-- =====================================================================
-- 서비스 관리자도 동아리를 삭제할 수 있다 (그 동아리 회원이 아니어도)
--   * delete_club: 그 동아리 운영진 또는 서비스 관리자. 이름을 그대로 입력해야 하는 확인은 같음
--   * 로고 파일도 지울 수 있게 Storage 정책 함수에 서비스 관리자 포함
--   * 서비스 관리자가 지우면 그 동아리 운영진에게 알림(club_deleted)
-- =====================================================================

alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next',
                  'club_request', 'club_decided', 'club_deleted'));

create or replace function public.is_admin_of_logo_path(p_path text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
  return public.is_platform_admin() or public.is_club_admin(split_part(p_path, '/', 1)::uuid);
exception when others then
  return false;
end;
$$;

create or replace function public.delete_club(p_club uuid, p_confirm_name text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_name     text;
  v_club_adm boolean := public.is_club_admin(p_club);
begin
  if not (v_club_adm or public.is_platform_admin()) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select name into v_name from public.clubs where id = p_club for update;
  if v_name is null then
    raise exception 'club_not_found' using errcode = 'P0002';
  end if;
  if p_confirm_name is distinct from v_name then
    raise exception 'confirm_name_mismatch' using errcode = '22023';
  end if;

  -- 운영진이 아닌 서비스 관리자가 지우면 운영진에게 알린다 (동아리와 함께 지워지지 않게 club_id 없이)
  if not v_club_adm then
    begin
      insert into public.notifications (user_id, kind, title, body, url)
      select m.user_id, 'club_deleted', '동아리 삭제',
             '''' || v_name || ''' 동아리가 서비스 관리자에 의해 삭제됐어요', '/clubs'
        from public.club_members m
       where m.club_id = p_club and m.role = 'admin' and m.status = 'approved';
    exception when others then
      raise warning 'club_deleted notify failed: %', sqlerrm;
    end;
  end if;

  delete from public.clubs where id = p_club;
end;
$$;
