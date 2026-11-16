\set ON_ERROR_STOP on
create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;

-- 공통 불변식: 확정 ≤ 정원, 대기자는 모두 확정자보다 뒤 순번, 회원당 활성 신청 1건
create or replace function pg_temp.invariants(p_session uuid, label text) returns void language plpgsql as $$
declare v_cap int; v_conf int; v_wait int; v_maxconf bigint; v_minwait bigint; v_dup int;
begin
  select capacity into v_cap from sessions where id = p_session;
  select count(*) filter (where status = 'confirmed'), count(*) filter (where status = 'waitlisted'),
         max(seq) filter (where status = 'confirmed'), min(seq) filter (where status = 'waitlisted')
    into v_conf, v_wait, v_maxconf, v_minwait
    from registrations where session_id = p_session and kind = 'member';
  select count(*) into v_dup from (
    select user_id from registrations where session_id = p_session and status <> 'canceled'
    group by user_id having count(*) > 1) d;
  perform pg_temp.ok(v_conf <= v_cap, format('%s: 확정 %s ≤ 정원 %s', label, v_conf, v_cap));
  perform pg_temp.ok(v_wait = 0 or v_conf = v_cap, format('%s: 대기자가 있으면 정원이 꽉 참', label));
  perform pg_temp.ok(v_minwait is null or v_maxconf < v_minwait, format('%s: 모든 대기자는 확정자보다 늦게 도착', label));
  perform pg_temp.ok(v_dup = 0, format('%s: 회원당 활성 신청 1건 (중복 %s)', label, v_dup));
end $$;

select pg_temp.invariants('40000000-0000-0000-0000-000000000001', 'S1 동시 100명');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000001') = 100, 'S1: 100건 모두 접수');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000001' and status = 'confirmed') = 30, 'S1: 정확히 30명 확정');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000001' and status = 'waitlisted') = 70, 'S1: 70명 대기');

select pg_temp.invariants('40000000-0000-0000-0000-000000000002', 'S2 동시 중복');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000002') = 50, 'S2: 100번 요청 → 50명분만 생성');

select pg_temp.invariants('40000000-0000-0000-0000-000000000003', 'S3 취소·신청 경합');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000003' and status = 'canceled') = 20, 'S3: 20건 취소');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000003' and status = 'confirmed') = 30, 'S3: 확정은 30명 유지');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000003' and promoted_at is not null) = 20, 'S3: 20명 승격');
select pg_temp.ok((select bool_and(user_id between '00000000-0000-0000-0000-000000000031' and '00000000-0000-0000-0000-000000000050')
                     from registrations where session_id = '40000000-0000-0000-0000-000000000003' and promoted_at is not null),
                  'S3: 승격된 사람은 기존 대기 1~20순위 (새 신청자보다 우선)');
select pg_temp.ok((select count(*) from registrations where session_id = '40000000-0000-0000-0000-000000000003' and status = 'waitlisted') = 50, 'S3: 대기 50명 (기존 10 + 신규 40)');
select 'ALL LOAD TESTS PASSED' as result;
