-- 로컬 테스트 전용 (운영 DB에는 올리지 않는다)
-- 예전 테스트들은 아무 사용자로 create_club을 부른다. 동아리 만들기가 서비스 관리자 전용이 되었으므로
-- 테스트 사용자는 만들어질 때 서비스 관리자로 등록한다. 승인제 자체는 m16에서 관리자 아닌 사용자로 검사한다
create or replace function public._test_auto_platform_admin()
returns trigger language plpgsql security definer set search_path = '' as $$
begin
  insert into public.platform_admins (user_id) values (new.id) on conflict do nothing;
  return new;
end $$;
revoke execute on function public._test_auto_platform_admin() from public, anon, authenticated;
create trigger _test_auto_platform_admin after insert on auth.users
  for each row execute function public._test_auto_platform_admin();
