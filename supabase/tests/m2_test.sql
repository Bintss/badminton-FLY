-- M2 검증: 신청 / 취소 / 대기자 승격 / 정원 변경 / 권한
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
grant execute on all functions in schema pg_temp to authenticated;

\set A '00000000-0000-0000-0000-0000000000a1'
\set B '00000000-0000-0000-0000-0000000000b1'
\set C '00000000-0000-0000-0000-0000000000c1'
\set D '00000000-0000-0000-0000-0000000000d1'
\set E '00000000-0000-0000-0000-0000000000e1'

insert into auth.users (id, raw_user_meta_data) values
  (:'A', '{"name":"운영진"}'), (:'B', '{"name":"비"}'), (:'C', '{"name":"씨"}'),
  (:'D', '{"name":"디"}'),     (:'E', '{"name":"외부인"}');

-- 동아리 X: A 운영진, B·C·D 승인 회원, E는 비회원
set role authenticated;
select pg_temp.as_user(:'A');
select create_club('M2 테스트 동아리') as club \gset
select pg_temp.as_user(:'B'); select request_join(:'club');
select pg_temp.as_user(:'C'); select request_join(:'club');
select pg_temp.as_user(:'D'); select request_join(:'club');
select pg_temp.as_user(:'A');
select decide_member(:'club', :'B', true), decide_member(:'club', :'C', true), decide_member(:'club', :'D', true);
reset role;

-- 세션 (M3 RPC 전이라 superuser로 생성)
\set S1 '20000000-0000-0000-0000-000000000001'
\set S2 '20000000-0000-0000-0000-000000000002'
\set S3 '20000000-0000-0000-0000-000000000003'
\set S4 '20000000-0000-0000-0000-000000000004'
\set S5 '20000000-0000-0000-0000-000000000005'
insert into sessions (id, club_id, type, host_user_id, title, starts_at, ends_at, capacity, court_count, opens_at, canceled_at) values
  (:'S1', :'club', 'flash', :'A', '열림 정원2', now() + interval '2 day', now() + interval '2 day 3 hour', 2, 1, now() - interval '1 minute', null),
  (:'S2', :'club', 'flash', :'A', '오픈 전',    now() + interval '2 day', now() + interval '2 day 3 hour', 30, 5, now() + interval '1 hour', null),
  (:'S3', :'club', 'flash', :'A', '이미 시작',  now() - interval '1 hour', now() + interval '2 hour', 30, 5, now() - interval '1 day', null),
  (:'S4', :'club', 'flash', :'A', '취소됨',     now() + interval '2 day', now() + interval '2 day 3 hour', 30, 5, now() - interval '1 minute', now()),
  (:'S5', :'club', 'flash', :'B', 'B의 번개',   now() + interval '2 day', now() + interval '2 day 3 hour', 10, 2, now() - interval '1 minute', null);

set role authenticated;

-- ── 신청 불가 조건 ───────────────────────────────────────────
select pg_temp.as_user(:'E');
select pg_temp.fails($$select register('$$ || :'S1' || $$')$$, 'forbidden', '비회원은 신청 불가');
select pg_temp.as_user(:'B');
select pg_temp.fails($$select register('$$ || :'S2' || $$')$$, 'not_open', '오픈 전 신청 불가 (서버 시각 기준)');
select pg_temp.fails($$select register('$$ || :'S3' || $$')$$, 'closed', '시작한 운동은 신청 불가');
select pg_temp.fails($$select register('$$ || :'S4' || $$')$$, 'session_canceled', '취소된 운동은 신청 불가');
select pg_temp.fails($$insert into registrations (session_id, kind, user_id, status) values ('$$ || :'S1' || $$', 'member', auth.uid(), 'confirmed')$$,
                     'permission denied', 'registrations 직접 insert 불가');

-- ── 정원 2: B, C 확정 / D, A 대기 ─────────────────────────────
select pg_temp.as_user(:'B'); select registration_id as b_reg, status as b_status, queue_position as b_pos from register(:'S1', '20:00') \gset
select pg_temp.as_user(:'C'); select registration_id as c_reg, status as c_status, queue_position as c_pos from register(:'S1') \gset
select pg_temp.as_user(:'D'); select registration_id as d_reg, status as d_status, queue_position as d_pos from register(:'S1') \gset
select pg_temp.as_user(:'A'); select registration_id as a_reg, status as a_status, queue_position as a_pos from register(:'S1') \gset
select pg_temp.ok(:'b_status' = 'confirmed' and :b_pos = 1, 'B 확정 1번');
select pg_temp.ok(:'c_status' = 'confirmed' and :c_pos = 2, 'C 확정 2번');
select pg_temp.ok(:'d_status' = 'waitlisted' and :d_pos = 1, 'D 대기 1번 (정원 초과)');
select pg_temp.ok(:'a_status' = 'waitlisted' and :a_pos = 2, 'A 대기 2번 (운영진도 동일 조건)');
select pg_temp.ok((select late_eta from registrations where id = :'b_reg') = '20:00', '늦참 도착 예정 시각 저장');

select pg_temp.as_user(:'B');
select registration_id as b_again, status as b_again_status from register(:'S1') \gset
select pg_temp.ok(:'b_again' = :'b_reg' and :'b_again_status' = 'confirmed', '중복 신청은 기존 신청 반환 (연타 대비)');
select pg_temp.ok((select count(*) from registrations where session_id = :'S1' and user_id = :'B') = 1, 'B 신청은 1건뿐');

