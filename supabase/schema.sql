-- 합창곡 선호도 투표 (주제 여러 개, 주제마다 한 표): Supabase 데이터 구조와 권한 규칙
-- 합창단 전용 Supabase 프로젝트(합창단 선호도 조사)의 SQL Editor에서 전체를 실행합니다.
-- 여러 번 실행해도 안전합니다. 이미 입력한 제목, 곡, 마감 시각, 표는 지워지지 않습니다.
--
-- 구조
--   choir_groups  투표 묶음 하나 = 페이지 하나 (제목, 안내문, 참여 인원)
--   choir_polls   묶음 안의 주제 (주제 이름, 곡 목록)
--   choir_votes   표 (주제마다 기기당 한 표)
--
-- 원칙
--   1) 표와 설정은 브라우저에서 직접 읽거나 쓸 수 없고, 아래 함수(RPC)로만 다룬다.
--   2) 같은 기기 ID는 같은 주제에 두 번 투표할 수 없다 (DB 기본키로 막음).
--   3) 기기 지문이 같은데 기기 ID가 다른 표는 받되 "확인 필요"로 표시한다.
--      (같은 기종, 같은 OS를 쓰는 다른 단원을 막지 않기 위해서)
--   4) 모든 주제를 투표한 기기가 정한 인원(기본 15)에 이르면 투표가 닫히고,
--      그때 주제마다 1위 곡만 공개된다. 나머지 곡의 득표는 밖으로 내보내지 않는다.
--   5) 제목과 곡 수정은 관리 코드를 아는 사람만 할 수 있다 (코드는 해시로만 저장).

create extension if not exists pgcrypto;

-- 0) 예전 한 주제 구조 정리 (표가 하나도 없을 때만) ------------------------------------
do $$
begin
  if to_regclass('public.choir_polls') is not null and not exists (
       select 1 from information_schema.columns
       where table_schema = 'public' and table_name = 'choir_polls' and column_name = 'group_id') then
    if to_regclass('public.choir_votes') is not null and exists (select 1 from public.choir_votes) then
      raise exception '예전 구조에 표가 남아 있어 멈췄습니다. 표를 먼저 백업하세요.';
    end if;
    drop function if exists public.choir_ip_hash(text);
    drop function if exists public.choir_poll_info(text);
    drop function if exists public.choir_my_vote(text, uuid);
    drop function if exists public.choir_cast_vote(text, uuid, text, int);
    drop function if exists public.choir_results(text);
    drop table if exists public.choir_votes;
    drop table if exists public.choir_polls;
  end if;
end $$;

-- 1) 표 구조 -----------------------------------------------------------------------
create table if not exists public.choir_groups (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  title text not null check (char_length(title) between 1 and 60),
  description text not null default '' check (char_length(description) <= 300),
  expected_voters int not null default 15 check (expected_voters between 1 and 1000),  -- 이 인원이 모두 투표하면 공개
  max_votes int not null default 200 check (max_votes between 1 and 5000),  -- 주제당 표 상한 (조작 피해 제한)
  admin_hash text,                     -- 관리 코드의 sha256, 비어 있으면 아무도 수정 불가
  created_at timestamptz not null default now()
);

create table if not exists public.choir_polls (
  id text primary key check (id ~ '^[a-z0-9-]{1,40}$'),
  group_id text not null references public.choir_groups(id) on delete cascade,
  sort int not null default 0,
  title text not null check (char_length(title) between 1 and 60),
  songs jsonb not null check (jsonb_typeof(songs) = 'array' and jsonb_array_length(songs) between 2 and 10),
  created_at timestamptz not null default now()
);
create index if not exists choir_polls_group_idx on public.choir_polls(group_id, sort);

create table if not exists public.choir_votes (
  poll_id text not null references public.choir_polls(id) on delete cascade,
  device_id uuid not null,
  fp text not null check (fp ~ '^[0-9a-f]{64}$'),
  song int not null check (song between 0 and 9),
  flagged boolean not null default false,  -- 같은 주제에 지문이 같은 다른 기기 표가 이미 있음
  ip_hash text,                            -- 원본 IP는 저장하지 않음, 몰표 확인용
  created_at timestamptz not null default now(),
  primary key (poll_id, device_id)
);
create index if not exists choir_votes_fp_idx on public.choir_votes(poll_id, fp);

alter table public.choir_groups enable row level security;
alter table public.choir_polls enable row level security;
alter table public.choir_votes enable row level security;
-- 정책을 만들지 않으므로 anon, authenticated 모두 직접 접근 불가
revoke all on public.choir_groups from anon, authenticated;
revoke all on public.choir_polls from anon, authenticated;
revoke all on public.choir_votes from anon, authenticated;

