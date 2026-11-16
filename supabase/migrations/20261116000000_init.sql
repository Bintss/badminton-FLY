-- =====================================================================
-- 배드민턴 동아리 운동 투표·대진 앱 — M1 초기 스키마
-- 스키마 전체 + RLS + 가입/승인 RPC
-- 원칙: 클라이언트는 SELECT만 직접 한다. 모든 쓰기는 security definer RPC로.
-- =====================================================================

-- ---------------------------------------------------------------------
-- Enum
-- ---------------------------------------------------------------------
create type public.member_role         as enum ('admin', 'member');
create type public.member_status       as enum ('pending', 'approved', 'rejected', 'left');
create type public.session_type        as enum ('regular', 'flash');
create type public.registration_kind   as enum ('member', 'guest');
create type public.registration_status as enum ('confirmed', 'waitlisted', 'canceled');
create type public.match_status        as enum ('queued', 'playing', 'finished', 'canceled');

-- ---------------------------------------------------------------------
-- Tables
-- ---------------------------------------------------------------------
create table public.clubs (
  id          uuid primary key default gen_random_uuid(),
  name        text not null check (char_length(name) between 1 and 50),
  created_by  uuid references auth.users(id) on delete set null,
  created_at  timestamptz not null default now()
);

create table public.profiles (
  id            uuid primary key references auth.users(id) on delete cascade,
  display_name  text not null check (char_length(display_name) between 1 and 30),
  created_at    timestamptz not null default now()
);

create table public.club_members (
  club_id       uuid not null references public.clubs(id) on delete cascade,
  user_id       uuid not null references public.profiles(id) on delete cascade,
  role          public.member_role   not null default 'member',
  status        public.member_status not null default 'pending',
  level         text check (char_length(level) <= 10),          -- 본인 입력, 표시용
  requested_at  timestamptz not null default now(),
  decided_at    timestamptz,
  decided_by    uuid references public.profiles(id) on delete set null,
  primary key (club_id, user_id)
);
create index club_members_user_idx on public.club_members (user_id);

-- 정기운동 정의. 투표 오픈 규칙 = 운동일 open_days_before일 전 open_time
create table public.session_templates (
  id                uuid primary key default gen_random_uuid(),
  club_id           uuid not null references public.clubs(id) on delete cascade,
  title             text not null check (char_length(title) between 1 and 50),
  weekday           smallint not null check (weekday between 0 and 6),   -- 0=일요일
  start_time        time not null,
  end_time          time not null,
  place             text not null default '',
  capacity          int  not null check (capacity > 0),
  court_count       int  not null check (court_count > 0),
  open_days_before  int  not null check (open_days_before between 0 and 30),
  open_time         time not null,
  active            boolean not null default true,
  created_at        timestamptz not null default now(),
  check (end_time > start_time)
);
create index session_templates_club_idx on public.session_templates (club_id);

-- 세션 상태(오픈 전/투표 중/진행 중/종료)는 저장하지 않고 시각으로 계산한다.
create table public.sessions (
  id            uuid primary key default gen_random_uuid(),
  club_id       uuid not null references public.clubs(id) on delete cascade,
  template_id   uuid references public.session_templates(id) on delete set null,
  type          public.session_type not null,
  host_user_id  uuid references public.profiles(id) on delete set null,
  title         text not null check (char_length(title) between 1 and 50),
  place         text not null default '',
  starts_at     timestamptz not null,
  ends_at       timestamptz not null,
  capacity      int not null check (capacity > 0),
  court_count   int not null check (court_count > 0),
  opens_at      timestamptz not null,
  canceled_at   timestamptz,
  created_at    timestamptz not null default now(),
  check (ends_at > starts_at),
  check (opens_at <= starts_at),
  check (type = 'regular' or template_id is null),   -- 번개는 템플릿 없음
  unique (template_id, starts_at)          -- 템플릿 → 세션 생성 cron 멱등성
);
create index sessions_club_starts_idx on public.sessions (club_id, starts_at);

