-- =====================================================================
-- 되돌리기: 20261119040000_exchange.sql (T5 교류전) 적용 전으로
--   SQL Editor에서 이 파일 전체를 한 번에 실행 (한 트랜잭션). 마이그레이션 폴더 밖이라 db push에는 안 올라감
--   교류전으로 만든 운동(신청·대진 포함)과 교류전 알림은 지워진다. 나머지 데이터는 그대로
--   교류전 전 함수 정의는 그 시점 DB에서 그대로 뽑았다 (로컬에서 적용 → 되돌리기 → 기존 테스트 통과 확인)
-- =====================================================================
begin;

-- 1) 교류전 데이터
delete from public.notifications where kind in ('exchange_invite', 'exchange_reply');
delete from public.sessions where kind = 'exchange';

-- 2) 새 함수를 쓰는 정책·뷰를 먼저 예전 것으로
drop policy sessions_select on public.sessions;
create policy sessions_select on public.sessions for select to authenticated using (is_club_member(club_id));
drop policy registrations_select on public.registrations;
create policy registrations_select on public.registrations for select to authenticated using (is_club_member(session_club_id(session_id)));

drop view public.session_overview;
create view public.session_overview with (security_invoker = true) as
SELECT s.id,
    s.club_id,
    s.template_id,
    s.type,
    s.host_user_id,
    s.title,
    s.place,
    s.starts_at,
    s.ends_at,
    s.capacity,
    s.court_count,
    s.opens_at,
    s.canceled_at,
    COALESCE(c.confirmed, 0::bigint)::integer AS confirmed_count,
    COALESCE(c.waitlisted, 0::bigint)::integer AS waitlist_count,
    COALESCE(c.guests, 0::bigint)::integer AS guest_count,
    me.id AS my_registration_id,
    me.status AS my_status,
    s.kind,
    s.tournament_state,
    s.round_count,
    s.score_target,
    s.score_cap,
    s.minutes_per_game,
    s.guests_in_capacity
   FROM sessions s
     LEFT JOIN LATERAL ( SELECT count(*) FILTER (WHERE counts_capacity(r.kind, s.guests_in_capacity) AND r.status = 'confirmed'::registration_status) AS confirmed,
            count(*) FILTER (WHERE counts_capacity(r.kind, s.guests_in_capacity) AND r.status = 'waitlisted'::registration_status) AS waitlisted,
            count(*) FILTER (WHERE r.kind = 'guest'::registration_kind AND r.status <> 'canceled'::registration_status) AS guests
           FROM registrations r
          WHERE r.session_id = s.id) c ON true
     LEFT JOIN LATERAL ( SELECT r.id,
            r.status
           FROM registrations r
          WHERE r.session_id = s.id AND r.user_id = auth.uid() AND r.kind = 'member'::registration_kind AND r.status <> 'canceled'::registration_status
         LIMIT 1) me ON true;
revoke all on public.session_overview from public, anon, authenticated;
grant select on public.session_overview to authenticated;