-- 2) 도우미 ------------------------------------------------------------------------
create or replace function public.choir_ip_hash(p_salt text)
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
  return encode(digest(p_salt || ':' || trim(ip), 'sha256'), 'hex');
end $$;

create or replace function public.choir_is_admin(p_group text, p_code text)
returns boolean language sql stable set search_path = public, extensions as $$
  select exists (
    select 1 from public.choir_groups g
    where g.id = p_group and g.admin_hash is not null and p_code is not null
      and g.admin_hash = encode(digest(p_code, 'sha256'), 'hex')
  );
$$;

-- 모든 주제에 투표한 기기 수
create or replace function public.choir_completed(p_group text)
returns int language sql stable set search_path = public as $$
  select count(*)::int from (
    select v.device_id
    from public.choir_votes v join public.choir_polls p on p.id = v.poll_id
    where p.group_id = p_group
    group by v.device_id
    having count(distinct v.poll_id) = (select count(*) from public.choir_polls where group_id = p_group)
  ) d;
$$;

-- 3) 페이지 정보: 주제, 곡, 이 기기의 선택, 공개 후 1위 곡 ------------------------------------
create or replace function public.choir_group(p_group text, p_device uuid)
returns json language sql stable security definer set search_path = public as $$
  with g as (
    select g.*, public.choir_completed(g.id) as completed
    from public.choir_groups g where g.id = p_group
  )
  select json_build_object(
    'id', g.id,
    'title', g.title,
    'description', g.description,
    'expected', g.expected_voters,
    'completed', least(g.completed, g.expected_voters),
    'closed', g.completed >= g.expected_voters,
    'flagged', case when g.completed >= g.expected_voters then
                 (select count(*) from public.choir_votes v join public.choir_polls p on p.id = v.poll_id
                  where p.group_id = g.id and v.flagged) else null end,
    'topics', coalesce((
      select json_agg(json_build_object(
        'id', p.id,
        'title', p.title,
        'songs', p.songs,
        'mine', (select v.song from public.choir_votes v where v.poll_id = p.id and v.device_id = p_device),
        'winners', case when g.completed >= g.expected_voters then (
            select coalesce(json_agg(c.song order by c.song), '[]'::json) from (
              select v.song, count(*) as n, rank() over (order by count(*) desc) as rk
              from public.choir_votes v where v.poll_id = p.id group by v.song
            ) c where c.rk = 1
          ) else null end
      ) order by p.sort, p.id)
      from public.choir_polls p where p.group_id = g.id
    ), '[]'::json)
  )
  from g;
$$;

-- 4) 투표하기: 여러 주제를 한 번에, 전부 저장되거나 전부 거부 ---------------------------------
--    p_choices 예: {"topic-1": 2, "topic-2": 0}
create or replace function public.choir_cast_votes(p_group text, p_device uuid, p_fp text, p_choices jsonb)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  g public.choir_groups;
  k text;
  s int;
  p public.choir_polls;
  ip text;
  saved text[] := '{}';
begin
  select * into g from public.choir_groups where id = p_group;
  if not found then
    return json_build_object('ok', false, 'reason', 'no_group');
  end if;
  if p_device is null or p_fp is null or p_fp !~ '^[0-9a-f]{64}$' then
    return json_build_object('ok', false, 'reason', 'bad_device');
  end if;
  if p_choices is null or jsonb_typeof(p_choices) <> 'object' or p_choices = '{}'::jsonb then
    return json_build_object('ok', false, 'reason', 'empty');
  end if;

  -- 같은 묶음에 동시에 들어온 요청은 차례로 처리 (상한, 지문 판정이 어긋나지 않게)
  perform pg_advisory_xact_lock(hashtext('choir:' || p_group));

  -- 정한 인원이 모두 투표했으면 닫힘 (잠금 뒤에 확인해야 16번째가 끼어들지 못함)
  if public.choir_completed(p_group) >= g.expected_voters then
    return json_build_object('ok', false, 'reason', 'closed');
  end if;

  -- 먼저 전부 검사하고, 하나라도 문제면 아무것도 저장하지 않는다
  for k in select jsonb_object_keys(p_choices) loop
    select * into p from public.choir_polls where id = k and group_id = p_group;
    if not found then
      return json_build_object('ok', false, 'reason', 'bad_topic', 'topic', k);
    end if;
    if jsonb_typeof(p_choices->k) <> 'number' then
      return json_build_object('ok', false, 'reason', 'bad_song', 'topic', k);
    end if;
    if (p_choices->>k)::numeric <> trunc((p_choices->>k)::numeric) then
      return json_build_object('ok', false, 'reason', 'bad_song', 'topic', k);
    end if;
    s := (p_choices->>k)::numeric::int;
    if s < 0 or s >= jsonb_array_length(p.songs) then
      return json_build_object('ok', false, 'reason', 'bad_song', 'topic', k);
    end if;
    if exists (select 1 from public.choir_votes v where v.poll_id = k and v.device_id = p_device) then
      return json_build_object('ok', false, 'reason', 'already_voted', 'topic', k);
    end if;
    if (select count(*) from public.choir_votes v where v.poll_id = k) >= g.max_votes then
      return json_build_object('ok', false, 'reason', 'full', 'topic', k);
    end if;
  end loop;

  ip := public.choir_ip_hash(p_group);
  for k in select jsonb_object_keys(p_choices) loop
    insert into public.choir_votes (poll_id, device_id, fp, song, flagged, ip_hash)
    values (k, p_device, p_fp, (p_choices->>k)::numeric::int,
            exists (select 1 from public.choir_votes v where v.poll_id = k and v.fp = p_fp),
            ip);
    saved := saved || k;
  end loop;

  return json_build_object('ok', true, 'saved', to_json(saved));
