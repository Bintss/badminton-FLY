-- =====================================================================
-- 투표 때 게스트 추가 + 게스트를 정원에 넣을지 설정
--
--   sessions.guests_in_capacity / session_templates.guests_in_capacity (기본: 넣지 않음 = 예전과 같음)
--   * 넣음: 게스트도 회원과 같은 선착순 줄에 선다. 정원이 차면 대기, 취소가 생기면 seq 순서대로 승격
--   * 안 넣음: 게스트는 늘 확정, 정원·대기 순번과 무관
--   * 대진판(현장)·대회 명단에서 운영진이 넣는 게스트는 설정과 상관없이 확정 (현장 판단)
--
--   add_vote_guest: 회원이 투표 화면에서 게스트를 데려온다
--     회원은 투표가 열린 동안(오픈 ~ 시작), 운영진·번개 개설자는 끝나기 전까지
--     회원 한 명이 한 운동에 데려올 수 있는 게스트는 3명까지 (운영진·개설자는 제한 없음)
--     대진이 공개된 대회에는 넣을 수 없다 (명단 관리에서 운영진이)
-- =====================================================================

alter table public.sessions add column guests_in_capacity boolean not null default false;
alter table public.session_templates add column guests_in_capacity boolean not null default false;

-- 내부: 이 신청이 정원을 차지하는 종류인가
create or replace function public.counts_capacity(p_kind public.registration_kind, p_guests_in boolean)
returns boolean
language sql immutable set search_path = ''
as $$
  select p_kind = 'member' or coalesce(p_guests_in, false);
$$;

