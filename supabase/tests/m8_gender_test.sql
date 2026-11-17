-- 성별: 본인 입력, 운영진 수정, 게스트 성별
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
  ('80000000-0000-0000-0000-000000000001', '{"name":"운영진"}'),
  ('80000000-0000-0000-0000-000000000002', '{"name":"회원"}'),
  ('80000000-0000-0000-0000-000000000003', '{"name":"외부인"}');
\set A '80000000-0000-0000-0000-000000000001'
\set M '80000000-0000-0000-0000-000000000002'
\set X '80000000-0000-0000-0000-000000000003'

set role authenticated;
select pg_temp.as_user(:'A');
select create_club('성별 테스트') as club \gset
select pg_temp.as_user(:'M');
select request_join(:'club');
select pg_temp.as_user(:'A');
select decide_member(:'club', :'M', true);

-- 본인 입력
select pg_temp.as_user(:'M');
select set_my_gender(:'club', 'F');
select pg_temp.ok((select gender = 'F' from club_members where club_id = :'club' and user_id = :'M'), '본인이 성별 입력');
select pg_temp.fails(format($$select set_my_gender('%s', 'X')$$, :'club'), 'invalid_gender', '남/여 외 값 거부');
select set_my_gender(:'club', null);
select pg_temp.ok((select gender is null from club_members where club_id = :'club' and user_id = :'M'), '성별 지우기');
select pg_temp.fails(format($$select set_member_gender('%s', '%s', 'M')$$, :'club', :'A'), 'forbidden', '일반 회원은 남의 성별 수정 불가');
select pg_temp.as_user(:'X');
select pg_temp.fails(format($$select set_my_gender('%s', 'M')$$, :'club'), 'not_member', '비회원은 입력 불가');

-- 운영진 수정
select pg_temp.as_user(:'A');
select set_member_gender(:'club', :'M', 'M');
select pg_temp.ok((select gender = 'M' from club_members where club_id = :'club' and user_id = :'M'), '운영진이 회원 성별 지정');
select pg_temp.fails(format($$select set_member_gender('%s', '%s', 'M')$$, :'club', :'X'), 'not_member', '동아리 회원이 아니면 수정 불가');

-- 게스트
reset role;
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at) values
  ('80000000-0000-0000-0000-0000000000a1', :'club', 'flash', '번개', now() + interval '1 hour', now() + interval '3 hour', 10, 2, now() - interval '1 day');
\set S '80000000-0000-0000-0000-0000000000a1'
set role authenticated;
select pg_temp.as_user(:'M');
select register(:'S');
select add_guest(:'S', '게스트 영희', 'F') as g1 \gset
select add_guest(:'S', '게스트 철수') as g2 \gset
select pg_temp.ok((select guest_gender = 'F' from registrations where id = :'g1'), '게스트 추가할 때 성별');
select pg_temp.ok((select guest_gender is null from registrations where id = :'g2'), '성별 없이 추가 (기존 방식 호환)');
select pg_temp.fails(format($$select add_guest('%s', '이름', 'Z')$$, :'S'), 'invalid_gender', '게스트 성별 잘못된 값 거부');
select pg_temp.fails(format($$select set_guest_gender('%s', 'M')$$, :'g2'), 'forbidden', '일반 회원은 게스트 성별 수정 불가');
select pg_temp.as_user(:'A');
select set_guest_gender(:'g2', 'M');
select pg_temp.ok((select guest_gender = 'M' from registrations where id = :'g2'), '운영진이 게스트 성별 수정');
select pg_temp.fails(format($$select set_guest_gender(id, 'M') from registrations where session_id = '%s' and kind = 'member' limit 1$$, :'S'),
  'registration_not_found', '회원 신청은 게스트 성별 수정 대상 아님');
reset role;

-- ── 급수 선택 (20261117050000_level_choice) ─────────────────
set role authenticated;
select pg_temp.as_user(:'M');
select set_my_level(:'club', 'B조');
select pg_temp.ok((select level = 'B조' from club_members where club_id = :'club' and user_id = :'M'), '급수 목록에서 선택');
select pg_temp.fails(format($$select set_my_level('%s', 'B')$$, :'club'), 'invalid_level', '목록에 없는 급수(오타) 거부');
select set_my_level(:'club', '  ');
select pg_temp.ok((select level is null from club_members where club_id = :'club' and user_id = :'M'), '급수 비우기');
select pg_temp.fails(format($$select set_member_level('%s', '%s', 'A조')$$, :'club', :'A'), 'forbidden', '일반 회원은 남의 급수 수정 불가');
select pg_temp.as_user(:'A');
select set_member_level(:'club', :'M', '초심');
select pg_temp.ok((select level = '초심' from club_members where club_id = :'club' and user_id = :'M'), '운영진이 회원 급수 수정');
select pg_temp.fails(format($$select set_member_level('%s', '%s', 'E조')$$, :'club', :'M'), 'invalid_level', '운영진도 목록 밖 급수 불가');
reset role;
select pg_temp.fails($$update club_members set level = 'Z' where true$$, 'club_members_level_choice', 'DB 제약: 목록 밖 값 저장 불가');