-- 3) 바꾼 함수를 예전 정의로
drop function public.roster_add_guest(uuid, text, text, text, uuid);
CREATE OR REPLACE FUNCTION public.capacity_used(p_session uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select count(*)::int
    from public.registrations r join public.sessions s on s.id = r.session_id
   where r.session_id = p_session and r.status = 'confirmed'
     and public.counts_capacity(r.kind, s.guests_in_capacity);
$function$;

CREATE OR REPLACE FUNCTION public.promote_waitlist(p_session uuid, p_slots integer)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.registration_position(p_registration uuid)
 RETURNS integer
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select count(*)::int
    from public.registrations me
    join public.sessions s on s.id = me.session_id
    join public.registrations other
      on other.session_id = me.session_id
     and public.counts_capacity(other.kind, s.guests_in_capacity)
     and other.status = me.status
     and other.seq <= me.seq
   where me.id = p_registration;
$function$;

CREATE OR REPLACE FUNCTION public.can_view_profile(p_user uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select p_user = auth.uid()
      or exists (
        select 1
        from public.club_members me
        join public.club_members other on other.club_id = me.club_id
        where me.user_id = auth.uid() and me.status = 'approved'
          and other.user_id = p_user
          and (other.status = 'approved' or me.role = 'admin')
      );
$function$;

CREATE OR REPLACE FUNCTION public.can_view_match(p_match uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match
       and public.is_club_member(s.club_id)
       and (m.phase = 'free'
            or s.tournament_state is distinct from 'draft'
            or public.is_club_admin(s.club_id))
  );
$function$;

CREATE OR REPLACE FUNCTION public.can_operate_board(p_session uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
           select 1 from public.sessions s
            where s.id = p_session and public.is_club_admin(s.club_id)
         )
      or exists (
           select 1
             from public.registrations r
             join public.sessions s on s.id = r.session_id
            where r.session_id = p_session and r.user_id = auth.uid()
              and r.kind = 'member' and r.status = 'confirmed'
              and public.is_club_member(s.club_id)
              and now() >= s.starts_at - interval '3 hours'
              and now() <  s.ends_at   + interval '3 hours'
         );
$function$;

CREATE OR REPLACE FUNCTION public.can_score_match(p_match uuid)
 RETURNS boolean
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match and m.phase = 'scheduled'
       and (
         public.is_club_admin(s.club_id)
         or ((s.tournament_state in ('published', 'in_progress') or m.result_at is null)
             and exists (select 1 from public.match_players mp
                           join public.registrations r on r.id = mp.registration_id
                          where mp.match_id = m.id and r.user_id = auth.uid() and r.kind = 'member'))
       )
  );
$function$;

CREATE OR REPLACE FUNCTION public.register(p_session uuid, p_late_eta time without time zone DEFAULT NULL::time without time zone)
 RETURNS TABLE(registration_id uuid, status registration_status, queue_position integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.add_vote_guest(p_session uuid, p_name text, p_gender text DEFAULT NULL::text, p_level text DEFAULT NULL::text)
 RETURNS TABLE(registration_id uuid, status registration_status, queue_position integer)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
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

  insert into public.registrations (session_id, kind, guest_name, guest_gender, guest_level, added_by, status)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, p_level, v_uid, v_status)
  returning id into v_id;

  perform public.log_activity(s.club_id, p_session, 'registration.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'status', v_status));

  return query select v_id, v_status,
    case when s.guests_in_capacity then public.registration_position(v_id) else null end;
end;
$function$;

CREATE OR REPLACE FUNCTION public.add_guest(p_session uuid, p_name text, p_gender text DEFAULT NULL::text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_club uuid;
  v_id   uuid;
begin
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  v_club := public.lock_board(p_session);

  insert into public.registrations (session_id, kind, guest_name, guest_gender, added_by, status, checked_in_at)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, auth.uid(), 'confirmed', now())
  returning id into v_id;

  perform public.log_activity(v_club, p_session, 'board.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'gender', p_gender));
  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.roster_add_member(p_session uuid, p_user uuid)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.roster_remove(p_registration uuid)
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
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
$function$;

CREATE OR REPLACE FUNCTION public.roster_add_guest(p_session uuid, p_name text, p_gender text, p_level text)
 RETURNS uuid
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s    public.sessions%rowtype;
  v_id uuid;
begin
  s := public.lock_roster(p_session);
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;

  insert into public.registrations (session_id, kind, guest_name, guest_gender, guest_level, added_by, status)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, p_level, auth.uid(), 'confirmed')
  returning id into v_id;

  perform public.log_activity(s.club_id, p_session, 'roster.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30)));
  return v_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lock_roster(p_session uuid)
 RETURNS sessions
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s public.sessions%rowtype;
begin
  s := public.lock_tournament(p_session);
  if s.kind <> 'tournament' then
    raise exception 'not_tournament' using errcode = 'P0001';
  end if;
  if s.tournament_state = 'finished' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  return s;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_guest_gender(p_registration uuid, p_gender text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_club    uuid;
  v_session uuid;
begin
  select r.session_id, s.club_id into v_session, v_club
    from public.registrations r join public.sessions s on s.id = r.session_id
   where r.id = p_registration and r.kind = 'guest';
  if v_session is null then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(v_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  update public.registrations set guest_gender = p_gender where id = p_registration;
  perform public.log_activity(v_club, v_session, 'board.set_guest_gender', jsonb_build_object('registration_id', p_registration, 'gender', p_gender));
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_guest_level(p_registration uuid, p_level text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_club    uuid;
  v_session uuid;
begin
  select r.session_id, s.club_id into v_session, v_club
    from public.registrations r join public.sessions s on s.id = r.session_id
   where r.id = p_registration and r.kind = 'guest';
  if v_session is null then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(v_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;
  update public.registrations set guest_level = p_level where id = p_registration;
end;
$function$;

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
  if s.kind <> 'tournament' then
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
    v_label := case when new.kind = 'tournament' then '자체대회' when new.type = 'flash' then '번개' else '운동' end;
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
    returning x.id, x.club_id, x.title, x.opens_at, x.starts_at
  loop
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, s.club_id, s.id, 'vote_soon',
           ceil(extract(epoch from (s.opens_at - now())) / 60)::int || '분 뒤 투표 오픈',
           s.title || ' (' || public.fmt_when(s.starts_at, coalesce(c.timezone, 'Asia/Seoul')) || ') 투표가 ' ||
             to_char(s.opens_at at time zone coalesce(c.timezone, 'Asia/Seoul'), 'HH24:MI') || '에 열려요. 선착순이에요',
           '/c/' || s.club_id || '/s/' || s.id
      from public.club_members m
      join public.clubs c on c.id = m.club_id
     where m.club_id = s.club_id and m.status = 'approved'
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
      select mp.registration_id, mp.team, r.user_id
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
        '/c/' || v_club || '/s/' || new.session_id || '/board');
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
        select mp.registration_id, mp.team, r.user_id
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
          '/c/' || v_club || '/s/' || p_session || '/board');
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

revoke execute on function public.roster_add_guest(uuid, text, text, text) from public, anon;
grant execute on function public.roster_add_guest(uuid, text, text, text) to authenticated;

-- 4) 교류전에서 새로 만든 함수
drop function public.create_exchange(uuid, uuid, text, text, timestamptz, timestamptz, int, int, int, timestamptz, int, int, int, int, boolean);
drop function public.respond_exchange(uuid, boolean);
drop function public.update_partner_capacity(uuid, int);
drop function public.session_player_meta(uuid);
drop function public.lock_roster_side(uuid, uuid);
drop function public.capacity_used_side(uuid, uuid);
drop function public.side_capacity(uuid, uuid);
drop function public.is_side_admin(uuid, uuid);
drop function public.side_of_user(uuid, uuid);
drop function public.active_partner(uuid);
drop function public.can_see_session(uuid);

-- 5) 열·제약
alter table public.registrations drop column side_club_id;
drop index if exists public.sessions_partner_idx;
alter table public.sessions
  drop constraint sessions_partner_exchange,
  drop constraint sessions_partner_not_self,
  drop column partner_club_id,
  drop column partner_status,
  drop column partner_capacity;

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next',
                  'club_request', 'club_decided', 'club_deleted'));

commit;
