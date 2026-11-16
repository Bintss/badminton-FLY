-- =====================================================================
-- M3: 정기운동 템플릿 → 세션 자동 생성, 번개 개설, 세션 수정/취소, 일정 목록 뷰
--
-- 세션 생성 규칙
--   * 템플릿마다 "투표 오픈이 7일 이내로 다가온" 미래 운동만 만든다 (목록이 너무 길어지지 않게)
--   * 시각 계산은 동아리 시간대(clubs.timezone, 기본 Asia/Seoul) 기준
--   * template_slot = 템플릿이 원래 정한 시작 시각. (template_id, template_slot) 유니크라서
--     운영진이 날짜를 옮기거나 취소해도 같은 회차가 다시 생성되지 않는다
--   * 템플릿 수정은 이후 생성되는 세션부터 적용 (이미 만든 세션은 그대로)
--   * 생성은 ① 템플릿 저장 직후 ② 홈 화면 진입 시(ensure_upcoming_sessions) ③ pg_cron 매시간
--     어느 경로로 몇 번 불려도 결과는 같다 (멱등)
-- =====================================================================

alter table public.clubs add column timezone text not null default 'Asia/Seoul';

alter table public.sessions add column template_slot timestamptz;
alter table public.sessions drop constraint sessions_template_id_starts_at_key;
alter table public.sessions add constraint sessions_template_slot_key unique (template_id, template_slot);

