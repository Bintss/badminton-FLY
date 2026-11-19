-- 권한 점검: 대진판 시간 제한, 테이블 쓰기 권한, 활동 기록, 함수 노출
\set ON_ERROR_STOP on
\pset footer off
\set QUIET on

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;
create or replace function pg_temp.fails(sql text, expect text, msg text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(expect in sqlerrm) > 0 then raise notice 'PASS: % (%)', msg, sqlerrm; return; end if;
    raise exception 'FAIL: % — unexpected error: %', msg, sqlerrm;
  end;
  raise exception 'FAIL: % — no error raised', msg;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, false);
$$;
create or replace function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('e1500000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- ── 함수 노출 (운영 DB와 같은 기본 권한에서) ────────────────────
select pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')) = 0,
  '로그인 안 한 사용자(anon)가 부를 수 있는 함수 없음');
select pg_temp.ok((select count(*) from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                    where n.nspname = 'public' and p.prosecdef and p.proconfig is null) = 0,
  'security definer 함수는 모두 search_path 고정');
select pg_temp.ok(not exists (
    select 1 from information_schema.role_table_grants
     where table_schema = 'public' and grantee in ('anon', 'authenticated')
       and privilege_type in ('INSERT', 'UPDATE', 'DELETE', 'TRUNCATE')),
  '앱 사용자에게 테이블 직접 쓰기 권한 없음 (쓰기는 함수로만)');
select pg_temp.ok(not exists (
    select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
     where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity),
  '모든 테이블에 RLS');

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '회원' || n) from generate_series(1, 4) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('권한 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '권한 테스트'); begin
  for i in 2..4 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..4 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
reset role;

\set FAR  '''e1500000-0000-0000-0000-0000000000a1'''
\set NEAR '''e1500000-0000-0000-0000-0000000000a2'''
\set PAST '''e1500000-0000-0000-0000-0000000000a3'''
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at) values
  (:FAR,  :'club', 'regular', '이틀 뒤',   now() + interval '2 day',  now() + interval '2 day 3 hour', 10, 2, now() - interval '1 hour'),
  (:NEAR, :'club', 'regular', '한 시간 뒤', now() + interval '1 hour', now() + interval '4 hour',       10, 2, now() - interval '1 day'),
  (:PAST, :'club', 'regular', '어제',     now() - interval '1 day',  now() - interval '20 hour',      10, 2, now() - interval '3 day');
insert into registrations (session_id, kind, user_id, added_by, status)
select x, 'member', pg_temp.u(n), pg_temp.u(n), 'confirmed'
  from unnest(array[:FAR, :NEAR, :PAST]::uuid[]) x, generate_series(2, 3) n;

-- ── 대진판: 참석 확정자는 시작 3시간 전 ~ 끝나고 3시간만 ─────────
set role authenticated;
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok(not can_operate_board(:FAR), '이틀 뒤 운동: 참석자는 아직 대진판 조작 불가');
select pg_temp.fails($$select add_guest('e1500000-0000-0000-0000-0000000000a1', '몰래 손님')$$, 'forbidden', '미리 대진판 게스트 추가로 정원·인원 제한 우회 불가');
select pg_temp.fails(format('select set_checked_in(%L, true)',
  (select id from registrations where session_id = :FAR and user_id = pg_temp.u(3))), 'forbidden', '미리 남의 도착 처리 불가');
select pg_temp.ok(can_operate_board(:NEAR), '한 시간 뒤 운동: 참석자 조작 가능');
select pg_temp.ok(not can_operate_board(:PAST), '끝나고 3시간 지난 운동: 참석자 조작 불가');
select pg_temp.as_user(pg_temp.u(4));
select pg_temp.ok(not can_operate_board(:NEAR), '신청 안 한 회원은 조작 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok(can_operate_board(:FAR) and can_operate_board(:PAST), '운영진은 언제나');

-- 게스트 취소: 대진판 시간이 아니면 데려온 사람·운영진만
select pg_temp.as_user(pg_temp.u(3));
select registration_id as gfar from add_vote_guest(:FAR, '친구', null) \gset
select registration_id as gnear from add_vote_guest(:NEAR, '친구2', null) \gset
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format('select cancel_registration(%L)', :'gfar'), 'forbidden', '이틀 뒤 운동: 다른 참석자는 남의 게스트 취소 불가');
select cancel_registration(:'gnear');
select pg_temp.ok((select status from registrations where id = :'gnear') = 'canceled', '대진판 시간에는 참석자가 현장에서 게스트 정리 가능');

-- ── 알림 테이블은 함수로만 ──────────────────────────────────────
select pg_temp.fails($$insert into notifications (user_id, kind, title, body, url) values (auth.uid(), 'vote_soon', 'x', 'x', '/')$$, 'permission denied', '알림 직접 만들기 불가');
select pg_temp.fails($$delete from push_subscriptions$$, 'permission denied', '구독 직접 지우기 불가');
select pg_temp.fails($$truncate notification_mutes$$, 'permission denied', '알림 끄기 표 비우기 불가');
select set_notification_pref('vote_soon', false);
select pg_temp.ok((select count(*) from notification_mutes) = 1, '함수로는 그대로 됨');

-- ── 활동 기록은 운영진만 ───────────────────────────────────────
select pg_temp.ok((select count(*) from activity_log) = 0, '일반 회원은 활동 기록을 못 봄');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok((select count(*) from activity_log where club_id = :'club') > 0, '운영진은 활동 기록을 봄');
reset role;
