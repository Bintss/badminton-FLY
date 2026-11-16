-- M1 검증: 가입/승인 흐름과 RLS 격리
-- 실행: supabase/tests/run_local.sh  (로컬 Postgres 16 + local_stub.sql)
\set ON_ERROR_STOP on
\pset footer off

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;

-- 예외가 나야 하는 SQL을 실행하고, 원하는 에러 문자열이 포함됐는지 확인
create or replace function pg_temp.fails(sql text, expect text, msg text) returns void language plpgsql as $$
begin
  begin
    execute sql;
  exception when others then
    if position(expect in sqlerrm) > 0 then
      raise notice 'PASS: % (%)', msg, sqlerrm; return;
    end if;
    raise exception 'FAIL: % — unexpected error: %', msg, sqlerrm;
  end;
  raise exception 'FAIL: % — no error raised', msg;
end $$;
grant execute on all functions in schema pg_temp to authenticated, anon;

-- 테스트 사용자 (auth.users 삽입 → 트리거로 profiles 생성)
insert into auth.users (id, raw_user_meta_data) values
  ('00000000-0000-0000-0000-00000000000a', '{"name":"운영진A"}'),
  ('00000000-0000-0000-0000-00000000000b', '{"full_name":"신입B"}'),
  ('00000000-0000-0000-0000-00000000000c', '{"user_name":"타동아리C"}'),
  ('00000000-0000-0000-0000-00000000000d', '{}');

