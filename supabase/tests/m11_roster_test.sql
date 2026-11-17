-- T3 명단 관리: 회원 추가(정원 늘림, 대기자 확정), 빼기(대기 승격, 대회 경기 수), 게스트 미리 추가, 권한, 대회 종료 후 잠금
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
  select ('b0000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 운영진 1, 회원 2~8, 외부인 9. 정원 4: 1~4 확정, 5·6 대기
insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '회원' || n) from generate_series(1, 9) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('명단 테스트') as club \gset
select set_config('my.club', :'club', false);
do $$ declare i int; begin
  for i in 2..8 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(current_setting('my.club')::uuid); end loop;
end $$;
reset role;
update club_members set status = 'approved' where club_id = :'club';
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  ('b0000000-0000-0000-0000-0000000000a1', :'club', 'flash', '대회', now() + interval '1 day', now() + interval '1 day 4 hour', 4, 1, now() - interval '1 day', 'tournament', 'draft', 2),
  ('b0000000-0000-0000-0000-0000000000a2', :'club', 'flash', '일반 번개', now() + interval '1 day', now() + interval '1 day 2 hour', 4, 1, now() - interval '1 day', 'normal', null, null);
\set S 'b0000000-0000-0000-0000-0000000000a1'
\set N 'b0000000-0000-0000-0000-0000000000a2'
set role authenticated;
do $$ declare i int; begin
  for i in 1..6 loop perform pg_temp.as_user(pg_temp.u(i)); perform register('b0000000-0000-0000-0000-0000000000a1'); end loop;
end $$;
select pg_temp.ok((select confirmed_count = 4 and waitlist_count = 2 from session_overview where id = :'S'), '준비: 확정 4, 대기 2');

