-- =====================================================================
-- 회원 내보내기 / 강퇴 / 강퇴 해제 / 동아리 나가기 / 동아리 삭제
--   - 내보내기: status = 'left'. 다시 가입 신청 가능
--   - 강퇴: status = 'left' + banned_at. 다시 가입 신청 불가 (운영진이 해제하면 가능)
--   - 둘 다 아직 시작 안 한 운동의 참석·대기 신청을 취소하고, 빈자리는 대기자 승격
--     (지난 운동 기록과 경기 기록은 그대로 둔다)
--   - 운영진은 바로 내보낼 수 없다: 먼저 운영진 해제
--   - 동아리 삭제: 운영진이 동아리 이름을 정확히 입력해야 한다. 모든 데이터가 함께 지워진다
-- =====================================================================
alter table public.club_members add column banned_at timestamptz;
alter table public.club_members add column banned_by uuid references public.profiles(id) on delete set null;

-- 가입 신청: 강퇴된 사람은 거부
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
  if exists (select 1 from public.club_members where club_id = p_club and user_id = v_uid and banned_at is not null) then
    raise exception 'banned' using errcode = '42501';
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
    select status into v_status from public.club_members
    where club_id = p_club and user_id = v_uid;
  else
    perform public.log_activity(p_club, null, 'member.request', '{}'::jsonb);
  end if;

  return v_status;
end;
$$;

-- 내부: 그 사람의 아직 시작 안 한 운동 신청을 모두 취소하고 대기자 승격. 취소한 건수
create or replace function public.cancel_upcoming_registrations(p_club uuid, p_user uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  rec     record;
  v_count int := 0;
begin
  for rec in
    select r.id, r.session_id, r.status
      from public.registrations r
      join public.sessions s on s.id = r.session_id
     where s.club_id = p_club and r.user_id = p_user and r.kind = 'member'
       and r.status in ('confirmed', 'waitlisted') and s.starts_at > now()
     order by s.id
  loop
    perform 1 from public.sessions where id = rec.session_id for update;   -- 잠금 순서: 세션 먼저
    update public.registrations set status = 'canceled', canceled_at = now() where id = rec.id;
    if rec.status = 'confirmed' then
      perform public.promote_waitlist(rec.session_id, 1);
    end if;
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- 내보내기 / 강퇴 (운영진)
create or replace function public.remove_member(p_club uuid, p_user uuid, p_ban boolean)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  m        public.club_members%rowtype;
  v_canceled int;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_user = auth.uid() then
    raise exception 'cannot_remove_self' using errcode = 'P0001';
  end if;
  select * into m from public.club_members where club_id = p_club and user_id = p_user for update;
  if not found or m.status <> 'approved' then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  if m.role = 'admin' then
    raise exception 'is_admin' using errcode = 'P0001';
  end if;

  update public.club_members
     set status = 'left', role = 'member', decided_at = now(), decided_by = auth.uid(),
         banned_at = case when p_ban then now() else null end,
         banned_by = case when p_ban then auth.uid() else null end
   where club_id = p_club and user_id = p_user;

  v_canceled := public.cancel_upcoming_registrations(p_club, p_user);
  perform public.log_activity(p_club, null, case when p_ban then 'member.ban' else 'member.remove' end,
    jsonb_build_object('user_id', p_user, 'canceled_registrations', v_canceled));
  return v_canceled;
end;
$$;

-- 가입 신청 중인 사람 강퇴 (운영진): 거절 + 재신청 불가
create or replace function public.ban_applicant(p_club uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.club_members
     set status = 'rejected', decided_at = now(), decided_by = auth.uid(), banned_at = now(), banned_by = auth.uid()
   where club_id = p_club and user_id = p_user and status = 'pending';
  if not found then
    raise exception 'not_pending' using errcode = 'P0002';
  end if;
  perform public.log_activity(p_club, null, 'member.ban', jsonb_build_object('user_id', p_user, 'applicant', true));
end;
$$;

-- 강퇴 해제 (운영진): 다시 가입 신청할 수 있게 된다 (자동 가입은 아님)
create or replace function public.unban_member(p_club uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  update public.club_members set banned_at = null, banned_by = null
   where club_id = p_club and user_id = p_user and banned_at is not null;
  if not found then
    raise exception 'not_banned' using errcode = 'P0002';
  end if;
  perform public.log_activity(p_club, null, 'member.unban', jsonb_build_object('user_id', p_user));
end;
$$;

-- 동아리 나가기 (본인). 마지막 운영진은 나갈 수 없다
create or replace function public.leave_club(p_club uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  m          public.club_members%rowtype;
  v_canceled int;
begin
  perform 1 from public.club_members
   where club_id = p_club and role = 'admin' and status = 'approved'
   for update;
  select * into m from public.club_members where club_id = p_club and user_id = auth.uid() for update;
  if not found or m.status not in ('approved', 'pending') then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  if m.role = 'admin' and (select count(*) from public.club_members
                            where club_id = p_club and role = 'admin' and status = 'approved'
                              and user_id <> auth.uid()) = 0 then
    raise exception 'last_admin' using errcode = 'P0001';
  end if;

  update public.club_members set status = 'left', role = 'member' where club_id = p_club and user_id = auth.uid();
  v_canceled := public.cancel_upcoming_registrations(p_club, auth.uid());
  perform public.log_activity(p_club, null, 'member.leave', jsonb_build_object('canceled_registrations', v_canceled));
  return v_canceled;
end;
$$;

-- 동아리 삭제 (운영진). 이름을 정확히 입력해야 한다. 운동·신청·경기·기록이 모두 함께 지워진다
--   로고 파일은 화면에서 먼저 지운다 (Storage 정책이 운영진 권한을 보기 때문)
create or replace function public.delete_club(p_club uuid, p_confirm_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_name text;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select name into v_name from public.clubs where id = p_club for update;
  if v_name is null then
    raise exception 'club_not_found' using errcode = 'P0002';
  end if;
  if p_confirm_name is distinct from v_name then
    raise exception 'confirm_name_mismatch' using errcode = '22023';
  end if;
  delete from public.clubs where id = p_club;
end;
$$;

revoke execute on function public.cancel_upcoming_registrations(uuid, uuid) from public, anon, authenticated;
revoke execute on function public.remove_member(uuid, uuid, boolean)        from public, anon, authenticated;
revoke execute on function public.ban_applicant(uuid, uuid)                 from public, anon, authenticated;
revoke execute on function public.unban_member(uuid, uuid)                  from public, anon, authenticated;
revoke execute on function public.leave_club(uuid)                          from public, anon, authenticated;
revoke execute on function public.delete_club(uuid, text)                   from public, anon, authenticated;
grant execute on function public.remove_member(uuid, uuid, boolean)         to authenticated;
grant execute on function public.ban_applicant(uuid, uuid)                  to authenticated;
grant execute on function public.unban_member(uuid, uuid)                   to authenticated;
grant execute on function public.leave_club(uuid)                           to authenticated;
grant execute on function public.delete_club(uuid, text)                    to authenticated;
