-- 합창곡 선호도 투표: Supabase 데이터 구조와 권한 규칙
-- Supabase 대시보드 > SQL Editor > New query 에 전체를 붙여 넣고 Run 하세요.
-- 여러 번 실행해도 안전합니다. 기존 매니볼 테이블은 건드리지 않습니다 (모든 이름이 choir_ 로 시작).
--
-- 원칙
--   1) 표는 브라우저에서 직접 읽거나 쓸 수 없고, 아래 함수(RPC)로만 다룬다.
--   2) 같은 기기 ID는 두 번 투표할 수 없다 (DB 기본키로 막음).
--   3) 기기 지문이 같은데 기기 ID가 다른 표는 받되 "확인 필요"로 표시한다.
--      (같은 기종, 같은 OS를 쓰는 다른 단원을 막지 않기 위해서)
--   4) 결과는 마감 시각이 지나야만 공개된다.

create extension if not exists pgcrypto;

-- 투표 설정 ------------------------------------------------------------------
create table if not exists public.choir_polls (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  title text not null check (char_length(title) between 1 and 60),
  description text not null default '' check (char_length(description) <= 300),
  songs jsonb not null check (jsonb_typeof(songs) = 'array' and jsonb_array_length(songs) between 2 and 10),
  close_at timestamptz,                 -- 비워 두면 마감 미정: 투표는 열려 있고 결과는 비공개
  max_votes int not null default 200 check (max_votes between 1 and 5000),  -- 조작 피해 상한
  created_at timestamptz not null default now()
);

-- 표 --------------------------------------------------------------------------
create table if not exists public.choir_votes (
  poll_id text not null references public.choir_polls(id) on delete cascade,
  device_id uuid not null,
  fp text not null check (fp ~ '^[0-9a-f]{64}$'),
  song int not null check (song between 0 and 9),
  flagged boolean not null default false,  -- 지문이 이미 투표한 기기와 같음
  ip_hash text,                            -- 원본 IP는 저장하지 않음, 몰표 확인용
  created_at timestamptz not null default now(),
  primary key (poll_id, device_id)
);
create index if not exists choir_votes_fp_idx on public.choir_votes(poll_id, fp);

alter table public.choir_polls enable row level security;
alter table public.choir_votes enable row level security;
-- 정책을 만들지 않으므로 anon, authenticated 모두 직접 접근 불가
revoke all on public.choir_polls from anon, authenticated;
revoke all on public.choir_votes from anon, authenticated;

-- 도우미: 요청자 IP 해시 (Supabase는 x-forwarded-for 헤더를 넘겨줌) ---------------
create or replace function public.choir_ip_hash(p_poll text)
returns text language plpgsql stable set search_path = public, extensions as $$
declare h json; ip text;
begin
  begin
    h := current_setting('request.headers', true)::json;
  exception when others then
    return null;
  end;
  ip := split_part(coalesce(h->>'x-forwarded-for', h->>'x-real-ip', ''), ',', 1);
  if ip = '' then return null; end if;
  return encode(digest(p_poll || ':' || trim(ip), 'sha256'), 'hex');
end $$;

-- 1) 투표 정보 ----------------------------------------------------------------
create or replace function public.choir_poll_info(p_poll text)
returns json language sql stable security definer set search_path = public as $$
  select json_build_object(
    'id', p.id,
    'title', p.title,
    'description', p.description,
    'songs', p.songs,
    'close_at', p.close_at,
    'closed', p.close_at is not null and now() >= p.close_at,
    'participants', (select count(*) from public.choir_votes v where v.poll_id = p.id),
    'server_now', now()
  )
  from public.choir_polls p where p.id = p_poll;
$$;

-- 2) 이 기기의 투표 여부 --------------------------------------------------------
--    기기 ID가 일치할 때만 본인이 고른 곡을 돌려준다 (지문만 같으면 남의 표일 수 있음)
create or replace function public.choir_my_vote(p_poll text, p_device uuid)
returns json language sql stable security definer set search_path = public as $$
  select coalesce(
    (select json_build_object('voted', true, 'song', v.song, 'at', v.created_at)
       from public.choir_votes v where v.poll_id = p_poll and v.device_id = p_device),
    json_build_object('voted', false)
  );
$$;

-- 3) 투표하기 -------------------------------------------------------------------
create or replace function public.choir_cast_vote(p_poll text, p_device uuid, p_fp text, p_song int)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  p public.choir_polls;
  n int;
  is_flagged boolean;
