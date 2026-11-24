-- 대진판 실사용: 코트 열기·닫기·수 바꾸기, 퇴근 처리
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
  select ('d2300000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 9) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('코트 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '코트 테스트'); begin
  for i in 2..9 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..9 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
select create_flash(:'club', '번개', '', now() + interval '1 hour', now() + interval '3 hour', 12, 2, now() - interval '1 hour') as fs \gset
do $$ declare i int; s uuid := (select id from sessions where title = '번개' and club_id = (select id from clubs where name = '코트 테스트')); begin
  for i in 1..9 loop perform pg_temp.as_user(pg_temp.u(i)); perform register(s); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select array_agg(r.id order by p.n)::text as r
  from registrations r join (select pg_temp.u(n) as uid, n from generate_series(1, 9) n) p on p.uid = r.user_id
 where r.session_id = :'fs' \gset
select set_checked_in(x, true) from unnest(:'r'::uuid[]) x;

-- ── 코트 닫기·열기 ─────────────────────────────────────────────
select set_court_open(:'fs', 1, false);
select pg_temp.ok((select closed_courts = '{1}' from sessions where id = :'fs'), '코트1 닫기');
select (create_match(:'fs', (:'r'::uuid[])[1:4])).court_no as c1 \gset
select pg_temp.ok(:'c1'::int = 2, '닫힌 코트를 건너뛰고 코트2로');
select (create_match(:'fs', (:'r'::uuid[])[5:8])).status as st2 \gset
select pg_temp.ok(:'st2' = 'queued', '열린 코트가 없으면 대기');
select set_court_open(:'fs', 1, true);
select pg_temp.ok((select count(*) from matches where session_id = :'fs' and status = 'playing' and court_no = 1) = 1, '코트를 열면 대기 경기가 바로 들어감');
select pg_temp.fails(format('select set_court_open(%L, 5, false)', :'fs'), 'invalid_court', '없는 코트는 못 닫음');

-- ── 코트 수 ────────────────────────────────────────────────────
select pg_temp.fails(format('select set_court_count(%L, 1)', :'fs'), 'court_in_use', '경기 중인 코트를 없애는 건 불가');
select set_court_count(:'fs', 3);
select set_court_open(:'fs', 3, false);
select set_court_count(:'fs', 4);
select pg_temp.ok((select court_count = 4 and closed_courts = '{3}' from sessions where id = :'fs'), '코트 늘리기 (닫힌 코트는 그대로)');
select set_court_count(:'fs', 2);
select pg_temp.ok((select court_count = 2 and closed_courts = '{}' from sessions where id = :'fs'), '줄이면 없어진 코트의 닫힘 표시도 정리');
-- 확정자도 코트 조작 가능 (대진판 조작 권한)
select pg_temp.as_user(pg_temp.u(9));
select set_court_open(:'fs', 2, false);
select set_court_open(:'fs', 2, true);
select pg_temp.ok(true, '참석 확정자도 코트 열고 닫기 가능');

-- ── 퇴근 ───────────────────────────────────────────────────────
-- 선수9를 대기 경기에 넣어 둠: 선수9 + 1,2,3 (1~4는 코트에서 경기 중 → 대기)
select pg_temp.as_user(pg_temp.u(1));
select (create_match(:'fs', array[(:'r'::uuid[])[9], (:'r'::uuid[])[1], (:'r'::uuid[])[2], (:'r'::uuid[])[3]])).match_id as q \gset
select pg_temp.as_user(pg_temp.u(5));
select pg_temp.fails(format('select set_left(%L, true)', (:'r'::uuid[])[9]), 'forbidden', '다른 사람 퇴근은 운영진만');
select pg_temp.fails(format('select set_left(%L, true)', (:'r'::uuid[])[5]), 'playing_now', '경기 중에는 퇴근 처리 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok(set_left((:'r'::uuid[])[9], true) = 1, '운영진이 퇴근 처리 → 대기 경기 1개 취소');
reset role;
select pg_temp.ok((select status = 'canceled' from matches where id = :'q'), '그 사람이 들어간 대기 경기는 취소');
select pg_temp.ok((select left_at is not null and checked_in_at is null from registrations where id = (:'r'::uuid[])[9]), '퇴근: 도착 해제·퇴근 시각');
select pg_temp.ok((select left_at is not null from session_player_stats where registration_id = (:'r'::uuid[])[9]), '대진판 통계에 퇴근 표시');
set role authenticated;
select pg_temp.as_user(pg_temp.u(9));
select set_left((:'r'::uuid[])[9], false);
select pg_temp.ok((select left_at is null and checked_in_at is not null from registrations where id = (:'r'::uuid[])[9]), '본인이 복귀');
select set_left((:'r'::uuid[])[9], true);
select pg_temp.as_user(pg_temp.u(1));
select set_checked_in((:'r'::uuid[])[9], true);
select pg_temp.ok((select left_at is null from registrations where id = (:'r'::uuid[])[9]), '퇴근한 사람을 도착 처리해도 복귀');
reset role;