end $$;

-- 5) 관리: 불러오기와 저장 (관리 코드 필요) ---------------------------------------------
create or replace function public.choir_admin_load(p_group text, p_code text)
returns json language plpgsql stable security definer set search_path = public as $$
declare g public.choir_groups;
begin
  if not public.choir_is_admin(p_group, p_code) then
    return json_build_object('ok', false, 'reason', 'bad_code');
  end if;
  select * into g from public.choir_groups where id = p_group;
  return json_build_object(
    'ok', true,
    'title', g.title,
    'description', g.description,
    'expected', g.expected_voters,
    'completed', public.choir_completed(p_group),
    'topics', coalesce((
      select json_agg(json_build_object(
        'id', p.id, 'title', p.title, 'songs', p.songs,
        'votes', (select count(*) from public.choir_votes v where v.poll_id = p.id)
      ) order by p.sort, p.id)
      from public.choir_polls p where p.group_id = p_group
    ), '[]'::json)
  );
end $$;

--    p_data 예: {"title": "...", "description": "...", "expected": 15,
--               "topics": [{"id": "topic-1", "title": "...", "songs": ["..", "..", "..", "..", ".."]}, ...]}
--    주제를 새로 만들거나 지우지는 않고, 있는 주제의 이름과 곡 제목만 바꾼다.
--    표가 들어온 주제는 곡 개수를 바꿀 수 없다 (표는 곡 순번으로 저장되므로).
create or replace function public.choir_admin_save(p_group text, p_code text, p_data jsonb)
returns json language plpgsql volatile security definer set search_path = public as $$
declare
  t jsonb;
  p public.choir_polls;
  new_songs jsonb;
  n_votes int;
  v_expected int;
