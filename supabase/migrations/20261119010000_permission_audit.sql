-- =====================================================================
-- 권한 점검 후속
--
--   1) 대진판 조작 시간 제한: 운영진이 아닌 참석 확정자는 "시작 3시간 전 ~ 끝나고 3시간"에만
--      (앱의 '대진판 열기' 버튼과 같은 범위). 이전에는 서버에 시간 제한이 없어서
--      참석 확정자가 며칠 전에도 게스트 무제한 추가(정원·1인 3명 제한 우회), 남의 게스트 취소,
--      도착 처리, 경기 만들기·종료를 할 수 있었다
--   2) 알림 관련 테이블(notifications, push_subscriptions, notification_mutes)의 기본 권한 정리
--      RLS로 막혀 있었지만 anon·authenticated에 INSERT/UPDATE/DELETE/TRUNCATE 권한이 남아 있었다.
--      다른 테이블처럼 읽기만 주고, 쓰기는 함수로만
--   3) 활동 기록(activity_log)은 운영진만 읽기 (강퇴·점수 수정 기록 등. 앱에서 쓰지 않음)
-- =====================================================================

create or replace function public.can_operate_board(p_session uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
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
$$;

revoke all on public.notifications      from anon, authenticated;
revoke all on public.push_subscriptions from anon, authenticated;
revoke all on public.notification_mutes from anon, authenticated;
grant select on public.notifications      to authenticated;
grant select on public.push_subscriptions to authenticated;
grant select on public.notification_mutes to authenticated;

drop policy if exists activity_log_select on public.activity_log;
create policy activity_log_select on public.activity_log
  for select to authenticated using (public.is_club_admin(club_id));
