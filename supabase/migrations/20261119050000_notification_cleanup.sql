-- =====================================================================
-- 알림 정리 (10분마다, pg_cron)
--   1) 끝난(또는 취소된) 운동의 코트 배정·코트 대기·투표 10분 전 알림은 지운다 — 운동이 끝나면 쓸모가 없다
--   2) 30일 지난 알림은 모두 지운다
--   지우면 안 읽은 수(종·앱 아이콘 숫자)도 함께 줄어든다
-- =====================================================================

create index if not exists notifications_session_idx on public.notifications (session_id) where session_id is not null;
create index if not exists notifications_created_idx on public.notifications (created_at);

create or replace function public.cleanup_notifications()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_short int;
  v_old   int;
begin
  delete from public.notifications n
   using public.sessions s
   where n.session_id = s.id
     and n.kind in ('court_assigned', 'court_next', 'vote_soon')
     and (s.ends_at < now() or s.canceled_at is not null);
  get diagnostics v_short = row_count;

  delete from public.notifications where created_at < now() - interval '30 days';
  get diagnostics v_old = row_count;

  return v_short + v_old;
end;
$$;

revoke execute on function public.cleanup_notifications() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('notifications-cleanup', '*/10 * * * *', 'select public.cleanup_notifications()');
  else
    raise notice 'pg_cron not installed: notifications-cleanup not scheduled';
  end if;
end $$;
