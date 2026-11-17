-- =====================================================================
-- T3: 자체대회 명단 관리 (운영진)
--   - 회원 추가: 참석 확정으로 넣는다. 대기 중이면 바로 확정. 정원이 차 있으면 정원을 1 늘린다
--     (대기자보다 앞에 끼워넣는 것이므로 변경 이력에 남김)
--   - 빼기: 참석 취소와 같다. 확정자를 빼면 대기 1번 자동 확정. 그 사람의 시작 안 한 대회 경기 수를 돌려준다
--   - 게스트 추가: 이름·성별·급수. 대진판의 add_guest와 달리 도착 처리하지 않는다 (대회 전에 미리 넣는 용도)
--   - 대회가 끝나면 명단은 바꾸지 않는다
-- =====================================================================
alter table public.registrations add column guest_level text
  check (guest_level is null or guest_level in ('A조', 'B조', 'C조', 'D조', '초심'));
alter table public.registrations add constraint registrations_guest_level_kind check (kind = 'guest' or guest_level is null);

-- 내부: 운영진 + 명단을 바꿀 수 있는 대회 단계인지. 세션 잠금
create or replace function public.lock_roster(p_session uuid)
returns public.sessions
language plpgsql security definer set search_path = ''
as $$
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
$$;

-- 회원 추가 (운영진)
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

  select count(*) into v_confirmed from public.registrations
   where session_id = p_session and kind = 'member' and status = 'confirmed';
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

-- 빼기 (운영진). 회원·게스트 모두. 돌려주는 값: 그 사람이 든 시작 안 한 대회 경기 수
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
  if r.status = 'confirmed' and r.kind = 'member' then
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

-- 게스트 미리 추가 (운영진)
create or replace function public.roster_add_guest(p_session uuid, p_name text, p_gender text, p_level text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
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
$$;

-- 게스트 급수 수정 (운영진)
create or replace function public.set_guest_level(p_registration uuid, p_level text)
returns void
language plpgsql security definer set search_path = ''
as $$
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
$$;

revoke execute on function public.lock_roster(uuid)                          from public, anon, authenticated;
revoke execute on function public.roster_add_member(uuid, uuid)              from public, anon, authenticated;
revoke execute on function public.roster_remove(uuid)                        from public, anon, authenticated;
revoke execute on function public.roster_add_guest(uuid, text, text, text)   from public, anon, authenticated;
revoke execute on function public.set_guest_level(uuid, text)                from public, anon, authenticated;
grant execute on function public.roster_add_member(uuid, uuid)               to authenticated;
grant execute on function public.roster_remove(uuid)                         to authenticated;
grant execute on function public.roster_add_guest(uuid, text, text, text)    to authenticated;
grant execute on function public.set_guest_level(uuid, text)                 to authenticated;