create table public.registrations (
  id             uuid primary key default gen_random_uuid(),
  session_id     uuid not null references public.sessions(id) on delete cascade,
  kind           public.registration_kind not null,
  user_id        uuid references public.profiles(id) on delete cascade,
  guest_name     text check (char_length(guest_name) between 1 and 30),
  added_by       uuid references public.profiles(id) on delete set null,
  status         public.registration_status not null,
  seq            bigint generated always as identity,       -- 서버 도착 순서
  late_eta       time,                                      -- 늦참 도착 예정 시각
  checked_in_at  timestamptz,
  created_at     timestamptz not null default now(),
  canceled_at    timestamptz,
  promoted_at    timestamptz,
  check (
    (kind = 'member' and user_id is not null and guest_name is null) or
    (kind = 'guest'  and user_id is null     and guest_name is not null)
  )
);
-- 1인 1표: 취소되지 않은 회원 신청은 세션당 하나
create unique index registrations_one_active_member
  on public.registrations (session_id, user_id)
  where kind = 'member' and status <> 'canceled';
create index registrations_session_status_seq_idx
  on public.registrations (session_id, status, seq);

create table public.matches (
  id           uuid primary key default gen_random_uuid(),
  session_id   uuid not null references public.sessions(id) on delete cascade,
  court_no     int check (court_no > 0),          -- null = 대기 중
  queue_pos    int,                               -- 대기열 순서 (queued일 때만)
  status       public.match_status not null default 'queued',
  created_by   uuid references public.profiles(id) on delete set null,
  created_at   timestamptz not null default now(),
  started_at   timestamptz,
  finished_at  timestamptz
);
create index matches_session_status_idx on public.matches (session_id, status);
-- 한 코트에 진행 중 경기는 하나
create unique index matches_one_playing_per_court
  on public.matches (session_id, court_no)
  where status = 'playing';

create table public.match_players (
  match_id         uuid not null references public.matches(id) on delete cascade,
  registration_id  uuid not null references public.registrations(id) on delete cascade,
  primary key (match_id, registration_id)
);
create index match_players_registration_idx on public.match_players (registration_id);

create table public.activity_log (
  id          bigint generated always as identity primary key,
  club_id     uuid not null references public.clubs(id) on delete cascade,
  session_id  uuid references public.sessions(id) on delete cascade,
  actor_id    uuid references public.profiles(id) on delete set null,
  action      text not null,
  payload     jsonb not null default '{}'::jsonb,
  created_at  timestamptz not null default now()
);
create index activity_log_club_created_idx on public.activity_log (club_id, created_at desc);

-- ---------------------------------------------------------------------
-- Helper functions (RLS에서 재귀 없이 쓰기 위해 security definer)
-- ---------------------------------------------------------------------
create or replace function public.is_club_member(p_club uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.club_members m
    where m.club_id = p_club and m.user_id = auth.uid() and m.status = 'approved'
  );
$$;

create or replace function public.is_club_admin(p_club uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.club_members m
    where m.club_id = p_club and m.user_id = auth.uid()
      and m.status = 'approved' and m.role = 'admin'
  );
$$;

