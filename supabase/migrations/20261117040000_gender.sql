-- =====================================================================
-- 성별: 자동 대진에서 혼복(팀마다 남1·여1)·남복·여복을 정확히 짜기 위해
--   - 회원: 본인이 입력(내 정보), 운영진이 수정 가능. 동아리별로 저장(급수와 같은 자리)
--   - 게스트: 추가할 때 고름. 운영진이 나중에 수정 가능
--   'M' = 남, 'F' = 여, null = 미입력
-- =====================================================================
alter table public.club_members add column gender text check (gender in ('M', 'F'));
alter table public.registrations add column guest_gender text check (guest_gender in ('M', 'F'));
alter table public.registrations add constraint registrations_guest_gender_kind check (kind = 'guest' or guest_gender is null);

create or replace function public.set_my_gender(p_club uuid, p_gender text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  update public.club_members set gender = p_gender
   where club_id = p_club and user_id = auth.uid() and status = 'approved';
  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
end;
$$;

create or replace function public.set_member_gender(p_club uuid, p_user uuid, p_gender text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  update public.club_members set gender = p_gender
   where club_id = p_club and user_id = p_user and status = 'approved';
  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  perform public.log_activity(p_club, null, 'member.set_gender', jsonb_build_object('user_id', p_user, 'gender', p_gender));
end;
$$;

-- 게스트 추가: 성별 선택 (기존 호출과 호환되게 기본값 null)
drop function if exists public.add_guest(uuid, text);
create or replace function public.add_guest(p_session uuid, p_name text, p_gender text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
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
$$;

-- 게스트 성별 수정 (운영진)
create or replace function public.set_guest_gender(p_registration uuid, p_gender text)
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
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  update public.registrations set guest_gender = p_gender where id = p_registration;
  perform public.log_activity(v_club, v_session, 'board.set_guest_gender', jsonb_build_object('registration_id', p_registration, 'gender', p_gender));
end;
$$;

revoke execute on function public.set_my_gender(uuid, text)                from public, anon, authenticated;
revoke execute on function public.set_member_gender(uuid, uuid, text)      from public, anon, authenticated;
revoke execute on function public.add_guest(uuid, text, text)              from public, anon, authenticated;
revoke execute on function public.set_guest_gender(uuid, text)             from public, anon, authenticated;
grant execute on function public.set_my_gender(uuid, text)                 to authenticated;
grant execute on function public.set_member_gender(uuid, uuid, text)       to authenticated;
grant execute on function public.add_guest(uuid, text, text)               to authenticated;
grant execute on function public.set_guest_gender(uuid, text)              to authenticated;
