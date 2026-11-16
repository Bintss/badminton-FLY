-- =====================================================================
-- M3: 정기운동 세션 자동 생성 스케줄 (pg_cron, 매시간)
-- pg_cron을 쓸 수 없는 환경(로컬 테스트 등)에서는 아무것도 하지 않는다.
-- cron이 없어도 홈 화면 진입 시 ensure_upcoming_sessions가 같은 일을 한다.
-- Supabase에서는 Database > Extensions에서 pg_cron이 켜져 있어야 한다.
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    create extension if not exists pg_cron with schema pg_catalog;
    -- 같은 이름이면 덮어쓴다 (재실행 안전)
    perform cron.schedule('generate-regular-sessions', '5 * * * *', 'select public.generate_all_sessions()');
  else
    raise notice 'pg_cron not available: skipping schedule (ensure_upcoming_sessions covers generation)';
  end if;
end $$;