select pg_temp.ok((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000a') = '운영진A', 'profile 자동 생성 (name)');
select pg_temp.ok((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000b') = '신입B',  'profile 자동 생성 (full_name)');
select pg_temp.ok((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000d') = '회원',    'profile 기본 이름');

-- ── A: 동아리 X 생성 ──────────────────────────────────────────
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select create_club('단국 배드민턴') as club_x \gset
select pg_temp.ok(is_club_admin(:'club_x'), 'A는 X의 운영진');

-- ── C: 동아리 Y 생성 ──────────────────────────────────────────
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select create_club('다른 동아리') as club_y \gset

-- 테스트용 세션/등록 데이터는 superuser로 직접 넣는다 (M2 RPC 전)
reset role;
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at)
values ('10000000-0000-0000-0000-000000000001', :'club_x', 'flash', 'X 번개',
        now() + interval '2 day', now() + interval '2 day 3 hour', 30, 5, now());
insert into registrations (session_id, kind, user_id, status)
values ('10000000-0000-0000-0000-000000000001', 'member', '00000000-0000-0000-0000-00000000000a', 'confirmed');

-- ── B: 가입 신청 ─────────────────────────────────────────────
set role authenticated;
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
select pg_temp.ok(request_join(:'club_x') = 'pending', 'B 가입 신청 → pending');
select pg_temp.ok(request_join(:'club_x') = 'pending', 'B 재신청은 멱등');
select pg_temp.ok((select count(*) from clubs) = 2, '로그인 사용자는 동아리 목록 열람 가능');
select pg_temp.ok((select count(*) from sessions) = 0, '승인 전 B는 세션을 볼 수 없음');
select pg_temp.ok((select count(*) from registrations) = 0, '승인 전 B는 신청 명단을 볼 수 없음');
select pg_temp.ok((select count(*) from club_members) = 1, '승인 전 B는 본인 멤버십 행만 보임');
select pg_temp.ok((select count(*) from profiles) = 1, '승인 전 B는 본인 프로필만 보임');
select pg_temp.fails($$select decide_member('$$ || :'club_x' || $$', '00000000-0000-0000-0000-00000000000b', true)$$,
                     'forbidden', 'B는 스스로 승인 불가');
select pg_temp.fails($$insert into club_members (club_id, user_id, role, status) values ('$$ || :'club_x' || $$', '00000000-0000-0000-0000-00000000000b', 'admin', 'approved')$$,
                     'permission denied', 'club_members 직접 insert 불가');
select pg_temp.fails($$update club_members set status = 'approved' where user_id = '00000000-0000-0000-0000-00000000000b'$$,
                     'permission denied', 'club_members 직접 update 불가');
select pg_temp.fails($$select log_activity('$$ || :'club_x' || $$', null, 'fake', '{}')$$,
                     'permission denied', 'log_activity는 RPC로 노출되지 않음');

-- ── A: 신청자 확인 후 승인 ───────────────────────────────────
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok((select count(*) from club_members where club_id = :'club_x' and status = 'pending') = 1, 'A는 X의 가입 신청자를 볼 수 있음');
select pg_temp.ok((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000b') = '신입B', 'A는 신청자 프로필(이름)을 볼 수 있음');
select pg_temp.ok(decide_member(:'club_x', '00000000-0000-0000-0000-00000000000b', true) = 'approved', 'A가 B 승인');
select pg_temp.fails($$select decide_member('$$ || :'club_x' || $$', '00000000-0000-0000-0000-00000000000b', true)$$,
                     'not_pending', '이미 승인된 사람은 다시 처리 불가');
select pg_temp.fails($$select set_member_role('$$ || :'club_x' || $$', '00000000-0000-0000-0000-00000000000a', 'member')$$,
                     'last_admin', '마지막 운영진은 해제 불가');
select pg_temp.ok((select count(*) from activity_log where club_id = :'club_x' and action = 'member.approve') = 1, '승인 이력 기록');

-- ── B: 승인 후 ───────────────────────────────────────────────
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000b', false);
select pg_temp.ok((select count(*) from sessions) = 1, '승인 후 B는 X 세션을 볼 수 있음');
select pg_temp.ok((select count(*) from registrations) = 1, '승인 후 B는 X 신청 명단을 볼 수 있음');
select pg_temp.ok((select count(*) from profiles) = 2, 'B는 같은 동아리 A의 프로필을 볼 수 있음');
select set_my_level(:'club_x', 'D조');
select pg_temp.ok((select level from club_members where club_id = :'club_x' and user_id = auth.uid()) = 'D조', 'B 급수 입력');
update profiles set display_name = '김신입' where id = auth.uid();
select pg_temp.ok((select display_name from profiles where id = auth.uid()) = '김신입', 'B 본인 이름 수정');
update profiles set display_name = '해킹' where id = '00000000-0000-0000-0000-00000000000a';
select pg_temp.ok((select display_name from profiles where id = '00000000-0000-0000-0000-00000000000a') = '운영진A', '남의 이름은 수정 안 됨');
select pg_temp.fails($$update club_members set level = 'A조' where user_id = auth.uid()$$,
                     'permission denied', 'club_members.level 직접 수정 불가 (RPC로만)');
select pg_temp.fails($$select set_my_level('$$ || :'club_y' || $$', 'A조')$$,
                     'not_member', '가입 안 한 동아리에 급수 입력 불가');

-- ── C: 다른 동아리 격리 ──────────────────────────────────────
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok((select count(*) from sessions) = 0, 'C는 X 세션을 볼 수 없음');
select pg_temp.ok((select count(*) from registrations) = 0, 'C는 X 신청 명단을 볼 수 없음');
select pg_temp.ok((select count(*) from club_members where club_id = :'club_x') = 0, 'C는 X 회원 명단을 볼 수 없음');
select pg_temp.ok((select count(*) from profiles where id <> auth.uid()) = 0, 'C는 X 회원 프로필을 볼 수 없음');
select pg_temp.ok((select count(*) from activity_log where club_id = :'club_x') = 0, 'C는 X 이력을 볼 수 없음');

-- ── 거절 → 재신청 ────────────────────────────────────────────
select pg_temp.ok(request_join(:'club_x') = 'pending', 'C가 X에 가입 신청');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select pg_temp.ok(decide_member(:'club_x', '00000000-0000-0000-0000-00000000000c', false) = 'rejected', 'A가 C 거절');
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000c', false);
select pg_temp.ok((select count(*) from sessions where club_id = :'club_x') = 0, '거절된 C는 여전히 X 세션 못 봄');
select pg_temp.ok(request_join(:'club_x') = 'pending', '거절 후 재신청 → pending');

-- ── 운영진 추가 후 해제 ─────────────────────────────────────
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-00000000000a', false);
select set_member_role(:'club_x', '00000000-0000-0000-0000-00000000000b', 'admin');
select set_member_role(:'club_x', '00000000-0000-0000-0000-00000000000a', 'member');
select pg_temp.ok(not is_club_admin(:'club_x'), '운영진이 2명이면 본인 해제 가능');

-- ── anon ─────────────────────────────────────────────────────
set role anon;
select set_config('request.jwt.claim.sub', '', false);
select pg_temp.fails('select count(*) from clubs', 'permission denied', 'anon은 테이블 접근 불가');
select pg_temp.fails('select server_now()', 'permission denied', 'anon은 RPC 호출 불가');

reset role;
select 'ALL M1 TESTS PASSED' as result;
