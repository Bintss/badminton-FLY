-- 알림 정리: 끝난 운동의 짧은 알림, 30일 지난 알림
\set ON_ERROR_STOP on
\pset footer off
\set QUIET on

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;

insert into auth.users (id, raw_user_meta_data) values ('e1800000-0000-0000-0000-000000000001', '{"name":"알림정리"}');
set role authenticated;
select set_config('request.jwt.claim.sub', 'e1800000-0000-0000-0000-000000000001', false);
select create_club('알림 정리 클럽') as club \gset
reset role;

\set U '''e1800000-0000-0000-0000-000000000001'''
\set DONE '''e1800000-0000-0000-0000-0000000000a1'''
\set NEXT '''e1800000-0000-0000-0000-0000000000a2'''
\set GONE '''e1800000-0000-0000-0000-0000000000a3'''
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, canceled_at) values
  (:DONE, :'club', 'regular', '끝난 운동', now() - interval '5 hour', now() - interval '2 hour', 10, 2, now() - interval '2 day', null),
  (:NEXT, :'club', 'regular', '다음 운동', now() + interval '1 day', now() + interval '1 day 3 hour', 10, 2, now() - interval '1 hour', null),
  (:GONE, :'club', 'regular', '취소된 운동', now() + interval '2 day', now() + interval '2 day 3 hour', 10, 2, now() - interval '1 hour', now());

insert into notifications (user_id, club_id, session_id, kind, title, body, url, created_at) values
  (:U, :'club', :DONE, 'court_assigned', '끝난 운동 코트', '', '/', now() - interval '3 hour'),
  (:U, :'club', :DONE, 'court_next',     '끝난 운동 대기', '', '/', now() - interval '3 hour'),
  (:U, :'club', :DONE, 'vote_soon',      '끝난 운동 투표', '', '/', now() - interval '2 day'),
  (:U, :'club', :DONE, 'vote_created',   '끝난 운동 새 운동', '', '/', now() - interval '2 day'),
  (:U, :'club', :NEXT, 'vote_soon',      '다음 운동 투표', '', '/', now() - interval '1 hour'),
  (:U, :'club', :GONE, 'vote_soon',      '취소된 운동 투표', '', '/', now() - interval '1 hour'),
  (:U, :'club', null,  'join_approved',  '31일 전', '', '/', now() - interval '31 day'),
  (:U, :'club', null,  'join_approved',  '29일 전', '', '/', now() - interval '29 day');

select pg_temp.ok(cleanup_notifications() >= 5, '정리 실행 (다른 테스트가 남긴 알림도 함께 정리될 수 있어 이 사용자 것만 아래에서 확인)');
select pg_temp.ok((select count(*) from notifications where user_id = :U
                     and title in ('끝난 운동 코트', '끝난 운동 대기', '끝난 운동 투표', '취소된 운동 투표', '31일 전')) = 0,
  '끝난·취소된 운동의 코트·투표 알림과 30일 지난 알림은 지워짐');
select pg_temp.ok((select count(*) from notifications where user_id = :U
                     and title in ('29일 전', '끝난 운동 새 운동', '다음 운동 투표')) = 3,
  '새 운동 알림·아직 안 끝난 운동·30일 안 알림은 남음');
select pg_temp.ok(not has_function_privilege('authenticated', 'public.cleanup_notifications()', 'execute'), '앱 사용자는 정리 함수를 못 부름');