-- ---------------------------------------------------------------------
-- 내부: 템플릿 하나에 대해 필요한 세션 생성. 반환 = 새로 만든 개수
-- ---------------------------------------------------------------------
create or replace function public.generate_template_sessions(p_template uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  t        public.session_templates%rowtype;
  v_tz     text;
  v_today  date;
  d        date;
  v_start  timestamptz;
  v_end    timestamptz;
  v_open   timestamptz;
  v_made   int := 0;
begin
  select * into t from public.session_templates where id = p_template and active;
  if not found then
    return 0;
  end if;
  select timezone into v_tz from public.clubs where id = t.club_id;

  v_today := (now() at time zone v_tz)::date;

  for d in
    select g::date from generate_series(v_today, v_today + t.open_days_before + 7, interval '1 day') g
  loop
    continue when extract(dow from d)::int <> t.weekday;

    v_start := (d + t.start_time) at time zone v_tz;
    v_end   := (d + t.end_time)   at time zone v_tz;
    v_open  := ((d - t.open_days_before) + t.open_time) at time zone v_tz;
    if v_open > v_start then
      v_open := v_start;
    end if;

    continue when v_start <= now();                       -- 지난 운동
    continue when v_open > now() + interval '7 days';     -- 아직 너무 먼 운동

    insert into public.sessions
      (club_id, template_id, template_slot, type, title, place,
       starts_at, ends_at, capacity, court_count, opens_at)
    values
      (t.club_id, t.id, v_start, 'regular', t.title, t.place,
       v_start, v_end, t.capacity, t.court_count, v_open)
    on conflict (template_id, template_slot) do nothing;

    if found then
      v_made := v_made + 1;
    end if;
  end loop;

  return v_made;
end;
$$;

-- 내부(cron용): 모든 활성 템플릿
create or replace function public.generate_all_sessions()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_id   uuid;
  v_made int := 0;
begin
  for v_id in select id from public.session_templates where active loop
    v_made := v_made + public.generate_template_sessions(v_id);
  end loop;
  return v_made;
end;
$$;

-- 회원용: 홈 화면 진입 시 호출. cron이 없거나 늦어도 목록이 비지 않게 한다
create or replace function public.ensure_upcoming_sessions(p_club uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_id   uuid;
  v_made int := 0;
begin
  if not public.is_club_member(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  for v_id in select id from public.session_templates where club_id = p_club and active loop
    v_made := v_made + public.generate_template_sessions(v_id);
  end loop;
  return v_made;
end;
$$;

-- ---------------------------------------------------------------------
-- 정기운동 템플릿 저장 (운영진). p_id가 null이면 새로 만든다.
-- ---------------------------------------------------------------------
create or replace function public.save_template(
  p_club             uuid,
  p_id               uuid,
  p_title            text,
  p_weekday          smallint,
  p_start_time       time,
  p_end_time         time,
  p_place            text,
  p_capacity         int,
  p_court_count      int,
  p_open_days_before int,
  p_open_time        time,
  p_active           boolean default true
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_end_time <= p_start_time then
    raise exception 'invalid_time' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.session_templates
      (club_id, title, weekday, start_time, end_time, place, capacity, court_count,
       open_days_before, open_time, active)
    values
      (p_club, btrim(p_title), p_weekday, p_start_time, p_end_time, coalesce(btrim(p_place), ''),
       p_capacity, p_court_count, p_open_days_before, p_open_time, coalesce(p_active, true))
    returning id into v_id;
  else
    update public.session_templates
       set title = btrim(p_title), weekday = p_weekday, start_time = p_start_time, end_time = p_end_time,
           place = coalesce(btrim(p_place), ''), capacity = p_capacity, court_count = p_court_count,
           open_days_before = p_open_days_before, open_time = p_open_time,
           active = coalesce(p_active, true)
     where id = p_id and club_id = p_club
    returning id into v_id;
    if v_id is null then
      raise exception 'template_not_found' using errcode = 'P0002';
    end if;
  end if;

  perform public.log_activity(p_club, null, case when p_id is null then 'template.create' else 'template.update' end,
    jsonb_build_object('template_id', v_id));
  perform public.generate_template_sessions(v_id);
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 번개 개설 (승인 회원 누구나)
-- ---------------------------------------------------------------------
create or replace function public.create_flash(
  p_club        uuid,
  p_title       text,
  p_place       text,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_capacity    int,
  p_court_count int,
  p_opens_at    timestamptz default null     -- null = 지금 바로 오픈
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_open timestamptz := coalesce(p_opens_at, now());
  v_id   uuid;
begin
  if not public.is_club_member(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_starts_at <= now() or p_ends_at <= p_starts_at or v_open > p_starts_at then
    raise exception 'invalid_time' using errcode = '22023';
  end if;
  if p_capacity is null or p_capacity <= 0 then
    raise exception 'invalid_capacity' using errcode = '22023';
  end if;
  if p_court_count is null or p_court_count <= 0 then
    raise exception 'invalid_court_count' using errcode = '22023';
  end if;

  insert into public.sessions
    (club_id, type, host_user_id, title, place, starts_at, ends_at, capacity, court_count, opens_at)
  values
    (p_club, 'flash', auth.uid(), btrim(p_title), coalesce(btrim(p_place), ''),
     p_starts_at, p_ends_at, p_capacity, p_court_count, v_open)
  returning id into v_id;

  perform public.log_activity(p_club, v_id, 'session.create_flash', '{}'::jsonb);
  return v_id;
end;
$$;

-- 내부: 세션 관리 권한 (운영진 / 번개 개설자)
create or replace function public.can_manage_session(p_session public.sessions)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select public.is_club_admin(p_session.club_id)
      or (p_session.type = 'flash'
          and p_session.host_user_id = auth.uid()
          and public.is_club_member(p_session.club_id));
$$;

-- ---------------------------------------------------------------------
-- 세션 수정 (운영진 / 번개 개설자). 정원은 update_capacity로.
--   오픈 시각은 투표가 열리기 전까지만 바꿀 수 있다 (선착순 공정성)
-- ---------------------------------------------------------------------
create or replace function public.update_session(
  p_session     uuid,
  p_title       text,
  p_place       text,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_court_count int,
  p_opens_at    timestamptz
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.can_manage_session(s) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if p_opens_at is distinct from s.opens_at and now() >= s.opens_at then
    raise exception 'already_open' using errcode = 'P0001';
  end if;
  if p_ends_at <= p_starts_at or p_opens_at > p_starts_at then
    raise exception 'invalid_time' using errcode = '22023';
  end if;
  if p_court_count is null or p_court_count <= 0 then
    raise exception 'invalid_court_count' using errcode = '22023';
  end if;

  update public.sessions
     set title = btrim(p_title), place = coalesce(btrim(p_place), ''),
         starts_at = p_starts_at, ends_at = p_ends_at,
         court_count = p_court_count, opens_at = p_opens_at
   where id = p_session;

  perform public.log_activity(s.club_id, p_session, 'session.update',
    jsonb_build_object('starts_at', p_starts_at, 'opens_at', p_opens_at));
end;
$$;

-- 세션 취소 (운영진 / 번개 개설자). 신청 내역은 남겨 둔다.
create or replace function public.cancel_session(p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.can_manage_session(s) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    return;
  end if;

  update public.sessions set canceled_at = now() where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'session.cancel', '{}'::jsonb);
end;
$$;

-- ---------------------------------------------------------------------
-- 일정 목록 뷰: 세션 + 확정/대기 인원 + 내 신청 상태
--   security_invoker = 조회하는 사용자 권한(RLS)으로 실행 → 다른 동아리 세션은 안 보인다
-- ---------------------------------------------------------------------
create view public.session_overview
with (security_invoker = true)
as
select
  s.id, s.club_id, s.template_id, s.type, s.host_user_id, s.title, s.place,
  s.starts_at, s.ends_at, s.capacity, s.court_count, s.opens_at, s.canceled_at,
  coalesce(c.confirmed, 0)::int  as confirmed_count,
  coalesce(c.waitlisted, 0)::int as waitlist_count,
  coalesce(c.guests, 0)::int     as guest_count,
  me.id                          as my_registration_id,
  me.status                      as my_status
from public.sessions s
left join lateral (
  select count(*) filter (where r.kind = 'member' and r.status = 'confirmed')  as confirmed,
         count(*) filter (where r.kind = 'member' and r.status = 'waitlisted') as waitlisted,
         count(*) filter (where r.kind = 'guest'  and r.status <> 'canceled')  as guests
    from public.registrations r
   where r.session_id = s.id
) c on true
left join lateral (
  select r.id, r.status
    from public.registrations r
   where r.session_id = s.id and r.user_id = auth.uid() and r.kind = 'member' and r.status <> 'canceled'
   limit 1
) me on true;

revoke all on public.session_overview from public, anon, authenticated;
grant select on public.session_overview to authenticated;

-- ---------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------
revoke execute on function public.generate_template_sessions(uuid)        from public, anon, authenticated;
revoke execute on function public.generate_all_sessions()                 from public, anon, authenticated;
revoke execute on function public.can_manage_session(public.sessions)     from public, anon, authenticated;
revoke execute on function public.ensure_upcoming_sessions(uuid)          from public, anon, authenticated;
revoke execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean) from public, anon, authenticated;
revoke execute on function public.create_flash(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz) from public, anon, authenticated;
revoke execute on function public.update_session(uuid, text, text, timestamptz, timestamptz, int, timestamptz) from public, anon, authenticated;
revoke execute on function public.cancel_session(uuid)                    from public, anon, authenticated;

grant execute on function public.ensure_upcoming_sessions(uuid) to authenticated;
grant execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean) to authenticated;
grant execute on function public.create_flash(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz) to authenticated;
grant execute on function public.update_session(uuid, text, text, timestamptz, timestamptz, int, timestamptz) to authenticated;
grant execute on function public.cancel_session(uuid) to authenticated;
