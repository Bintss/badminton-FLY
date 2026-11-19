-- 회원 내보내기·강퇴·해제, 동아리 나가기, 동아리 삭제
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

insert into auth.users (id, raw_user_meta_data) values
  ('90000000-0000-0000-0000-000000000001', '{"name":"운영진"}'),
  ('90000000-0000-0000-0000-000000000002', '{"name":"내보낼 사람"}'),
  ('90000000-0000-0000-0000-000000000003', '{"name":"강퇴할 사람"}'),
  ('90000000-0000-0000-0000-000000000004', '{"name":"대기자"}'),
  ('90000000-0000-0000-0000-000000000005', '{"name":"부운영진"}'),
  ('90000000-0000-0000-0000-000000000006', '{"name":"신청자"}');
\set A '90000000-0000-0000-0000-000000000001'
\set R '90000000-0000-0000-0000-000000000002'
\set B '90000000-0000-0000-0000-000000000003'
\set W '90000000-0000-0000-0000-000000000004'
\set A2 '90000000-0000-0000-0000-000000000005'
\set P '90000000-0000-0000-0000-000000000006'

set role authenticated;
select pg_temp.as_user(:'A');
select create_club('내보내기 테스트') as club \gset
do $$ declare u uuid; begin
  foreach u in array array['90000000-0000-0000-0000-000000000002','90000000-0000-0000-0000-000000000003',
                           '90000000-0000-0000-0000-000000000004','90000000-0000-0000-0000-000000000005',
                           '90000000-0000-0000-0000-000000000006']::uuid[] loop
    perform pg_temp.as_user(u);
    perform request_join((select id from clubs where name = '내보내기 테스트'));
  end loop;
end $$;
select pg_temp.as_user(:'A');
select decide_member(:'club', u, true) from unnest(array[:'R', :'B', :'W', :'A2']::uuid[]) u;
select set_member_role(:'club', :'A2', 'admin');

-- 정원 1명 운동: B 확정, W 대기 / 지난 운동: B 확정 기록
reset role;
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at) values
  ('90000000-0000-0000-0000-0000000000a1', :'club', 'flash', '다음 운동', now() + interval '1 day', now() + interval '1 day 2 hour', 1, 1, now() - interval '1 day'),
  ('90000000-0000-0000-0000-0000000000a2', :'club', 'flash', '지난 운동', now() + interval '1 hour', now() + interval '3 hour', 10, 1, now() - interval '1 day');
\set S1 '90000000-0000-0000-0000-0000000000a1'
\set S2 '90000000-0000-0000-0000-0000000000a2'
set role authenticated;
select pg_temp.as_user(:'B'); select register(:'S1'); select register(:'S2');
select pg_temp.as_user(:'W'); select register(:'S1');
reset role;
update sessions set starts_at = now() - interval '1 hour', ends_at = now() + interval '1 hour' where id = :'S2';   -- 이미 시작한 운동
set role authenticated;

-- 권한 (로컬 테스트 설정이 넣은 서비스 관리자 표시는 빼고 동아리 권한만 본다)
reset role;
delete from platform_admins where user_id::text like '90000000-0000-0000-0000-%';
set role authenticated;
select pg_temp.as_user(:'R');
select pg_temp.fails(format($$select remove_member('%s', '%s', false)$$, :'club', :'B'), 'forbidden', '일반 회원은 내보내기 불가');
select pg_temp.fails(format($$select delete_club('%s', '내보내기 테스트')$$, :'club'), 'forbidden', '일반 회원은 동아리 삭제 불가');
select pg_temp.as_user(:'A');
select pg_temp.fails(format($$select remove_member('%s', '%s', false)$$, :'club', :'A'), 'cannot_remove_self', '자기 자신은 내보낼 수 없음');
select pg_temp.fails(format($$select remove_member('%s', '%s', false)$$, :'club', :'A2'), 'is_admin', '운영진은 먼저 운영진 해제');