-- 권한·대상
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format($$select roster_add_member('%s', '%s')$$, :'S', pg_temp.u(7)), 'forbidden', '일반 회원은 명단 추가 불가');
select pg_temp.fails(format($$select roster_add_guest('%s', '게스트', 'M', 'C조')$$, :'S'), 'forbidden', '일반 회원은 게스트 미리 추가 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format($$select roster_add_member('%s', '%s')$$, :'N', pg_temp.u(7)), 'not_tournament', '일반 운동은 명단 관리 대상 아님');
select pg_temp.fails(format($$select roster_add_member('%s', '%s')$$, :'S', pg_temp.u(9)), 'not_member', '동아리 회원이 아니면 추가 불가');
select pg_temp.fails(format($$select roster_add_member('%s', '%s')$$, :'S', pg_temp.u(2)), 'already_registered', '이미 확정된 사람은 다시 추가 불가');

-- 미신청 회원 추가 → 정원 늘림
select roster_add_member(:'S', pg_temp.u(7)) as r7 \gset
select pg_temp.ok((select status = 'confirmed' and added_by = pg_temp.u(1) from registrations where id = :'r7'), '미신청 회원을 참석 확정으로 추가');
select pg_temp.ok((select capacity = 5 and confirmed_count = 5 and waitlist_count = 2 from session_overview where id = :'S'), '정원이 차 있으면 정원 +1, 대기자는 그대로');
-- 대기자 바로 확정
select roster_add_member(:'S', pg_temp.u(6));
select pg_temp.ok((select status = 'confirmed' and promoted_at is not null from registrations where session_id = :'S' and user_id = pg_temp.u(6) and status <> 'canceled'), '대기자를 바로 확정');
select pg_temp.ok((select capacity = 6 and confirmed_count = 6 and waitlist_count = 1 from session_overview where id = :'S'), '정원 6, 대기 1 (5번만 남음)');
select pg_temp.ok((select count(*) from registrations where session_id = :'S' and user_id = pg_temp.u(6)) = 1, '대기 신청을 확정으로 바꿀 뿐 새 신청을 만들지 않음');

-- 게스트 미리 추가
select pg_temp.fails(format($$select roster_add_guest('%s', '게스트', 'M', 'B')$$, :'S'), 'invalid_level', '게스트 급수도 목록에서만');
select roster_add_guest(:'S', '  게스트 철수 ', 'M', 'C조') as g1 \gset
select pg_temp.ok((select guest_name = '게스트 철수' and guest_gender = 'M' and guest_level = 'C조' and checked_in_at is null and status = 'confirmed'
                     from registrations where id = :'g1'), '게스트 미리 추가: 이름·성별·급수, 도착 처리는 안 함');
select set_guest_level(:'g1', 'B조');
select pg_temp.ok((select guest_level = 'B조' from registrations where id = :'g1'), '게스트 급수 수정');

-- 빼기 → 대기 승격
select pg_temp.ok(roster_remove(x.r) = 0, '확정자 빼기 (대회 경기 없음)') from (select id as r from registrations where session_id = :'S' and user_id = pg_temp.u(3) and status = 'confirmed') x;
select pg_temp.ok((select status = 'confirmed' from registrations where session_id = :'S' and user_id = pg_temp.u(5) and status <> 'canceled'), '뺀 자리에 대기 1번(5번) 자동 확정');
select pg_temp.fails(format($$select roster_remove(id) from registrations where session_id = '%s' and user_id = '%s' and status = 'canceled'$$, :'S', pg_temp.u(3)),
  'already_canceled', '이미 취소된 신청은 다시 뺄 수 없음');
select pg_temp.as_user(pg_temp.u(3));
select pg_temp.ok((select status from register(:'S')) = 'waitlisted', '뺀 사람이 다시 신청하면 맨 뒤 대기');
select pg_temp.as_user(pg_temp.u(1));

-- 대진 확정 후 빼기 → 대회 경기 수 돌려줌, 그 경기는 건너뜀
select array_agg(id order by seq)::text as regs from registrations where session_id = :'S' and status = 'confirmed' and kind = 'member' \gset
select set_config('my.r', :'regs', false);
create or replace function pg_temp.r(i int) returns text language sql as $$ select (current_setting('my.r')::uuid[])[i]::text $$;
grant execute on function pg_temp.r(int) to authenticated;
select save_schedule(:'S', format('[
  {"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(1), pg_temp.r(3), pg_temp.r(2), pg_temp.r(5))::jsonb);
select publish_schedule(:'S');
select pg_temp.ok(roster_remove(pg_temp.r(2)::uuid) = 2, '대회 경기 2개에 든 사람을 빼면 2를 돌려줌');
select pg_temp.ok((select status = 'canceled' from registrations where id = pg_temp.r(2)::uuid), '뺀 사람은 취소');
select set_checked_in(id, true) from registrations where session_id = :'S' and status = 'confirmed';
select pg_temp.ok((select count(*) from matches where session_id = :'S' and status = 'playing') = 0, '뺀 사람이 든 경기는 코트에 안 들어감 (선수 교체 필요)');
select substitute_player(id, pg_temp.r(2)::uuid, pg_temp.r(6)::uuid) from matches where session_id = :'S' and round_no = 1;
select pg_temp.ok((select count(*) from matches where session_id = :'S' and status = 'playing') = 1, '교체하면 바로 코트로');

-- 대회 종료 후 잠금
select end_tournament(:'S');
select pg_temp.fails(format($$select roster_add_member('%s', '%s')$$, :'S', pg_temp.u(8)), 'tournament_locked', '대회가 끝나면 명단 추가 불가');
select pg_temp.fails(format($$select roster_add_guest('%s', '게스트', null, null)$$, :'S'), 'tournament_locked', '대회가 끝나면 게스트 미리 추가 불가');

-- 변경 이력
reset role;
select pg_temp.ok((select count(*) from activity_log where session_id = :'S' and action like 'roster.%') = 5, '명단 변경 이력 5건 (추가 2, 게스트 1, 빼기 2)');
select pg_temp.ok((select (payload ->> 'capacity_raised')::boolean from activity_log where session_id = :'S' and action = 'roster.add' order by id limit 1), '정원을 늘린 것도 기록');