-- ── 취소 → 대기 1순위 승격 ───────────────────────────────────
select pg_temp.as_user(:'D');
select pg_temp.fails($$select cancel_registration('$$ || :'b_reg' || $$')$$, 'forbidden', '남의 신청은 취소 불가');
select pg_temp.as_user(:'B');
select cancel_registration(:'b_reg') as promoted \gset
select pg_temp.ok(:'promoted' = :'d_reg', 'B 취소 → D 승격');
select pg_temp.ok((select status = 'confirmed' and promoted_at is not null from registrations where id = :'d_reg'), 'D 확정 + promoted_at 기록');
select pg_temp.ok((select count(*) from registrations where session_id = :'S1' and kind = 'member' and status = 'confirmed') = 2, '확정 인원은 정원(2) 유지');
select pg_temp.fails($$select cancel_registration('$$ || :'b_reg' || $$')$$, 'already_canceled', '이미 취소한 신청은 다시 취소 불가');

select registration_id as b_reg2, status as b2_status, queue_position as b2_pos from register(:'S1') \gset
select pg_temp.ok(:'b2_status' = 'waitlisted' and :b2_pos = 2, 'B 재신청 → 대기 맨 뒤 (A 다음)');

select pg_temp.as_user(:'C');
select cancel_registration(:'c_reg') as promoted2 \gset
select pg_temp.ok(:'promoted2' = :'a_reg', 'C 취소 → 대기 1순위 A 승격 (seq 순서)');

select pg_temp.as_user(:'A');
select cancel_registration(:'d_reg') as promoted3 \gset
select pg_temp.ok(:'promoted3' = :'b_reg2', '운영진은 다른 회원 신청 취소 가능 → B 승격');

-- 대기자가 없을 때 취소하면 승격 없음
select coalesce(cancel_registration(:'b_reg2')::text, 'none') as promoted4 \gset
select pg_temp.ok(:'promoted4' = 'none', '대기자 없으면 승격 없음 (null)');

-- ── 늦참 시각 수정 ───────────────────────────────────────────
select pg_temp.as_user(:'A');
select set_late_eta(:'a_reg', '21:30');
select pg_temp.ok((select late_eta from registrations where id = :'a_reg') = '21:30', '본인 늦참 시각 수정');
select pg_temp.as_user(:'C');
select pg_temp.fails($$select set_late_eta('$$ || :'a_reg' || $$', '19:00')$$, 'registration_not_found', '남의 늦참 시각은 수정 불가');

-- ── 정원 변경 ────────────────────────────────────────────────
-- 현재 S1: A 확정 1명. B·C·D 다시 신청 → 정원 2라 B 확정, C·D 대기
select pg_temp.as_user(:'B'); select register(:'S1');
select pg_temp.as_user(:'C'); select register(:'S1');
select pg_temp.as_user(:'D'); select register(:'S1');
select pg_temp.ok((select count(*) from registrations where session_id = :'S1' and status = 'waitlisted') = 2, '재신청 후 대기 2명');

select pg_temp.as_user(:'C');
select pg_temp.fails($$select update_capacity('$$ || :'S1' || $$', 10)$$, 'forbidden', '일반 회원은 남의 번개 정원 변경 불가');
select pg_temp.as_user(:'A');
select pg_temp.fails($$select update_capacity('$$ || :'S1' || $$', 1)$$, 'capacity_below_confirmed', '확정 인원보다 작게 줄일 수 없음');
select pg_temp.fails($$select update_capacity('$$ || :'S1' || $$', 0)$$, 'invalid_capacity', '정원 0 불가');
select pg_temp.ok(update_capacity(:'S1', 3) = 1, '정원 2→3: 1명 승격');
select pg_temp.ok((select status from registrations where session_id = :'S1' and user_id = :'C' and status <> 'canceled') = 'confirmed', '승격 대상은 대기 1순위 C');
select pg_temp.ok(update_capacity(:'S1', 10) = 1, '정원 3→10: 남은 대기 1명 승격');
select pg_temp.ok((select capacity from sessions where id = :'S1') = 10, '정원 저장');

select pg_temp.as_user(:'B');
select pg_temp.ok(update_capacity(:'S5', 12) = 0, '번개 개설자는 자기 번개 정원 변경 가능');

-- ── 게스트는 정원 밖, 회원 누구나 취소 가능 ─────────────────────
reset role;
insert into registrations (id, session_id, kind, guest_name, added_by, status)
values ('30000000-0000-0000-0000-000000000001', :'S5', 'guest', '민수', :'B', 'confirmed');
update sessions set capacity = 1 where id = :'S5';
set role authenticated;
select pg_temp.as_user(:'C');
select status as c5_status from register(:'S5') \gset
select pg_temp.ok(:'c5_status' = 'confirmed', '게스트는 정원에 포함되지 않음 (정원 1인데 회원 확정)');
select cancel_registration('30000000-0000-0000-0000-000000000001');
select pg_temp.ok((select status from registrations where id = '30000000-0000-0000-0000-000000000001') = 'canceled', '게스트는 회원 누구나 취소 가능');

-- ── 이력 ─────────────────────────────────────────────────────
select pg_temp.ok((select count(*) from activity_log where session_id = :'S1' and action = 'registration.cancel') = 4, '취소 이력 4건');
select pg_temp.ok((select count(*) from activity_log where session_id = :'S1' and action = 'session.capacity') = 2, '정원 변경 이력 2건');

-- ── 내부 함수 비공개 ─────────────────────────────────────────
select pg_temp.fails($$select promote_waitlist('$$ || :'S1' || $$', 5)$$, 'permission denied', 'promote_waitlist는 RPC로 노출되지 않음');

reset role;
select 'ALL M2 TESTS PASSED' as result;