-- 내보내기: 다시 신청 가능
select pg_temp.ok(remove_member(:'club', :'R', false) = 0, '내보내기 (취소할 신청 없음)');
select pg_temp.ok((select status = 'left' and banned_at is null from club_members where club_id = :'club' and user_id = :'R'), '내보낸 사람은 left');
select pg_temp.as_user(:'R');
select pg_temp.ok((select count(*) from sessions where club_id = :'club') = 0, '내보낸 사람은 운동 목록을 못 봄');
select pg_temp.ok(request_join(:'club') = 'pending', '내보낸 사람은 다시 가입 신청 가능');

-- 강퇴: 다음 운동 신청 취소 + 대기자 승격, 지난 운동 기록은 유지, 재신청 불가
select pg_temp.as_user(:'A');
select pg_temp.ok(remove_member(:'club', :'B', true) = 1, '강퇴 → 아직 시작 안 한 운동 신청 1건 취소');
select pg_temp.ok((select status = 'canceled' from registrations where session_id = :'S1' and user_id = :'B'), '다음 운동 신청 취소됨');
select pg_temp.ok((select status = 'confirmed' from registrations where session_id = :'S1' and user_id = :'W'), '빈자리에 대기자 승격');
select pg_temp.ok((select status = 'confirmed' from registrations where session_id = :'S2' and user_id = :'B'), '이미 시작한 운동 기록은 그대로');
select pg_temp.ok((select banned_at is not null from club_members where club_id = :'club' and user_id = :'B'), '강퇴 표시');
select pg_temp.as_user(:'B');
select pg_temp.fails(format($$select request_join('%s')$$, :'club'), 'banned', '강퇴된 사람은 다시 가입 신청 불가');

-- 해제
select pg_temp.as_user(:'R');
select pg_temp.fails(format($$select unban_member('%s', '%s')$$, :'club', :'B'), 'forbidden', '일반 회원은 강퇴 해제 불가');
select pg_temp.as_user(:'A');
select pg_temp.fails(format($$select unban_member('%s', '%s')$$, :'club', :'R'), 'not_banned', '강퇴 안 된 사람은 해제 대상 아님');
select unban_member(:'club', :'B');
select pg_temp.as_user(:'B');
select pg_temp.ok(request_join(:'club') = 'pending', '해제되면 다시 가입 신청 가능 (자동 가입은 아님)');

-- 신청자 강퇴
select pg_temp.as_user(:'A');
select ban_applicant(:'club', :'P');
select pg_temp.as_user(:'P');
select pg_temp.fails(format($$select request_join('%s')$$, :'club'), 'banned', '강퇴된 신청자는 다시 신청 불가');

-- 나가기
select pg_temp.as_user(:'W');
select pg_temp.ok(leave_club(:'club') = 1, '나가기 → 다음 운동 신청 취소');
select pg_temp.ok((select status = 'left' from club_members where club_id = :'club' and user_id = :'W'), '나간 사람은 left');
select pg_temp.as_user(:'A2');
select leave_club(:'club');
select pg_temp.as_user(:'A');
select pg_temp.fails(format($$select leave_club('%s')$$, :'club'), 'last_admin', '마지막 운영진은 나갈 수 없음');

-- 동아리 삭제
select pg_temp.fails(format($$select delete_club('%s', '내보내기 테스')$$, :'club'), 'confirm_name_mismatch', '이름이 다르면 삭제 안 됨');
select delete_club(:'club', '내보내기 테스트');
reset role;
select pg_temp.ok((select count(*) from clubs where id = :'club') = 0
  and (select count(*) from sessions where club_id = :'club') = 0
  and (select count(*) from club_members where club_id = :'club') = 0
  and (select count(*) from registrations where session_id in (:'S1', :'S2')) = 0, '동아리 삭제 → 운동·회원·신청 모두 삭제');