-- 내부: 정원을 차지한 확정 인원
create or replace function public.capacity_used(p_session uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
    from public.registrations r join public.sessions s on s.id = r.session_id
   where r.session_id = p_session and r.status = 'confirmed'
     and public.counts_capacity(r.kind, s.guests_in_capacity);
$$;


-- 대기 승격: 설정에 따라 게스트도 같은 줄
create or replace function public.promote_waitlist(p_session uuid, p_slots int)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_count int := 0;
begin
  if p_slots <= 0 then
    return 0;
  end if;

  with next_up as (
    select r.id from public.registrations r join public.sessions s on s.id = r.session_id
     where r.session_id = p_session and r.status = 'waitlisted'
       and public.counts_capacity(r.kind, s.guests_in_capacity)
     order by r.seq
     limit p_slots
     for update of r
  )
  update public.registrations r
     set status = 'confirmed', promoted_at = now()
    from next_up
   where r.id = next_up.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

create or replace function public.registration_position(p_registration uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
    from public.registrations me
    join public.sessions s on s.id = me.session_id
    join public.registrations other
      on other.session_id = me.session_id
     and public.counts_capacity(other.kind, s.guests_in_capacity)
     and other.status = me.status
     and other.seq <= me.seq
   where me.id = p_registration;
$$;

create or replace function public.register(p_session uuid, p_late_eta time default null)
returns table (registration_id uuid, status public.registration_status, queue_position int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid       uuid := auth.uid();
  v_session   public.sessions%rowtype;
  v_confirmed int;
  v_status    public.registration_status;
  v_reg_id    uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select * into v_session from public.sessions s where s.id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_member(v_session.club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_session.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if now() < v_session.opens_at then
    raise exception 'not_open' using errcode = 'P0001';
  end if;
  if now() >= v_session.starts_at then
    raise exception 'closed' using errcode = 'P0001';
  end if;

  -- 이미 신청함 → 기존 신청 반환
  select r.id, r.status into v_reg_id, v_status
    from public.registrations r
   where r.session_id = p_session and r.user_id = v_uid
     and r.kind = 'member' and r.status <> 'canceled';
  if found then
    return query select v_reg_id, v_status, public.registration_position(v_reg_id);
    return;
  end if;

  v_confirmed := public.capacity_used(p_session);

  v_status := case when v_confirmed < v_session.capacity
                   then 'confirmed'::public.registration_status
                   else 'waitlisted'::public.registration_status end;

  insert into public.registrations (session_id, kind, user_id, added_by, status, late_eta)
  values (p_session, 'member', v_uid, v_uid, v_status, p_late_eta)
  returning id into v_reg_id;

  perform public.log_activity(v_session.club_id, p_session, 'registration.create',
    jsonb_build_object('registration_id', v_reg_id, 'status', v_status));

  return query select v_reg_id, v_status, public.registration_position(v_reg_id);
end;
$$;

create or replace function public.cancel_registration(p_registration uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid      uuid := auth.uid();
  v_reg      public.registrations%rowtype;
  v_club     uuid;
  v_promoted uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  -- 잠금 순서: 세션 먼저
  select s.club_id into v_club
    from public.sessions s
    join public.registrations r on r.session_id = s.id
   where r.id = p_registration
     for update of s;
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;

  select * into v_reg from public.registrations where id = p_registration for update;

  -- 게스트: 데려온 사람 / 운영진·번개 개설자 / 대진판을 쓸 수 있는 참석자(현장)
  -- (user_id·added_by가 null이면 비교가 null이 되어 검사를 빠져나가므로 coalesce)
  if not (
       coalesce(v_reg.user_id = v_uid, false)
    or public.is_club_admin(v_club)
    or (v_reg.kind = 'guest' and public.is_club_member(v_club)
        and (coalesce(v_reg.added_by = v_uid, false)
             or public.can_manage_session((select x from public.sessions x where x.id = v_reg.session_id))
             or public.can_operate_board(v_reg.session_id)))
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_reg.status = 'canceled' then
    raise exception 'already_canceled' using errcode = 'P0001';
  end if;

  update public.registrations
     set status = 'canceled', canceled_at = now()
   where id = p_registration;

  -- 정원을 차지하던 확정자가 빠지면 대기 1순위 승격 (게스트 포함 설정이면 게스트도)
  if v_reg.status = 'confirmed'
     and public.counts_capacity(v_reg.kind, (select guests_in_capacity from public.sessions where id = v_reg.session_id)) then
    with next_up as (
      select r2.id from public.registrations r2 join public.sessions s2 on s2.id = r2.session_id
       where r2.session_id = v_reg.session_id and r2.status = 'waitlisted'
         and public.counts_capacity(r2.kind, s2.guests_in_capacity)
       order by r2.seq
       limit 1
       for update of r2
    )
    update public.registrations r
       set status = 'confirmed', promoted_at = now()
      from next_up
     where r.id = next_up.id
    returning r.id into v_promoted;
  end if;

  perform public.log_activity(v_club, v_reg.session_id, 'registration.cancel',
    jsonb_build_object('registration_id', p_registration,
                       'was', v_reg.status,
                       'promoted', v_promoted));
  return v_promoted;
end;
$$;

create or replace function public.update_capacity(p_session uuid, p_capacity int)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_session   public.sessions%rowtype;
  v_confirmed int;
  v_promoted  int;
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_capacity is null or p_capacity <= 0 then
    raise exception 'invalid_capacity' using errcode = '22023';
  end if;

  select * into v_session from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not (
       public.is_club_admin(v_session.club_id)
    or (v_session.type = 'flash' and v_session.host_user_id = auth.uid()
        and public.is_club_member(v_session.club_id))
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  v_confirmed := public.capacity_used(p_session);

  if p_capacity < v_confirmed then
    raise exception 'capacity_below_confirmed' using errcode = 'P0001',
      detail = format('confirmed=%s', v_confirmed);
  end if;

  update public.sessions set capacity = p_capacity where id = p_session;
  v_promoted := public.promote_waitlist(p_session, p_capacity - v_confirmed);

  perform public.log_activity(v_session.club_id, p_session, 'session.capacity',
    jsonb_build_object('from', v_session.capacity, 'to', p_capacity, 'promoted', v_promoted));
  return v_promoted;
end;
$$;

create or replace function public.roster_add_member(p_session uuid, p_user uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s           public.sessions%rowtype;
  v_existing  public.registrations%rowtype;
  v_confirmed int;
  v_id        uuid;
  v_raised    boolean := false;
begin
  s := public.lock_roster(p_session);
  if not exists (select 1 from public.club_members
                  where club_id = s.club_id and user_id = p_user and status = 'approved') then
    raise exception 'not_member' using errcode = 'P0002';
  end if;

  select * into v_existing from public.registrations
   where session_id = p_session and user_id = p_user and kind = 'member' and status <> 'canceled';
  if found and v_existing.status = 'confirmed' then
    raise exception 'already_registered' using errcode = 'P0001';
  end if;

  v_confirmed := public.capacity_used(p_session);
  if v_confirmed >= s.capacity then
    update public.sessions set capacity = v_confirmed + 1 where id = p_session;
    v_raised := true;
  end if;

  if v_existing.id is not null then
    update public.registrations set status = 'confirmed', promoted_at = now() where id = v_existing.id;
    v_id := v_existing.id;
  else
    insert into public.registrations (session_id, kind, user_id, added_by, status)
    values (p_session, 'member', p_user, auth.uid(), 'confirmed')
    returning id into v_id;
  end if;

  perform public.log_activity(s.club_id, p_session, 'roster.add',
    jsonb_build_object('user_id', p_user, 'registration_id', v_id, 'from_waitlist', v_existing.id is not null,
                       'capacity_raised', v_raised));
  return v_id;
end;
$$;

create or replace function public.roster_remove(p_registration uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  r        public.registrations%rowtype;
  s        public.sessions%rowtype;
  v_queued int;
begin
  select * into r from public.registrations where id = p_registration;
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  s := public.lock_roster(r.session_id);
  select * into r from public.registrations where id = p_registration for update;
  if r.status = 'canceled' then
    raise exception 'already_canceled' using errcode = 'P0001';
  end if;

  update public.registrations set status = 'canceled', canceled_at = now() where id = p_registration;
  if r.status = 'confirmed' and public.counts_capacity(r.kind, s.guests_in_capacity) then
    perform public.promote_waitlist(r.session_id, 1);
  end if;

  select count(*) into v_queued
    from public.match_players mp join public.matches m on m.id = mp.match_id
   where mp.registration_id = p_registration and m.phase = 'scheduled' and m.status = 'queued';

  perform public.log_activity(s.club_id, r.session_id, 'roster.remove',
    jsonb_build_object('registration_id', p_registration, 'user_id', r.user_id, 'guest_name', r.guest_name,
                       'was', r.status, 'queued_matches', v_queued));
  return v_queued;
end;
$$;

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
       starts_at, ends_at, capacity, court_count, opens_at, guests_in_capacity)
    values
      (t.club_id, t.id, v_start, 'regular', t.title, t.place,
       v_start, v_end, t.capacity, t.court_count, v_open, t.guests_in_capacity)
    on conflict (template_id, template_slot) do nothing;

    if found then
      v_made := v_made + 1;
    end if;
  end loop;

  return v_made;
end;
$$;


drop function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean);
drop function public.create_flash(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz);
drop function public.create_tournament(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, int, int, int, int);


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
  p_active           boolean default true,
  p_guests_in_capacity boolean default false
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
       open_days_before, open_time, active, guests_in_capacity)
    values
      (p_club, btrim(p_title), p_weekday, p_start_time, p_end_time, coalesce(btrim(p_place), ''),
       p_capacity, p_court_count, p_open_days_before, p_open_time, coalesce(p_active, true),
       coalesce(p_guests_in_capacity, false))
    returning id into v_id;
  else
    update public.session_templates
       set title = btrim(p_title), weekday = p_weekday, start_time = p_start_time, end_time = p_end_time,
           place = coalesce(btrim(p_place), ''), capacity = p_capacity, court_count = p_court_count,
           open_days_before = p_open_days_before, open_time = p_open_time,
           active = coalesce(p_active, true), guests_in_capacity = coalesce(p_guests_in_capacity, false)
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

create or replace function public.create_flash(
  p_club        uuid,
  p_title       text,
  p_place       text,
  p_starts_at   timestamptz,
  p_ends_at     timestamptz,
  p_capacity    int,
  p_court_count int,
  p_opens_at    timestamptz default null,    -- null = 지금 바로 오픈
  p_guests_in_capacity boolean default false
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
    (club_id, type, host_user_id, title, place, starts_at, ends_at, capacity, court_count, opens_at, guests_in_capacity)
  values
    (p_club, 'flash', auth.uid(), btrim(p_title), coalesce(btrim(p_place), ''),
     p_starts_at, p_ends_at, p_capacity, p_court_count, v_open, coalesce(p_guests_in_capacity, false))
  returning id into v_id;

  perform public.log_activity(p_club, v_id, 'session.create_flash', '{}'::jsonb);
  return v_id;
end;
$$;

create or replace function public.create_tournament(
  p_club             uuid,
  p_title            text,
  p_place            text,
  p_starts_at        timestamptz,
  p_ends_at          timestamptz,
  p_capacity         int,
  p_court_count      int,
  p_opens_at         timestamptz,      -- null = 지금 바로 오픈
  p_round_count      int,
  p_score_target     int,
  p_score_cap        int,              -- null = 최대 점수 없음
  p_minutes_per_game int,
  p_guests_in_capacity boolean default false
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_open timestamptz := coalesce(p_opens_at, now());
  v_id   uuid;
begin
  if not public.is_club_admin(p_club) then
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
  if p_round_count is null or p_round_count not between 1 and 20 then
    raise exception 'invalid_round_count' using errcode = '22023';
  end if;
  if p_score_target is null or p_score_target not between 5 and 50
     or (p_score_cap is not null and (p_score_cap < p_score_target or p_score_cap > 60)) then
    raise exception 'invalid_score_rule' using errcode = '22023';
  end if;
  if p_minutes_per_game is null or p_minutes_per_game not between 5 and 60 then
    raise exception 'invalid_minutes' using errcode = '22023';
  end if;

  insert into public.sessions
    (club_id, type, host_user_id, title, place, starts_at, ends_at, capacity, court_count, opens_at,
     kind, tournament_state, round_count, score_target, score_cap, minutes_per_game, guests_in_capacity)
  values
    (p_club, 'flash', auth.uid(), coalesce(nullif(btrim(p_title), ''), '자체대회'), coalesce(btrim(p_place), ''),
     p_starts_at, p_ends_at, p_capacity, p_court_count, v_open,
     'tournament', 'draft', p_round_count, p_score_target, p_score_cap, p_minutes_per_game, coalesce(p_guests_in_capacity, false))
  returning id into v_id;

  perform public.log_activity(p_club, v_id, 'session.create_tournament',
    jsonb_build_object('round_count', p_round_count));
  return v_id;
end;
$$;


-- ---------------------------------------------------------------------
-- 게스트를 정원에 넣을지 바꾸기 (운영진 / 번개 개설자). 반환 = 이번에 확정된 인원
--   넣음으로: 이미 확정된 사람은 그대로 (정원을 넘어도 내보내지 않음). 이후 신청부터 같은 줄
--   안 넣음으로: 대기 중인 게스트는 모두 확정, 비게 된 자리만큼 대기 회원 승격
-- ---------------------------------------------------------------------
create or replace function public.set_guests_in_capacity(p_session uuid, p_on boolean)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s          public.sessions%rowtype;
  v_promoted int := 0;
  v_guests   int := 0;
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
  if coalesce(p_on, false) = s.guests_in_capacity then
    return 0;
  end if;

  update public.sessions set guests_in_capacity = coalesce(p_on, false) where id = p_session;

  if not coalesce(p_on, false) then
    update public.registrations set status = 'confirmed', promoted_at = now()
     where session_id = p_session and kind = 'guest' and status = 'waitlisted';
    get diagnostics v_guests = row_count;
    v_promoted := public.promote_waitlist(p_session, s.capacity - public.capacity_used(p_session));
  end if;

  perform public.log_activity(s.club_id, p_session, 'session.guests_in_capacity',
    jsonb_build_object('on', coalesce(p_on, false), 'promoted', v_promoted + v_guests));
  return v_promoted + v_guests;
end;
$$;

-- ---------------------------------------------------------------------
-- 투표 화면에서 게스트 데려오기
--   반환: registration_id, status(confirmed|waitlisted), queue_position
-- ---------------------------------------------------------------------
create or replace function public.add_vote_guest(p_session uuid, p_name text, p_gender text default null)
returns table (registration_id uuid, status public.registration_status, queue_position int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  s         public.sessions%rowtype;
  v_manager boolean;
  v_status  public.registration_status;
  v_id      uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;

  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_member(s.club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if s.kind = 'tournament' and s.tournament_state is distinct from 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;

  v_manager := public.can_manage_session(s);
  if v_manager then
    if now() >= s.ends_at then
      raise exception 'closed' using errcode = 'P0001';
    end if;
  else
    if now() < s.opens_at then
      raise exception 'not_open' using errcode = 'P0001';
    end if;
    if now() >= s.starts_at then
      raise exception 'closed' using errcode = 'P0001';
    end if;
    if (select count(*) from public.registrations x
         where x.session_id = p_session and x.kind = 'guest' and x.added_by = v_uid and x.status <> 'canceled') >= 3 then
      raise exception 'guest_limit' using errcode = 'P0001';
    end if;
  end if;

  v_status := case when not s.guests_in_capacity or public.capacity_used(p_session) < s.capacity
                   then 'confirmed'::public.registration_status
                   else 'waitlisted'::public.registration_status end;

  insert into public.registrations (session_id, kind, guest_name, guest_gender, added_by, status)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, v_uid, v_status)
  returning id into v_id;

  perform public.log_activity(s.club_id, p_session, 'registration.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'status', v_status));

  return query select v_id, v_status,
    case when s.guests_in_capacity then public.registration_position(v_id) else null end;
end;
$$;



-- 일정 목록 뷰: 확정·대기 인원 = 정원을 차지하는 사람 (게스트 포함 설정이면 게스트도). guest_count는 전체 게스트
create or replace view public.session_overview
with (security_invoker = true)
as
select
  s.id, s.club_id, s.template_id, s.type, s.host_user_id, s.title, s.place,
  s.starts_at, s.ends_at, s.capacity, s.court_count, s.opens_at, s.canceled_at,
  coalesce(c.confirmed, 0)::int  as confirmed_count,
  coalesce(c.waitlisted, 0)::int as waitlist_count,
  coalesce(c.guests, 0)::int     as guest_count,
  me.id                          as my_registration_id,
  me.status                      as my_status,
  s.kind,
  s.tournament_state,
  s.round_count,
  s.score_target,
  s.score_cap,
  s.minutes_per_game,
  s.guests_in_capacity
from public.sessions s
left join lateral (
  select count(*) filter (where public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'confirmed')  as confirmed,
         count(*) filter (where public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'waitlisted') as waitlisted,
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



revoke execute on function public.counts_capacity(public.registration_kind, boolean) from public, anon;
grant  execute on function public.counts_capacity(public.registration_kind, boolean) to authenticated;
revoke execute on function public.capacity_used(uuid)                       from public, anon, authenticated;
revoke execute on function public.promote_waitlist(uuid, int)               from public, anon, authenticated;
revoke execute on function public.registration_position(uuid)               from public, anon, authenticated;
revoke execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean) from public, anon, authenticated;
revoke execute on function public.create_flash(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, boolean) from public, anon, authenticated;
revoke execute on function public.create_tournament(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, int, int, int, int, boolean) from public, anon, authenticated;
revoke execute on function public.set_guests_in_capacity(uuid, boolean)     from public, anon, authenticated;
revoke execute on function public.add_vote_guest(uuid, text, text)          from public, anon, authenticated;
grant execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean) to authenticated;
grant execute on function public.create_flash(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, boolean) to authenticated;
grant execute on function public.create_tournament(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, int, int, int, int, boolean) to authenticated;
grant execute on function public.set_guests_in_capacity(uuid, boolean)      to authenticated;
grant execute on function public.add_vote_guest(uuid, text, text)           to authenticated;
