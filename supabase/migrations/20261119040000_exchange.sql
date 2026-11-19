-- =====================================================================
-- T5 교류전: 두 동아리가 함께 하는 대회 (자체대회와 같은 대진·점수·코트 고정 규칙)
--
--   * 주최 동아리 운영진이 만들고 상대 동아리를 초대 → 상대 운영진이 수락해야 상대 회원에게 보인다
--   * 정원은 동아리별: sessions.capacity = 주최, sessions.partner_capacity = 상대
--     각 신청은 registrations.side_club_id(어느 편인지)를 갖는다. 일반 운동은 null = 주최 동아리
--   * 경기는 항상 주최 2명 vs 상대 2명 (save_schedule이 검사, 교체도 같은 편끼리만)
--   * 대진 짜기·공개·대회 설정·기권·조기 종료는 주최 운영진만.
--     상대 운영진은 자기 편 명단 관리(추가·빼기·게스트)와 점수 수정, 상대 정원 변경
--   * 알림 이동 경로는 받는 사람 동아리 기준 (/c/<내 동아리>/s/<운동>)
-- =====================================================================

alter table public.sessions
  add column partner_club_id  uuid references public.clubs(id) on delete set null,
  add column partner_status   text check (partner_status in ('invited', 'accepted', 'declined')),
  add column partner_capacity int check (partner_capacity > 0),
  add constraint sessions_partner_exchange check (partner_club_id is null or kind = 'exchange'),
  add constraint sessions_partner_not_self check (partner_club_id is distinct from club_id);
create index sessions_partner_idx on public.sessions (partner_club_id) where partner_club_id is not null;

alter table public.registrations add column side_club_id uuid references public.clubs(id) on delete set null;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next',
                  'club_request', 'club_decided', 'club_deleted', 'exchange_invite', 'exchange_reply'));

-- ---------------------------------------------------------------------
-- 도우미
-- ---------------------------------------------------------------------
-- 이 운동을 볼 수 있는가: 주최 회원 / 수락한 상대 회원 / (초대 중·거절) 상대 운영진
create or replace function public.can_see_session(p_session uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.sessions s
     where s.id = p_session
       and (public.is_club_member(s.club_id)
            or (s.kind = 'exchange' and s.partner_club_id is not null
                and ((s.partner_status = 'accepted' and public.is_club_member(s.partner_club_id))
                     or public.is_club_admin(s.partner_club_id))))
  );
$$;