begin
  if not public.choir_is_admin(p_group, p_code) then
    return json_build_object('ok', false, 'reason', 'bad_code');
  end if;
  if p_data is null or jsonb_typeof(p_data) <> 'object' then
    return json_build_object('ok', false, 'reason', 'bad_data');
  end if;

  if p_data ? 'expected' then
    if jsonb_typeof(p_data->'expected') <> 'number'
       or (p_data->>'expected')::numeric <> trunc((p_data->>'expected')::numeric)
       or (p_data->>'expected')::numeric not between 1 and 1000 then
      return json_build_object('ok', false, 'reason', 'bad_expected');
    end if;
    v_expected := (p_data->>'expected')::int;
  else
    select expected_voters into v_expected from public.choir_groups where id = p_group;
  end if;

  -- 검사 먼저
  for t in select * from jsonb_array_elements(coalesce(p_data->'topics', '[]'::jsonb)) loop
    select * into p from public.choir_polls where id = t->>'id' and group_id = p_group;
    if not found then
      return json_build_object('ok', false, 'reason', 'bad_topic', 'topic', t->>'id');
    end if;
    if char_length(btrim(coalesce(t->>'title', ''))) not between 1 and 60 then
      return json_build_object('ok', false, 'reason', 'bad_topic_title', 'topic', p.id);
    end if;
    new_songs := t->'songs';
    if new_songs is null or jsonb_typeof(new_songs) <> 'array' or jsonb_array_length(new_songs) not between 2 and 10 then
      return json_build_object('ok', false, 'reason', 'bad_songs', 'topic', p.id);
    end if;
    if exists (select 1 from jsonb_array_elements(new_songs) e
               where jsonb_typeof(e) <> 'string' or char_length(btrim(e #>> '{}')) not between 1 and 80) then
      return json_build_object('ok', false, 'reason', 'bad_song_title', 'topic', p.id);
    end if;
    select count(*) into n_votes from public.choir_votes where poll_id = p.id;
    if n_votes > 0 and jsonb_array_length(new_songs) <> jsonb_array_length(p.songs) then
      return json_build_object('ok', false, 'reason', 'songs_locked', 'topic', p.id);
    end if;
  end loop;
  if p_data ? 'title' and char_length(btrim(coalesce(p_data->>'title', ''))) not between 1 and 60 then
    return json_build_object('ok', false, 'reason', 'bad_title');
  end if;
  if p_data ? 'description' and char_length(coalesce(p_data->>'description', '')) > 300 then
    return json_build_object('ok', false, 'reason', 'bad_description');
  end if;

  -- 저장
  update public.choir_groups set
    title = case when p_data ? 'title' then btrim(p_data->>'title') else title end,
    description = case when p_data ? 'description' then btrim(coalesce(p_data->>'description', '')) else description end,
    expected_voters = v_expected
  where id = p_group;

  for t in select * from jsonb_array_elements(coalesce(p_data->'topics', '[]'::jsonb)) loop
    update public.choir_polls set
      title = btrim(t->>'title'),
      songs = (select jsonb_agg(btrim(x.e #>> '{}') order by x.o)
               from jsonb_array_elements(t->'songs') with ordinality as x(e, o))
    where id = t->>'id' and group_id = p_group;
  end loop;

  return public.choir_admin_load(p_group, p_code);
end $$;

-- 6) 권한 --------------------------------------------------------------------------
revoke all on function public.choir_ip_hash(text) from public, anon, authenticated;
revoke all on function public.choir_is_admin(text, text) from public, anon, authenticated;
revoke all on function public.choir_completed(text) from public, anon, authenticated;
revoke all on function public.choir_group(text, uuid) from public;
revoke all on function public.choir_cast_votes(text, uuid, text, jsonb) from public;
revoke all on function public.choir_admin_load(text, text) from public;
revoke all on function public.choir_admin_save(text, text, jsonb) from public;
grant execute on function public.choir_group(text, uuid) to anon, authenticated;
grant execute on function public.choir_cast_votes(text, uuid, text, jsonb) to anon, authenticated;
grant execute on function public.choir_admin_load(text, text) to anon, authenticated;
grant execute on function public.choir_admin_save(text, text, jsonb) to anon, authenticated;

-- 7) 첫 묶음과 주제 두 개 (이미 있으면 그대로 둠) ---------------------------------------------
insert into public.choir_groups (id, title, description)
values ('main', '합창곡 선호도 조사',
        '주제마다 가장 부르고 싶은 곡을 하나씩 골라 주세요. 모두 투표하면 주제별 1위 곡이 공개됩니다.')
on conflict (id) do nothing;

insert into public.choir_polls (id, group_id, sort, title, songs) values
  ('topic-1', 'main', 1, '주제 1 (이름 미정)',
   '["1번 곡 (제목 미정)", "2번 곡 (제목 미정)", "3번 곡 (제목 미정)", "4번 곡 (제목 미정)", "5번 곡 (제목 미정)"]'::jsonb),
  ('topic-2', 'main', 2, '주제 2 (이름 미정)',
   '["1번 곡 (제목 미정)", "2번 곡 (제목 미정)", "3번 곡 (제목 미정)", "4번 곡 (제목 미정)", "5번 곡 (제목 미정)"]'::jsonb)
on conflict (id) do nothing;

-- 관리 코드는 이 파일에 적지 않고 SQL Editor에서 따로 정합니다 (저장소가 공개라서):
--   update public.choir_groups set admin_hash = encode(extensions.digest('여기에 코드', 'sha256'), 'hex') where id = 'main';

-- 자주 쓰는 관리 명령 ---------------------------------------------------------------------
-- 공개 인원 바꾸기:        update public.choir_groups set expected_voters = 14 where id = 'main';
-- 진행 상황:               select public.choir_completed('main');
-- 전체 득표 몰래 보기:     select poll_id, song, count(*), count(*) filter (where flagged) as flagged
--                          from public.choir_votes group by 1, 2 order by 1, 2;
-- 확인 필요 표 보기:       select * from public.choir_votes where flagged order by created_at;
-- 표 하나 지우기:          delete from public.choir_votes where device_id = '...';
-- 몰표 의심 확인 (같은 IP에서 같은 분에 5표 이상, 연습실 와이파이처럼 정상적으로 겹칠 수도 있음):
--   select ip_hash, date_trunc('minute', created_at) as 분, count(*) from public.choir_votes
--   group by 1, 2 having count(*) >= 5 order by 3 desc;

-- 새로 만든 함수를 API가 바로 인식하도록 목록 새로고침
notify pgrst, 'reload schema';