begin
  select * into p from public.choir_polls where id = p_poll;
  if not found then
    return json_build_object('ok', false, 'reason', 'no_poll');
  end if;
  if p.close_at is not null and now() >= p.close_at then
    return json_build_object('ok', false, 'reason', 'closed');
  end if;
  if p_song is null or p_song < 0 or p_song >= jsonb_array_length(p.songs) then
    return json_build_object('ok', false, 'reason', 'bad_song');
  end if;
  if p_device is null or p_fp is null or p_fp !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false, 'reason', 'bad_device');
  end if;

  -- 동시에 여러 요청이 와도 상한과 지문 판정이 어긋나지 않도록 투표 단위로 잠금
  perform pg_advisory_xact_lock(hashtext('choir:' || p_poll));

  if exists (select 1 from public.choir_votes where poll_id = p_poll and device_id = p_device) then
    return json_build_object('ok', false, 'reason', 'already_voted');
  end if;

  select count(*) into n from public.choir_votes where poll_id = p_poll;
  if n >= p.max_votes then
    return json_build_object('ok', false, 'reason', 'full');
  end if;

  is_flagged := exists (select 1 from public.choir_votes where poll_id = p_poll and fp = p_fp);

  insert into public.choir_votes (poll_id, device_id, fp, song, flagged, ip_hash)
  values (p_poll, p_device, p_fp, p_song, is_flagged, public.choir_ip_hash(p_poll));

  return json_build_object('ok', true, 'song', p_song);
end $$;

-- 4) 결과 (마감 후에만) ----------------------------------------------------------
create or replace function public.choir_results(p_poll text)
returns json language plpgsql stable security definer set search_path = public as $$
declare p public.choir_polls;
begin
  select * into p from public.choir_polls where id = p_poll;
  if not found then
    return json_build_object('ok', false, 'reason', 'no_poll');
  end if;
  if p.close_at is null or now() < p.close_at then
    return json_build_object('ok', false, 'reason', 'not_closed');
  end if;
  return json_build_object(
    'ok', true,
    'total', (select count(*) from public.choir_votes where poll_id = p_poll),
    'flagged', (select count(*) from public.choir_votes where poll_id = p_poll and flagged),
    'counts', (
      select json_agg(json_build_object(
               'song', i - 1,
               'votes', (select count(*) from public.choir_votes v where v.poll_id = p_poll and v.song = i - 1),
               'flagged', (select count(*) from public.choir_votes v where v.poll_id = p_poll and v.song = i - 1 and v.flagged)
             ) order by i)
      from generate_series(1, jsonb_array_length(p.songs)) as i
    )
  );
end $$;

revoke all on function public.choir_ip_hash(text) from public, anon, authenticated;
revoke all on function public.choir_poll_info(text) from public;
revoke all on function public.choir_my_vote(text, uuid) from public;
revoke all on function public.choir_cast_vote(text, uuid, text, int) from public;
revoke all on function public.choir_results(text) from public;
grant execute on function public.choir_poll_info(text) to anon, authenticated;
grant execute on function public.choir_my_vote(text, uuid) to anon, authenticated;
grant execute on function public.choir_cast_vote(text, uuid, text, int) to anon, authenticated;
grant execute on function public.choir_results(text) to anon, authenticated;

-- 첫 투표 만들기 (이미 있으면 그대로 둠: 이 파일을 다시 실행해도 곡 제목, 마감 시각이 지워지지 않음) --
insert into public.choir_polls (id, title, description, songs, close_at)
values (
  'main',
  '합창곡 선호도 조사',
  '다섯 곡 중 가장 부르고 싶은 곡 하나를 골라 주세요. 한 기기에서 한 번만 투표할 수 있습니다.',
  '["1번 곡 (제목 미정)", "2번 곡 (제목 미정)", "3번 곡 (제목 미정)", "4번 곡 (제목 미정)", "5번 곡 (제목 미정)"]'::jsonb,
  null
)
on conflict (id) do nothing;

-- 자주 쓰는 관리 명령 (필요할 때 골라 실행) ----------------------------------------------
-- 곡 제목 바꾸기 (표가 들어온 뒤에는 순서를 바꾸지 말 것: 표는 곡 순번으로 저장됨):
--   update public.choir_polls set songs = '["곡1", "곡2", "곡3", "곡4", "곡5"]'::jsonb where id = 'main';
-- 제목, 안내문 바꾸기:
--   update public.choir_polls set title = '...', description = '...' where id = 'main';
-- 지금 바로 마감:          update public.choir_polls set close_at = now() where id = 'main';
-- 마감 시각 지정:          update public.choir_polls set close_at = '2026-11-20 22:00+09' where id = 'main';
-- 마감 취소(다시 열기):    update public.choir_polls set close_at = null where id = 'main';
-- 마감 전 결과 몰래 보기:  select song, count(*), count(*) filter (where flagged) as flagged
--                          from public.choir_votes where poll_id = 'main' group by song order by song;
-- 확인 필요 표 보기:       select * from public.choir_votes where poll_id = 'main' and flagged order by created_at;
-- 몰표 의심 확인 (같은 IP에서 10분 안에 들어온 표 수, 연습실 와이파이처럼 정상적으로 겹칠 수도 있음):
--   select ip_hash, date_trunc('minute', created_at) as 분, count(*) from public.choir_votes
--   where poll_id = 'main' group by 1, 2 having count(*) >= 5 order by 3 desc;
-- 참여 인원 상한 바꾸기:   update public.choir_polls set max_votes = 80 where id = 'main';
-- 표 하나 지우기:          delete from public.choir_votes where poll_id = 'main' and device_id = '...';

-- 새로 만든 함수를 API가 바로 인식하도록 목록 새로고침
notify pgrst, 'reload schema';
