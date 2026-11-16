-- =====================================================================
-- M2: 투표 신청 / 취소 / 정원 변경 + 대기자 자동 승격
--
-- 동시성 규칙
--   * 세션 단위 직렬화: 모든 RPC는 먼저 sessions 행을 FOR UPDATE로 잠근다.
--     → 같은 세션에 대한 신청·취소·정원 변경은 한 번에 하나씩 처리된다.
--   * 잠금 순서는 항상 sessions → registrations (데드락 방지)
--   * 오픈 판정은 now() (= 요청 트랜잭션 시작 시각, 서버 기준).
--     잠금을 기다리는 동안 시각이 지나도 "도착 시각"으로 판정한다.
--   * 정원은 회원 신청(kind = 'member')만 센다. 게스트는 정원 밖.
-- =====================================================================

-- 내부용: 대기자를 seq 순서대로 최대 p_slots명 승격. 호출 전에 세션 행이 잠겨 있어야 한다.
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
    select id from public.registrations
     where session_id = p_session and kind = 'member' and status = 'waitlisted'
     order by seq
     limit p_slots
     for update
  )
  update public.registrations r
     set status = 'confirmed', promoted_at = now()
    from next_up
   where r.id = next_up.id;

  get diagnostics v_count = row_count;
  return v_count;
end;
$$;

-- 내부용: 신청의 현재 순번 (확정이면 확정 중 몇 번째, 대기면 대기 중 몇 번째)
create or replace function public.registration_position(p_registration uuid)
returns int
language sql stable security definer set search_path = ''
as $$
  select count(*)::int
    from public.registrations me
    join public.registrations other
      on other.session_id = me.session_id
     and other.kind = 'member'
     and other.status = me.status
     and other.seq <= me.seq
   where me.id = p_registration;
$$;

-- ---------------------------------------------------------------------
-- 참석 신청
--   반환: registration_id, status(confirmed|waitlisted), queue_position
--   이미 신청돼 있으면 새로 만들지 않고 기존 신청을 돌려준다 (버튼 연타 대비)
-- ---------------------------------------------------------------------
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

  select count(*) into v_confirmed
    from public.registrations r
   where r.session_id = p_session and r.kind = 'member' and r.status = 'confirmed';

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

-- ---------------------------------------------------------------------
-- 늦참 도착 예정 시각 수정 (본인)
-- ---------------------------------------------------------------------
create or replace function public.set_late_eta(p_registration uuid, p_late_eta time)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.registrations
     set late_eta = p_late_eta
   where id = p_registration and user_id = auth.uid() and status <> 'canceled';
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 신청 취소 + 대기 1순위 자동 승격 (한 트랜잭션)
--   취소 가능: 본인 / 해당 동아리 운영진 / 게스트는 동아리 회원 누구나
--   취소 시한 없음 (요구사항: 별도 공지)
--   반환: 승격된 신청 id (없으면 null)
-- ---------------------------------------------------------------------
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

  if not (
       v_reg.user_id = v_uid
    or public.is_club_admin(v_club)
    or (v_reg.kind = 'guest' and public.is_club_member(v_club))
  ) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_reg.status = 'canceled' then
    raise exception 'already_canceled' using errcode = 'P0001';
  end if;

  update public.registrations
     set status = 'canceled', canceled_at = now()
   where id = p_registration;

  -- 확정자가 빠지면 대기 1순위 승격
  if v_reg.kind = 'member' and v_reg.status = 'confirmed' then
    with next_up as (
      select id from public.registrations
       where session_id = v_reg.session_id and kind = 'member' and status = 'waitlisted'
       order by seq
       limit 1
       for update
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

-- ---------------------------------------------------------------------
-- 정원 변경
--   권한: 운영진 / 번개 개설자
--   늘리면 늘어난 만큼 대기자 승격, 현재 확정 인원보다 작게는 못 줄임
--   반환: 승격된 인원 수
-- ---------------------------------------------------------------------
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

  select count(*) into v_confirmed
    from public.registrations
   where session_id = p_session and kind = 'member' and status = 'confirmed';

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

-- ---------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------
revoke execute on function public.promote_waitlist(uuid, int)        from public, anon, authenticated;
revoke execute on function public.registration_position(uuid)        from public, anon, authenticated;
revoke execute on function public.register(uuid, time)               from public, anon, authenticated;
revoke execute on function public.set_late_eta(uuid, time)           from public, anon, authenticated;
revoke execute on function public.cancel_registration(uuid)          from public, anon, authenticated;
revoke execute on function public.update_capacity(uuid, int)         from public, anon, authenticated;

grant execute on function public.register(uuid, time)        to authenticated;
grant execute on function public.set_late_eta(uuid, time)    to authenticated;
grant execute on function public.cancel_registration(uuid)   to authenticated;
grant execute on function public.update_capacity(uuid, int)  to authenticated;