-- 수락된 교류전의 상대 동아리 (아니면 null)
create or replace function public.active_partner(p_session uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select s.partner_club_id from public.sessions s
   where s.id = p_session and s.kind = 'exchange' and s.partner_status = 'accepted';
$$;

-- 이 사람이 이 운동에서 어느 편인가: 주최 회원이면 주최, 아니면 수락된 상대 동아리 회원이면 상대, 둘 다 아니면 null
create or replace function public.side_of_user(p_session uuid, p_user uuid)
returns uuid
language sql stable security definer set search_path = ''
as $$
  select case
    when exists (select 1 from public.club_members m
                  where m.club_id = s.club_id and m.user_id = p_user and m.status = 'approved') then s.club_id
    when s.kind = 'exchange' and s.partner_status = 'accepted'
         and exists (select 1 from public.club_members m
                      where m.club_id = s.partner_club_id and m.user_id = p_user and m.status = 'approved') then s.partner_club_id
  end
    from public.sessions s where s.id = p_session;
$$;

-- 편의 운영진인가 (주최 운영진은 양쪽 모두, 상대 운영진은 상대 편만)
create or replace function public.is_side_admin(p_session uuid, p_side uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1 from public.sessions s
     where s.id = p_session
       and (public.is_club_admin(s.club_id)
            or (s.kind = 'exchange' and s.partner_status = 'accepted'
                and p_side = s.partner_club_id and public.is_club_admin(s.partner_club_id)))
  );
$$;

-- 편 정원
create or replace function public.side_capacity(p_session uuid, p_side uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select case when s.kind = 'exchange' and p_side = s.partner_club_id then s.partner_capacity else s.capacity end
    from public.sessions s where s.id = p_session;
$$;

-- 편 정원을 차지한 확정 인원
create or replace function public.capacity_used_side(p_session uuid, p_side uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
    from public.registrations r join public.sessions s on s.id = r.session_id
   where r.session_id = p_session and r.status = 'confirmed'
     and coalesce(r.side_club_id, s.club_id) = p_side
     and public.counts_capacity(r.kind, s.guests_in_capacity);
$$;

-- 주최 편 (일반 운동이면 전체) 사용 인원. update_capacity 등 주최 정원 계산용
create or replace function public.capacity_used(p_session uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select public.capacity_used_side(p_session, (select club_id from public.sessions where id = p_session));
$$;

-- 대기 승격: 편마다 빈자리만큼 seq 순서대로. p_slots는 예전 호출 호환용(무시) — 항상 실제 빈자리로 계산
create or replace function public.promote_waitlist(p_session uuid, p_slots int)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s       public.sessions%rowtype;
  v_side  uuid;
  v_free  int;
  v_n     int;
  v_count int := 0;
begin
  select * into s from public.sessions where id = p_session;
  foreach v_side in array array_remove(array[s.club_id,
      case when s.kind = 'exchange' and s.partner_status = 'accepted' then s.partner_club_id end], null) loop
    v_free := public.side_capacity(p_session, v_side) - public.capacity_used_side(p_session, v_side);
    continue when v_free is null or v_free <= 0;
    with next_up as (
      select r.id from public.registrations r
       where r.session_id = p_session and r.status = 'waitlisted'
         and coalesce(r.side_club_id, s.club_id) = v_side
         and public.counts_capacity(r.kind, s.guests_in_capacity)
       order by r.seq
       limit v_free
       for update of r
    )
    update public.registrations r set status = 'confirmed', promoted_at = now()
      from next_up where r.id = next_up.id;
    get diagnostics v_n = row_count;
    v_count := v_count + v_n;
  end loop;
  return v_count;
end;
$$;

-- 순번: 같은 편 안에서
create or replace function public.registration_position(p_registration uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
    from public.registrations me
    join public.sessions s on s.id = me.session_id
    join public.registrations other
      on other.session_id = me.session_id
     and coalesce(other.side_club_id, s.club_id) = coalesce(me.side_club_id, s.club_id)
     and public.counts_capacity(other.kind, s.guests_in_capacity)
     and other.status = me.status
     and other.seq <= me.seq
   where me.id = p_registration;
$$;

-- 명단 관리 잠금: 대회(자체대회·교류전), 끝나지 않음, 그 편의 운영진
create or replace function public.lock_roster_side(p_session uuid, p_side uuid)
returns public.sessions
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_side_admin(p_session, coalesce(p_side, s.club_id)) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if s.kind = 'normal' then
    raise exception 'not_tournament' using errcode = 'P0001';
  end if;
  if s.tournament_state = 'finished' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  return s;
end;
$$;

-- ---------------------------------------------------------------------
-- 볼 권한·조작 권한
-- ---------------------------------------------------------------------
drop policy sessions_select on public.sessions;
create policy sessions_select on public.sessions
  for select to authenticated using (
    public.is_club_member(club_id)
    or (kind = 'exchange' and partner_club_id is not null
        and ((partner_status = 'accepted' and public.is_club_member(partner_club_id))
             or public.is_club_admin(partner_club_id))));

drop policy registrations_select on public.registrations;
create policy registrations_select on public.registrations
  for select to authenticated using (public.can_see_session(session_id));

-- 이름: 같은 동아리 + 같이 보이는 교류전에 신청한 사람
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
      )
      or exists (
        select 1 from public.registrations r join public.sessions s on s.id = r.session_id
         where r.user_id = p_user and s.kind = 'exchange' and r.status <> 'canceled'
           and public.can_see_session(s.id)
      );
$$;

create or replace function public.can_view_match(p_match uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match
       and public.can_see_session(s.id)
       and (m.phase = 'free'
            or s.tournament_state is distinct from 'draft'
            or public.is_club_admin(s.club_id))
  );
$$;

-- 대진판: 운영진(주최·수락한 상대)은 언제나, 참석 확정자는 시작 3시간 전 ~ 끝나고 3시간
create or replace function public.can_operate_board(p_session uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
           select 1 from public.sessions s
            where s.id = p_session
              and (public.is_club_admin(s.club_id)
                   or (s.kind = 'exchange' and s.partner_status = 'accepted' and public.is_club_admin(s.partner_club_id)))
         )
      or exists (
           select 1
             from public.registrations r
             join public.sessions s on s.id = r.session_id
            where r.session_id = p_session and r.user_id = auth.uid()
              and r.kind = 'member' and r.status = 'confirmed'
              and public.is_club_member(coalesce(r.side_club_id, s.club_id))
              and now() >= s.starts_at - interval '3 hours'
              and now() <  s.ends_at   + interval '3 hours'
         );
$$;

-- 점수: 운영진(주최·수락한 상대)은 언제나, 선수는 대회 중이거나 아직 결과가 없을 때
create or replace function public.can_score_match(p_match uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match and m.phase = 'scheduled'
       and (
         public.is_club_admin(s.club_id)
         or (s.kind = 'exchange' and s.partner_status = 'accepted' and public.is_club_admin(s.partner_club_id))
         or ((s.tournament_state in ('published', 'in_progress') or m.result_at is null)
             and exists (select 1 from public.match_players mp
                           join public.registrations r on r.id = mp.registration_id
                          where mp.match_id = m.id and r.user_id = auth.uid() and r.kind = 'member'))
       )
  );
$$;

-- ---------------------------------------------------------------------
-- 신청 (편마다 정원)
-- ---------------------------------------------------------------------
create or replace function public.register(p_session uuid, p_late_eta time default null)
returns table (registration_id uuid, status public.registration_status, queue_position int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  s         public.sessions%rowtype;
  v_side    uuid;
  v_status  public.registration_status;
  v_reg_id  uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;

  select * into s from public.sessions x where x.id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  v_side := public.side_of_user(p_session, v_uid);
  if v_side is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if now() < s.opens_at then
    raise exception 'not_open' using errcode = 'P0001';
  end if;
  if now() >= s.starts_at then
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

  v_status := case when public.capacity_used_side(p_session, v_side) < public.side_capacity(p_session, v_side)
                   then 'confirmed'::public.registration_status
                   else 'waitlisted'::public.registration_status end;

  insert into public.registrations (session_id, kind, user_id, added_by, status, late_eta, side_club_id)
  values (p_session, 'member', v_uid, v_uid, v_status, p_late_eta,
          case when s.kind = 'exchange' then v_side end)
  returning id into v_reg_id;

  perform public.log_activity(s.club_id, p_session, 'registration.create',
    jsonb_build_object('registration_id', v_reg_id, 'status', v_status, 'side', v_side));

  return query select v_reg_id, v_status, public.registration_position(v_reg_id);
end;
$$;

-- 투표 화면 게스트: 데려온 사람의 편
create or replace function public.add_vote_guest(p_session uuid, p_name text, p_gender text default null, p_level text default null)
returns table (registration_id uuid, status public.registration_status, queue_position int)
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid     uuid := auth.uid();
  s         public.sessions%rowtype;
  v_side    uuid;
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
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;

  select * into s from public.sessions x where x.id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  v_side := public.side_of_user(p_session, v_uid);
  if v_side is null then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  if s.kind <> 'normal' and s.tournament_state is distinct from 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;

  v_manager := public.can_manage_session(s) or public.is_side_admin(p_session, v_side);
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

  v_status := case when not s.guests_in_capacity
                     or public.capacity_used_side(p_session, v_side) < public.side_capacity(p_session, v_side)
                   then 'confirmed'::public.registration_status
                   else 'waitlisted'::public.registration_status end;

  insert into public.registrations (session_id, kind, guest_name, guest_gender, guest_level, added_by, status, side_club_id)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, p_level, v_uid, v_status,
          case when s.kind = 'exchange' then v_side end)
  returning id into v_id;

  perform public.log_activity(s.club_id, p_session, 'registration.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'status', v_status));

  return query select v_id, v_status,
    case when s.guests_in_capacity then public.registration_position(v_id) else null end;
end;
$$;

-- 대진판(현장) 게스트: 추가한 사람의 편 (주최 운영진이 넣으면 주최)
create or replace function public.add_guest(p_session uuid, p_name text, p_gender text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_club uuid;
  v_kind text;
  v_side uuid;
  v_id   uuid;
begin
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  v_club := public.lock_board(p_session);
  select kind into v_kind from public.sessions where id = p_session;
  v_side := coalesce(public.side_of_user(p_session, auth.uid()), v_club);

  insert into public.registrations (session_id, kind, guest_name, guest_gender, added_by, status, checked_in_at, side_club_id)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, auth.uid(), 'confirmed', now(),
          case when v_kind = 'exchange' then v_side end)
  returning id into v_id;

  perform public.log_activity(v_club, p_session, 'board.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'gender', p_gender));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 명단 관리 (자체대회·교류전). 상대 운영진은 상대 편만
-- ---------------------------------------------------------------------
create or replace function public.roster_add_member(p_session uuid, p_user uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s          public.sessions%rowtype;
  v_side     uuid;
  v_existing public.registrations%rowtype;
  v_id       uuid;
  v_raised   boolean := false;
begin
  v_side := public.side_of_user(p_session, p_user);
  if v_side is null then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  s := public.lock_roster_side(p_session, v_side);

  select * into v_existing from public.registrations
   where session_id = p_session and user_id = p_user and kind = 'member' and status <> 'canceled';
  if found and v_existing.status = 'confirmed' then
    raise exception 'already_registered' using errcode = 'P0001';
  end if;

  if public.capacity_used_side(p_session, v_side) >= public.side_capacity(p_session, v_side) then
    if s.kind = 'exchange' and v_side = s.partner_club_id then
      update public.sessions set partner_capacity = public.capacity_used_side(p_session, v_side) + 1 where id = p_session;
    else
      update public.sessions set capacity = public.capacity_used_side(p_session, v_side) + 1 where id = p_session;
    end if;
    v_raised := true;
  end if;

  if v_existing.id is not null then
    update public.registrations set status = 'confirmed', promoted_at = now() where id = v_existing.id;
    v_id := v_existing.id;
  else
    insert into public.registrations (session_id, kind, user_id, added_by, status, side_club_id)
    values (p_session, 'member', p_user, auth.uid(), 'confirmed', case when s.kind = 'exchange' then v_side end)
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
  s := public.lock_roster_side(r.session_id, r.side_club_id);
  select * into r from public.registrations where id = p_registration for update;
  if r.status = 'canceled' then
    raise exception 'already_canceled' using errcode = 'P0001';
  end if;

  update public.registrations set status = 'canceled', canceled_at = now() where id = p_registration;
  perform public.promote_waitlist(r.session_id, 0);

  select count(*) into v_queued
    from public.match_players mp join public.matches m on m.id = mp.match_id
   where mp.registration_id = p_registration and m.phase = 'scheduled' and m.status = 'queued';

  perform public.log_activity(s.club_id, r.session_id, 'roster.remove',
    jsonb_build_object('registration_id', p_registration, 'user_id', r.user_id, 'guest_name', r.guest_name,
                       'was', r.status, 'queued_matches', v_queued));
  return v_queued;
end;
$$;

-- 게스트 미리 추가: p_side가 없으면 부른 운영진의 편 (주최 운영진이 상대 편에 넣으려면 p_side)
drop function public.roster_add_guest(uuid, text, text, text);
create or replace function public.roster_add_guest(p_session uuid, p_name text, p_gender text, p_level text, p_side uuid default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s      public.sessions%rowtype;
  v_side uuid;
  v_id   uuid;
begin
  v_side := coalesce(p_side, public.side_of_user(p_session, auth.uid()),
                     (select club_id from public.sessions where id = p_session));
  if v_side not in (select club_id from public.sessions where id = p_session
                    union all select partner_club_id from public.sessions where id = p_session and partner_status = 'accepted') then
    raise exception 'invalid_side' using errcode = '22023';
  end if;
  s := public.lock_roster_side(p_session, v_side);
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;

  insert into public.registrations (session_id, kind, guest_name, guest_gender, guest_level, added_by, status, side_club_id)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, p_level, auth.uid(), 'confirmed',
          case when s.kind = 'exchange' then v_side end)
  returning id into v_id;

  perform public.log_activity(s.club_id, p_session, 'roster.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'side', v_side));
  return v_id;
end;
$$;

-- 이전 lock_roster(주최 운영진 전용)는 lock_roster_side로 대체
create or replace function public.lock_roster(p_session uuid)
returns public.sessions
language plpgsql security definer set search_path = ''
as $$
begin
  return public.lock_roster_side(p_session, null);
end;
$$;

-- 게스트 성별·급수: 그 편의 운영진
create or replace function public.set_guest_gender(p_registration uuid, p_gender text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.registrations%rowtype;
  v_club uuid;
begin
  select * into r from public.registrations where id = p_registration and kind = 'guest';
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  if not public.is_side_admin(r.session_id, coalesce(r.side_club_id, public.session_club_id(r.session_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  update public.registrations set guest_gender = p_gender where id = p_registration;
  v_club := public.session_club_id(r.session_id);
  perform public.log_activity(v_club, r.session_id, 'board.set_guest_gender', jsonb_build_object('registration_id', p_registration, 'gender', p_gender));
end;
$$;

create or replace function public.set_guest_level(p_registration uuid, p_level text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  r public.registrations%rowtype;
begin
  select * into r from public.registrations where id = p_registration and kind = 'guest';
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  if not public.is_side_admin(r.session_id, coalesce(r.side_club_id, public.session_club_id(r.session_id))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;
  update public.registrations set guest_level = p_level where id = p_registration;
end;
$$;

-- ---------------------------------------------------------------------
-- 기존 함수 수정 (취소 승격, 대회 종류, 교류전 편 검사, 알림 경로)
-- ---------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.cancel_registration(p_registration uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
    or public.is_side_admin(v_reg.session_id, coalesce(v_reg.side_club_id, v_club))
    or (v_reg.kind = 'guest' and public.can_see_session(v_reg.session_id)
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

  -- 정원을 차지하던 확정자가 빠지면 같은 편 대기 1순위 승격 (게스트 포함 설정이면 게스트도)
  if v_reg.status = 'confirmed' and public.promote_waitlist(v_reg.session_id, 1) > 0 then
    select r2.id into v_promoted from public.registrations r2
     where r2.session_id = v_reg.session_id and r2.promoted_at = now()
     order by r2.seq limit 1;
  end if;

  perform public.log_activity(v_club, v_reg.session_id, 'registration.cancel',
    jsonb_build_object('registration_id', p_registration,
                       'was', v_reg.status,
                       'promoted', v_promoted));
  return v_promoted;
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_tournament_settings(p_session uuid, p_round_count integer, p_score_target integer, p_score_cap integer, p_minutes_per_game integer)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s           public.sessions%rowtype;
  v_scored    boolean;
  v_max_round int;
begin
  s := public.lock_tournament(p_session);
  if s.kind = 'normal' then
    raise exception 'not_tournament' using errcode = 'P0001';
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
  if s.tournament_state = 'finished' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;

  if s.tournament_state <> 'draft' and p_round_count <> s.round_count then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  select max(round_no) into v_max_round from public.matches where session_id = p_session and phase = 'scheduled';
  if v_max_round is not null and p_round_count < v_max_round then
    raise exception 'rounds_in_use' using errcode = 'P0001';
  end if;
  select exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled' and result_at is not null)
    into v_scored;
  if v_scored and (p_score_target <> s.score_target or p_score_cap is distinct from s.score_cap) then
    raise exception 'score_rule_locked' using errcode = 'P0001';
  end if;

  update public.sessions
     set round_count = p_round_count, score_target = p_score_target,
         score_cap = p_score_cap, minutes_per_game = p_minutes_per_game
   where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.settings',
    jsonb_build_object('round_count', p_round_count, 'score_target', p_score_target, 'score_cap', p_score_cap));
end;
$function$;

CREATE OR REPLACE FUNCTION public.save_schedule(p_session uuid, p_matches jsonb)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s       public.sessions%rowtype;
  v_n     int;
  v_bad   int;
  rec     record;
  v_match uuid;
begin
  s := public.lock_tournament(p_session);
  if s.kind = 'normal' or s.tournament_state <> 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_matches) <> 'array' then
    raise exception 'invalid_schedule' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_matches);
  if v_n > 400 then
    raise exception 'invalid_schedule' using errcode = '22023';
  end if;

  drop table if exists _sched_m, _sched_p;
  create temp table _sched_m (idx int, round_no int, order_no int) on commit drop;
  create temp table _sched_p (idx int, round_no int, team int, reg uuid) on commit drop;

  begin
    insert into _sched_m
    select ord::int, (e ->> 'round')::int, (e ->> 'order')::int
      from jsonb_array_elements(p_matches) with ordinality t(e, ord);

    insert into _sched_p
    select ord::int, (e ->> 'round')::int, 1, x::uuid
      from jsonb_array_elements(p_matches) with ordinality t(e, ord),
           jsonb_array_elements_text(coalesce(e -> 'team1', '[]'::jsonb)) x
    union all
    select ord::int, (e ->> 'round')::int, 2, x::uuid
      from jsonb_array_elements(p_matches) with ordinality t(e, ord),
           jsonb_array_elements_text(coalesce(e -> 'team2', '[]'::jsonb)) x;
  exception when others then
    raise exception 'invalid_schedule' using errcode = '22023';
  end;

  -- 매치·순서
  if exists (select 1 from _sched_m where round_no is null or order_no is null or order_no < 1
                or round_no < 1 or round_no > coalesce(s.round_count, 0)) then
    raise exception 'invalid_round' using errcode = '22023';
  end if;
  if exists (select 1 from _sched_m group by round_no, order_no having count(*) > 1) then
    raise exception 'duplicate_order' using errcode = '22023';
  end if;
  -- 경기당 팀별 2명, 서로 다른 4명
  if exists (
       select 1 from _sched_m m
        where (select count(*) from _sched_p p where p.idx = m.idx and p.team = 1) <> 2
           or (select count(*) from _sched_p p where p.idx = m.idx and p.team = 2) <> 2
           or (select count(distinct reg) from _sched_p p where p.idx = m.idx) <> 4) then
    raise exception 'need_four_players' using errcode = '22023';
  end if;
  -- 모두 이 운동의 참석 확정자
  select count(*) into v_bad from _sched_p p
   where not exists (select 1 from public.registrations r
                      where r.id = p.reg and r.session_id = p_session and r.status = 'confirmed');
  if v_bad > 0 then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  -- 교류전: 한 팀은 한 편, 두 팀은 서로 다른 편 (주최 2명 vs 상대 2명)
  if s.kind = 'exchange' and exists (
       select 1 from _sched_m m
        where (select count(distinct coalesce(r.side_club_id, s.club_id)) from _sched_p p join public.registrations r on r.id = p.reg
                where p.idx = m.idx and p.team = 1) <> 1
           or (select count(distinct coalesce(r.side_club_id, s.club_id)) from _sched_p p join public.registrations r on r.id = p.reg
                where p.idx = m.idx and p.team = 2) <> 1
           or (select count(distinct coalesce(r.side_club_id, s.club_id)) from _sched_p p join public.registrations r on r.id = p.reg
                where p.idx = m.idx) <> 2) then
    raise exception 'exchange_sides' using errcode = '22023';
  end if;
  -- 같은 매치에 같은 사람 한 번
  if exists (select 1 from _sched_p group by round_no, reg having count(*) > 1) then
    raise exception 'duplicate_in_round' using errcode = '22023';
  end if;

  delete from public.matches where session_id = p_session and phase = 'scheduled';

  for rec in select * from _sched_m order by round_no, order_no loop
    insert into public.matches (session_id, phase, round_no, order_no, status, created_by)
    values (p_session, 'scheduled', rec.round_no, rec.order_no, 'queued', auth.uid())
    returning id into v_match;
    insert into public.match_players (match_id, registration_id, team)
    select v_match, p.reg, p.team from _sched_p p where p.idx = rec.idx;
  end loop;

  perform public.log_activity(s.club_id, p_session, 'tournament.save_schedule', jsonb_build_object('matches', v_n));
  return v_n;
end;
$function$;

CREATE OR REPLACE FUNCTION public.publish_schedule(p_session uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.sessions%rowtype;
begin
  s := public.lock_tournament(p_session);
  if s.kind = 'normal' or s.tournament_state <> 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  if s.kind = 'exchange' and s.partner_status is distinct from 'accepted' then
    raise exception 'partner_not_accepted' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled') then
    raise exception 'empty_schedule' using errcode = 'P0001';
  end if;
  -- 초안을 만든 뒤 참석을 취소한 사람이 있으면 먼저 고쳐야 한다
  if exists (
       select 1 from public.match_players mp
         join public.matches m on m.id = mp.match_id
         join public.registrations r on r.id = mp.registration_id
        where m.session_id = p_session and m.phase = 'scheduled' and r.status <> 'confirmed') then
    raise exception 'schedule_stale' using errcode = 'P0001';
  end if;

  -- 대회 중엔 대회 경기만: 대기 중인 자율 경기는 정리 (진행 중인 자율 경기는 끝까지)
  update public.matches set status = 'canceled', queue_pos = null, finished_at = now()
   where session_id = p_session and phase = 'free' and status = 'queued';

  update public.sessions set tournament_state = 'published' where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.publish', '{}'::jsonb);
  perform public.fill_courts(p_session);
end;
$function$;

CREATE OR REPLACE FUNCTION public.substitute_player(p_match uuid, p_out uuid, p_in uuid)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  m public.matches%rowtype;
  s public.sessions%rowtype;
begin
  select * into m from public.matches where id = p_match;
  if not found then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  s := public.lock_tournament(m.session_id);
  select * into m from public.matches where id = p_match for update;

  if m.phase <> 'scheduled' or m.status <> 'queued' or s.tournament_state = 'finished' then
    raise exception 'not_substitutable' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.match_players where match_id = p_match and registration_id = p_out) then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  if not exists (select 1 from public.registrations
                  where id = p_in and session_id = m.session_id and status = 'confirmed') then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  -- 교류전: 같은 편끼리만
  if s.kind = 'exchange' and (select side_club_id from public.registrations where id = p_in)
                             is distinct from (select side_club_id from public.registrations where id = p_out) then
    raise exception 'exchange_sides' using errcode = '22023';
  end if;
  if exists (
       select 1 from public.match_players mp
         join public.matches o on o.id = mp.match_id
        where mp.registration_id = p_in and o.session_id = m.session_id
          and o.phase = 'scheduled' and o.round_no = m.round_no and o.status <> 'canceled') then
    raise exception 'duplicate_in_round' using errcode = '22023';
  end if;

  update public.match_players set registration_id = p_in
   where match_id = p_match and registration_id = p_out;

  perform public.log_activity(s.club_id, m.session_id, 'tournament.substitute',
    jsonb_build_object('match_id', p_match, 'out', p_out, 'in', p_in));
  perform public.fill_courts(m.session_id);
end;
$function$;

CREATE OR REPLACE FUNCTION public.sessions_notify_created()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  c       public.clubs%rowtype;
  v_tz    text;
  v_label text;
  v_body  text;
begin
  begin
    if new.canceled_at is not null or new.ends_at <= now() then
      return null;
    end if;
    select * into c from public.clubs where id = new.club_id;
    v_tz := coalesce(c.timezone, 'Asia/Seoul');
    v_label := case when new.kind = 'tournament' then '자체대회' when new.kind = 'exchange' then '교류전' when new.type = 'flash' then '번개' else '운동' end;
    v_body := new.title || ', ' || public.fmt_when(new.starts_at, v_tz) ||
              case when new.opens_at <= now() then '. 지금 투표 중이에요'
                   else '. 투표는 ' || public.fmt_when(new.opens_at, v_tz) || '에 열려요' end;

    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, new.club_id, new.id, 'vote_created', c.name || ' 새 ' || v_label, v_body,
           '/c/' || new.club_id || '/s/' || new.id
      from public.club_members m
     where m.club_id = new.club_id and m.status = 'approved'
       -- 번개·자체대회를 연 사람은 빼고, 정기운동(자동 생성, host 없음)은 모두에게
       and m.user_id is distinct from new.host_user_id
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_created');
  exception when others then
    -- 알림 때문에 원래 작업(가입·운동 생성·코트 배정)이 실패하면 안 된다
    raise warning 'sessions_notify_created failed: %', sqlerrm;
  end;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.enqueue_vote_soon()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s       record;
  v_count int := 0;
begin
  for s in
    update public.sessions x
       set vote_soon_notified_at = now()
     where x.vote_soon_notified_at is null and x.canceled_at is null
       and x.opens_at > now() and x.opens_at <= now() + interval '10 minutes'
    returning x.id, x.club_id, x.title, x.opens_at, x.starts_at,
              case when x.kind = 'exchange' and x.partner_status = 'accepted' then x.partner_club_id end as partner_club_id
  loop
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, m.club_id, s.id, 'vote_soon',
           ceil(extract(epoch from (s.opens_at - now())) / 60)::int || '분 뒤 투표 오픈',
           s.title || ' (' || public.fmt_when(s.starts_at, coalesce(c.timezone, 'Asia/Seoul')) || ') 투표가 ' ||
             to_char(s.opens_at at time zone coalesce(c.timezone, 'Asia/Seoul'), 'HH24:MI') || '에 열려요. 선착순이에요',
           '/c/' || m.club_id || '/s/' || s.id
      from public.club_members m
      join public.clubs c on c.id = m.club_id
     where m.club_id in (s.club_id, s.partner_club_id) and m.status = 'approved'
       -- 두 동아리 모두 회원이면 주최 쪽으로 한 번만
       and not coalesce(m.club_id = s.partner_club_id
                and exists (select 1 from public.club_members h where h.club_id = s.club_id and h.user_id = m.user_id and h.status = 'approved'), false)
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_soon');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

CREATE OR REPLACE FUNCTION public.matches_notify_court()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  p       record;
  v_club  uuid;
  v_title text;
  v_teams boolean;
begin
  begin
    if new.status <> 'playing' or (tg_op = 'UPDATE' and old.status = 'playing') then
      return null;
    end if;
    select club_id into v_club from public.sessions where id = new.session_id;
    v_title := '코트 ' || new.court_no || '에서 경기 시작' ||
               case when new.phase = 'scheduled' then ' (매치 ' || new.round_no || ')' else '' end;
    select bool_and(team is not null) into v_teams from public.match_players where match_id = new.id;

    for p in
      select mp.registration_id, mp.team, r.user_id, r.side_club_id
        from public.match_players mp join public.registrations r on r.id = mp.registration_id
       where mp.match_id = new.id and r.kind = 'member'
    loop
      perform public.notify(p.user_id, v_club, new.session_id, 'court_assigned', v_title,
        case when coalesce(v_teams, false) then
          '파트너 ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                                  from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                                  left join public.profiles pr on pr.id = r2.user_id
                                 where mp2.match_id = new.id and mp2.team = p.team and mp2.registration_id <> p.registration_id), '-') ||
          ', 상대 ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                                from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                                left join public.profiles pr on pr.id = r2.user_id
                               where mp2.match_id = new.id and mp2.team <> p.team), '-')
        else
          '함께: ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                               from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                               left join public.profiles pr on pr.id = r2.user_id
                              where mp2.match_id = new.id and mp2.registration_id <> p.registration_id), '-')
        end,
        '/c/' || coalesce(p.side_club_id, v_club) || '/s/' || new.session_id || '/board');
    end loop;
  exception when others then
    raise warning 'matches_notify_court failed: %', sqlerrm;
  end;
  return null;
end;
$function$;

CREATE OR REPLACE FUNCTION public.notify_court_next(p_session uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_courts int;
  v_club   uuid;
  v_court  int;
  v_match  public.matches%rowtype;
  p        record;
  v_count  int := 0;
begin
  begin
    select court_count, club_id into v_courts, v_club from public.sessions
     where id = p_session and tournament_state in ('published', 'in_progress') and canceled_at is null;
    if v_courts is null then
      return 0;
    end if;

    for v_court in 1..v_courts loop
      continue when not exists (
        select 1 from public.matches
         where session_id = p_session and status = 'playing' and court_no = v_court
      );

      select m.* into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'scheduled'
         and public.scheduled_court(m.order_no, v_courts) = v_court
       order by m.round_no, m.order_no, m.created_at
       limit 1;
      continue when v_match.id is null or v_match.next_notified_at is not null;

      update public.matches set next_notified_at = now() where id = v_match.id;

      for p in
        select mp.registration_id, mp.team, r.user_id, r.side_club_id
          from public.match_players mp join public.registrations r on r.id = mp.registration_id
         where mp.match_id = v_match.id and r.kind = 'member'
      loop
        perform public.notify(p.user_id, v_club, p_session, 'court_next',
          '코트 ' || v_court || ' 다음 경기 (매치 ' || v_match.round_no || ')',
          '지금 경기가 끝나면 바로 들어가요. 파트너 ' ||
            coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ' order by r2.seq)
                        from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                        left join public.profiles pr on pr.id = r2.user_id
                       where mp2.match_id = v_match.id and mp2.team = p.team and mp2.registration_id <> p.registration_id), '-') ||
            ', 상대 ' ||
            coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ' order by r2.seq)
                        from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                        left join public.profiles pr on pr.id = r2.user_id
                       where mp2.match_id = v_match.id and mp2.team is distinct from p.team), '-'),
          '/c/' || coalesce(p.side_club_id, v_club) || '/s/' || p_session || '/board');
        v_count := v_count + 1;
      end loop;
      v_match := null;
    end loop;
  exception when others then
    -- 알림 때문에 코트 채우기가 실패하면 안 된다
    raise warning 'notify_court_next failed: %', sqlerrm;
  end;
  return v_count;
end;
$function$;

-- ---------------------------------------------------------------------
-- 교류전 만들기 / 초대 응답 / 상대 정원
-- ---------------------------------------------------------------------
create or replace function public.create_exchange(
  p_club              uuid,
  p_partner           uuid,
  p_title             text,
  p_place             text,
  p_starts_at         timestamptz,
  p_ends_at           timestamptz,
  p_capacity          int,
  p_partner_capacity  int,
  p_court_count       int,
  p_opens_at          timestamptz,
  p_round_count       int,
  p_score_target      int,
  p_score_cap         int,
  p_minutes_per_game  int,
  p_guests_in_capacity boolean default false
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_open timestamptz := coalesce(p_opens_at, now());
  v_id   uuid;
  v_host text;
  v_title text := coalesce(nullif(btrim(p_title), ''), '교류전');
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_partner is null or p_partner = p_club or not exists (select 1 from public.clubs where id = p_partner) then
    raise exception 'invalid_partner' using errcode = '22023';
  end if;
  if p_starts_at <= now() or p_ends_at <= p_starts_at or v_open > p_starts_at then
    raise exception 'invalid_time' using errcode = '22023';
  end if;
  if coalesce(p_capacity, 0) <= 0 or coalesce(p_partner_capacity, 0) <= 0 then
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
     kind, tournament_state, round_count, score_target, score_cap, minutes_per_game, guests_in_capacity,
     partner_club_id, partner_status, partner_capacity)
  values
    (p_club, 'flash', auth.uid(), v_title, coalesce(btrim(p_place), ''),
     p_starts_at, p_ends_at, p_capacity, p_court_count, v_open,
     'exchange', 'draft', p_round_count, p_score_target, p_score_cap, p_minutes_per_game, coalesce(p_guests_in_capacity, false),
     p_partner, 'invited', p_partner_capacity)
  returning id into v_id;

  select name into v_host from public.clubs where id = p_club;
  begin
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, p_partner, v_id, 'exchange_invite', '교류전 초대',
           v_host || '에서 ''' || v_title || ''' 교류전에 초대했어요. 수락하면 회원들이 신청할 수 있어요',
           '/c/' || p_partner
      from public.club_members m
     where m.club_id = p_partner and m.role = 'admin' and m.status = 'approved';
  exception when others then
    raise warning 'exchange_invite notify failed: %', sqlerrm;
  end;

  perform public.log_activity(p_club, v_id, 'session.create_exchange', jsonb_build_object('partner', p_partner));
  return v_id;
end;
$$;

-- 상대 운영진: 수락하면 상대 회원에게 새 운동 알림, 거절하면 주최 운영진에게 알림
create or replace function public.respond_exchange(p_session uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s        public.sessions%rowtype;
  v_host   text;
  v_guest  text;
  v_tz     text;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found or s.kind <> 'exchange' or s.partner_club_id is null then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(s.partner_club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.partner_status <> 'invited' or s.canceled_at is not null then
    raise exception 'not_invited' using errcode = 'P0001';
  end if;

  update public.sessions set partner_status = case when p_accept then 'accepted' else 'declined' end where id = p_session;
  select name into v_host from public.clubs where id = s.club_id;
  select name, coalesce(timezone, 'Asia/Seoul') into v_guest, v_tz from public.clubs where id = s.partner_club_id;

  begin
    if p_accept then
      insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
      select m.user_id, s.partner_club_id, s.id, 'vote_created', v_guest || ' 새 교류전',
             v_host || '와(과) 교류전, ' || public.fmt_when(s.starts_at, v_tz) ||
               case when s.opens_at <= now() then '. 지금 투표 중이에요'
                    else '. 투표는 ' || public.fmt_when(s.opens_at, v_tz) || '에 열려요' end,
             '/c/' || s.partner_club_id || '/s/' || s.id
        from public.club_members m
       where m.club_id = s.partner_club_id and m.status = 'approved' and m.user_id <> auth.uid()
         and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_created');
    end if;
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, s.club_id, s.id, 'exchange_reply',
           case when p_accept then '교류전 수락' else '교류전 거절' end,
           v_guest || '이(가) ''' || s.title || ''' 교류전 초대를 ' || case when p_accept then '수락했어요' else '거절했어요' end,
           '/c/' || s.club_id || '/s/' || s.id
      from public.club_members m
     where m.club_id = s.club_id and m.role = 'admin' and m.status = 'approved';
  exception when others then
    raise warning 'exchange reply notify failed: %', sqlerrm;
  end;

  perform public.log_activity(s.club_id, s.id, case when p_accept then 'exchange.accept' else 'exchange.decline' end, '{}'::jsonb);
end;
$$;

-- 상대 정원: 주최 운영진 또는 상대 운영진
create or replace function public.update_partner_capacity(p_session uuid, p_capacity int)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s      public.sessions%rowtype;
  v_used int;
  v_n    int;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found or s.kind <> 'exchange' or s.partner_status <> 'accepted' then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_side_admin(p_session, s.partner_club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_capacity is null or p_capacity <= 0 then
    raise exception 'invalid_capacity' using errcode = '22023';
  end if;
  v_used := public.capacity_used_side(p_session, s.partner_club_id);
  if p_capacity < v_used then
    raise exception 'capacity_below_confirmed' using errcode = 'P0001', detail = format('confirmed=%s', v_used);
  end if;
  update public.sessions set partner_capacity = p_capacity where id = p_session;
  v_n := public.promote_waitlist(p_session, 0);
  perform public.log_activity(s.club_id, p_session, 'session.partner_capacity', jsonb_build_object('to', p_capacity, 'promoted', v_n));
  return v_n;
end;
$$;

-- 대진 짜기용: 이 운동 참석자의 급수·성별 (상대 동아리 회원 것도. 볼 수 있는 운동만)
create or replace function public.session_player_meta(p_session uuid)
returns table (registration_id uuid, side_club_id uuid, level text, gender text)
language sql stable security definer set search_path = ''
as $$
  select r.id, coalesce(r.side_club_id, s.club_id),
         case when r.kind = 'guest' then r.guest_level else m.level end,
         case when r.kind = 'guest' then r.guest_gender else m.gender end
    from public.registrations r
    join public.sessions s on s.id = r.session_id
    left join public.club_members m on m.club_id = coalesce(r.side_club_id, s.club_id) and m.user_id = r.user_id
   where r.session_id = p_session and r.status <> 'canceled' and public.can_see_session(p_session);
$$;

-- 일정 목록 뷰: 교류전 정보 + 보는 사람 편의 정원·인원 (일반 운동이면 주최 = 전체)
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
  s.guests_in_capacity,
  s.partner_club_id,
  s.partner_status,
  s.partner_capacity,
  coalesce(c.partner_confirmed, 0)::int as partner_confirmed_count,
  coalesce(c.partner_waitlisted, 0)::int as partner_waitlist_count
from public.sessions s
left join lateral (
  select count(*) filter (where coalesce(r.side_club_id, s.club_id) = s.club_id
                            and public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'confirmed')  as confirmed,
         count(*) filter (where coalesce(r.side_club_id, s.club_id) = s.club_id
                            and public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'waitlisted') as waitlisted,
         count(*) filter (where r.kind = 'guest' and r.status <> 'canceled') as guests,
         count(*) filter (where r.side_club_id = s.partner_club_id
                            and public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'confirmed')  as partner_confirmed,
         count(*) filter (where r.side_club_id = s.partner_club_id
                            and public.counts_capacity(r.kind, s.guests_in_capacity) and r.status = 'waitlisted') as partner_waitlisted
    from public.registrations r
   where r.session_id = s.id
) c on true
left join lateral (
  select r.id, r.status
    from public.registrations r
   where r.session_id = s.id and r.user_id = auth.uid() and r.kind = 'member' and r.status <> 'canceled'
   limit 1
) me on true;

revoke execute on function public.can_see_session(uuid)                 from public, anon;
revoke execute on function public.active_partner(uuid)                  from public, anon, authenticated;
revoke execute on function public.side_of_user(uuid, uuid)              from public, anon, authenticated;
revoke execute on function public.is_side_admin(uuid, uuid)             from public, anon, authenticated;
revoke execute on function public.side_capacity(uuid, uuid)             from public, anon, authenticated;
revoke execute on function public.capacity_used_side(uuid, uuid)        from public, anon, authenticated;
revoke execute on function public.lock_roster_side(uuid, uuid)          from public, anon, authenticated;
revoke execute on function public.roster_add_guest(uuid, text, text, text, uuid) from public, anon;
revoke execute on function public.create_exchange(uuid, uuid, text, text, timestamptz, timestamptz, int, int, int, timestamptz, int, int, int, int, boolean) from public, anon;
revoke execute on function public.respond_exchange(uuid, boolean)       from public, anon;
revoke execute on function public.update_partner_capacity(uuid, int)    from public, anon;
revoke execute on function public.session_player_meta(uuid)             from public, anon;
grant execute on function public.can_see_session(uuid)                  to authenticated;   -- RLS 정책에서 호출
grant execute on function public.roster_add_guest(uuid, text, text, text, uuid) to authenticated;
grant execute on function public.create_exchange(uuid, uuid, text, text, timestamptz, timestamptz, int, int, int, timestamptz, int, int, int, int, boolean) to authenticated;
grant execute on function public.respond_exchange(uuid, boolean)        to authenticated;
grant execute on function public.update_partner_capacity(uuid, int)     to authenticated;
grant execute on function public.session_player_meta(uuid)              to authenticated;