create or replace function public.session_club_id(p_session uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select s.club_id from public.sessions s where s.id = p_session;
$$;

create or replace function public.match_club_id(p_match uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select s.club_id
  from public.matches mt join public.sessions s on s.id = mt.session_id
  where mt.id = p_match;
$$;

-- 프로필 열람: 본인 / 같은 동아리 승인 회원끼리 / 내가 운영진인 동아리의 가입 신청자
create or replace function public.can_view_profile(p_user uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select p_user = auth.uid()
      or exists (
        select 1
        from public.club_members me
        join public.club_members other on other.club_id = me.club_id
        where me.user_id = auth.uid() and me.status = 'approved'
          and other.user_id = p_user
          and (other.status = 'approved' or me.role = 'admin')
      );
$$;

-- 내부용: 변경 이력 기록
create or replace function public.log_activity(
  p_club uuid, p_session uuid, p_action text, p_payload jsonb default '{}'::jsonb
)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.activity_log (club_id, session_id, actor_id, action, payload)
  values (p_club, p_session, auth.uid(), p_action, coalesce(p_payload, '{}'::jsonb));
$$;

-- ---------------------------------------------------------------------
-- 신규 가입자 → profiles 자동 생성 (카카오 닉네임 사용)
-- ---------------------------------------------------------------------
create or replace function public.handle_new_user()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  insert into public.profiles (id, display_name)
  values (
    new.id,
    left(coalesce(
      nullif(new.raw_user_meta_data ->> 'name', ''),
      nullif(new.raw_user_meta_data ->> 'full_name', ''),
      nullif(new.raw_user_meta_data ->> 'user_name', ''),
      nullif(new.raw_user_meta_data ->> 'preferred_username', ''),
      '회원'
    ), 30)
  )
  on conflict (id) do nothing;
  return new;
end;
$$;

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function public.handle_new_user();

-- ---------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------
alter table public.clubs             enable row level security;
alter table public.profiles          enable row level security;
alter table public.club_members      enable row level security;
alter table public.session_templates enable row level security;
alter table public.sessions          enable row level security;
alter table public.registrations     enable row level security;
alter table public.matches           enable row level security;
alter table public.match_players     enable row level security;
alter table public.activity_log      enable row level security;

-- 직접 쓰기 권한은 전부 회수. profiles.display_name만 예외.
revoke insert, update, delete, truncate on all tables in schema public from anon, authenticated;
revoke all on all tables in schema public from anon;
grant update (display_name) on public.profiles to authenticated;

-- clubs: 가입 신청을 위해 로그인 사용자는 목록 열람 가능
create policy clubs_select on public.clubs
  for select to authenticated using (true);

create policy profiles_select on public.profiles
  for select to authenticated using (public.can_view_profile(id));
create policy profiles_update_own on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- club_members: 본인 행 / 승인 회원은 승인 회원 명단 / 운영진은 전체(신청자 포함)
create policy club_members_select on public.club_members
  for select to authenticated using (
    user_id = auth.uid()
    or (status = 'approved' and public.is_club_member(club_id))
    or public.is_club_admin(club_id)
  );

create policy session_templates_select on public.session_templates
  for select to authenticated using (public.is_club_member(club_id));

create policy sessions_select on public.sessions
  for select to authenticated using (public.is_club_member(club_id));

create policy registrations_select on public.registrations
  for select to authenticated using (public.is_club_member(public.session_club_id(session_id)));

create policy matches_select on public.matches
  for select to authenticated using (public.is_club_member(public.session_club_id(session_id)));

create policy match_players_select on public.match_players
  for select to authenticated using (public.is_club_member(public.match_club_id(match_id)));

create policy activity_log_select on public.activity_log
  for select to authenticated using (public.is_club_member(club_id));

-- ---------------------------------------------------------------------
-- RPC: 동아리 / 가입 / 승인
-- ---------------------------------------------------------------------

-- 서버 시각 (화면 카운트다운 보정용). now()는 트랜잭션 시작 시각이라 clock_timestamp 사용
create or replace function public.server_now()
returns timestamptz
language sql volatile
as $$ select clock_timestamp(); $$;

-- 동아리 생성: 생성자가 운영진(승인 상태)이 된다
create or replace function public.create_club(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_club uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  insert into public.clubs (name, created_by)
  values (btrim(p_name), v_uid)
  returning id into v_club;

  insert into public.club_members (club_id, user_id, role, status, decided_at, decided_by)
  values (v_club, v_uid, 'admin', 'approved', now(), v_uid);

  perform public.log_activity(v_club, null, 'club.create', jsonb_build_object('name', btrim(p_name)));
  return v_club;
end;
$$;

-- 가입 신청: 없으면 pending 생성, 거절/탈퇴였으면 다시 pending. 이미 pending/approved면 그대로.
create or replace function public.request_join(p_club uuid)
returns public.member_status
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid    uuid := auth.uid();
  v_status public.member_status;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not exists (select 1 from public.clubs where id = p_club) then
    raise exception 'club_not_found' using errcode = 'P0002';
  end if;

  insert into public.club_members (club_id, user_id, role, status)
  values (p_club, v_uid, 'member', 'pending')
  on conflict (club_id, user_id) do update
    set status       = 'pending',
        role         = 'member',
        requested_at = now(),
        decided_at   = null,
        decided_by   = null
    where public.club_members.status in ('rejected', 'left')
  returning status into v_status;

  if v_status is null then
    -- 이미 pending 또는 approved
    select status into v_status from public.club_members
    where club_id = p_club and user_id = v_uid;
  else
    perform public.log_activity(p_club, null, 'member.request', '{}'::jsonb);
  end if;

  return v_status;
end;
$$;

-- 가입 승인/거절 (운영진)
create or replace function public.decide_member(p_club uuid, p_user uuid, p_approve boolean)
returns public.member_status
language plpgsql security definer set search_path = ''
as $$
declare
  v_status public.member_status;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.club_members
     set status     = case when p_approve then 'approved'::public.member_status
                           else 'rejected'::public.member_status end,
         decided_at = now(),
         decided_by = auth.uid()
   where club_id = p_club and user_id = p_user and status = 'pending'
  returning status into v_status;

  if v_status is null then
    raise exception 'not_pending' using errcode = 'P0002';
  end if;

  perform public.log_activity(
    p_club, null,
    case when p_approve then 'member.approve' else 'member.reject' end,
    jsonb_build_object('user_id', p_user)
  );
  return v_status;
end;
$$;

-- 운영진 지정/해제 (운영진). 마지막 운영진은 해제할 수 없다.
create or replace function public.set_member_role(p_club uuid, p_user uuid, p_role public.member_role)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  -- 동시 해제 경합 방지: 해당 동아리의 운영진 행을 잠근다
  perform 1 from public.club_members
   where club_id = p_club and role = 'admin' and status = 'approved'
   for update;

  if p_role = 'member'
     and (select count(*) from public.club_members
           where club_id = p_club and role = 'admin' and status = 'approved'
             and user_id <> p_user) = 0 then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;

  update public.club_members
     set role = p_role
   where club_id = p_club and user_id = p_user and status = 'approved';

  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;

  perform public.log_activity(p_club, null, 'member.role',
    jsonb_build_object('user_id', p_user, 'role', p_role));
end;
$$;

-- 본인 급수 입력 (표시용)
create or replace function public.set_my_level(p_club uuid, p_level text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.club_members
     set level = nullif(btrim(p_level), '')
   where club_id = p_club and user_id = auth.uid() and status = 'approved';

  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- Function 실행 권한: 로그인 사용자만, 내부 함수는 비공개
-- ---------------------------------------------------------------------
-- Supabase는 default privileges로 anon/authenticated에 execute를 주므로 셋 다 회수한 뒤 필요한 것만 부여
revoke execute on all functions in schema public from public, anon, authenticated;

grant execute on function public.server_now()                                       to authenticated;
grant execute on function public.create_club(text)                                  to authenticated;
grant execute on function public.request_join(uuid)                                 to authenticated;
grant execute on function public.decide_member(uuid, uuid, boolean)                 to authenticated;
grant execute on function public.set_member_role(uuid, uuid, public.member_role)    to authenticated;
grant execute on function public.set_my_level(uuid, text)                           to authenticated;
-- RLS 정책에서 호출되므로 authenticated에 필요
grant execute on function public.is_club_member(uuid)   to authenticated;
grant execute on function public.is_club_admin(uuid)    to authenticated;
grant execute on function public.session_club_id(uuid)  to authenticated;
grant execute on function public.match_club_id(uuid)    to authenticated;
grant execute on function public.can_view_profile(uuid) to authenticated;
-- log_activity, handle_new_user는 RPC로 노출하지 않음 (security definer 함수 내부에서만 호출)
