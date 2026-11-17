-- =====================================================================
-- M4: 신청 명단 실시간 갱신 (Supabase Realtime, Postgres Changes)
-- 구독 이벤트에도 RLS가 적용되므로 같은 동아리 회원에게만 전달된다.
-- 로컬 테스트처럼 supabase_realtime publication이 없으면 건너뛴다.
-- =====================================================================
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'registrations'
    ) then
      alter publication supabase_realtime add table public.registrations;
    end if;
    if not exists (
      select 1 from pg_publication_tables
       where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'sessions'
    ) then
      alter publication supabase_realtime add table public.sessions;
    end if;
  else
    raise notice 'supabase_realtime publication not found: skipping';
  end if;
end $$;
