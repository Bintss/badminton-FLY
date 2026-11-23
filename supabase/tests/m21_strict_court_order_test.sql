-- 자체대회: 코트마다 매치 순서 고정 (앞 경기 선수가 안 오면 뒤 경기를 당겨오지 않고 기다림)
\set ON_ERROR_STOP on
\pset footer off
\set QUIET on

create or replace function pg_temp.ok(cond boolean, msg text) returns void language plpgsql as $$
begin
  if cond is distinct from true then raise exception 'FAIL: %', msg; end if;
  raise notice 'PASS: %', msg;
end $$;
create or replace function pg_temp.as_user(p uuid) returns void language sql as $$
  select set_config('request.jwt.claim.sub', p::text, false);
$$;
create or replace function pg_temp.u(n int) returns uuid language sql immutable as $$
  select ('d2100000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 12) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('순서 고정 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '순서 고정 테스트'); begin
  for i in 2..12 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..12 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
reset role;

\set S '''d2100000-0000-0000-0000-0000000000a1'''
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  (:S, :'club', 'flash', '순서 고정 대회', now() + interval '1 hour', now() + interval '4 hour', 12, 2, now() - interval '1 day', 'tournament', 'draft', 3);
set role authenticated;
do $$ declare i int; begin
  for i in 1..12 loop perform pg_temp.as_user(pg_temp.u(i)); perform register('d2100000-0000-0000-0000-0000000000a1'); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select array_agg(r.id order by p.n)::text as r
  from registrations r join (select pg_temp.u(n) as uid, n from generate_series(1, 12) n) p on p.uid = r.user_id
 where r.session_id = :S \gset
-- 코트1: 매치1 [1,2 vs 3,4] → 매치2 [9,10 vs 11,12]
-- 코트2: 매치1 [5,6 vs 7,8] → 매치2 [1,5 vs 2,6]
select save_schedule(:S, format('[
  {"round":1,"order":1,"team1":["%1$s","%2$s"],"team2":["%3$s","%4$s"]},
  {"round":1,"order":2,"team1":["%5$s","%6$s"],"team2":["%7$s","%8$s"]},
  {"round":2,"order":1,"team1":["%9$s","%10$s"],"team2":["%11$s","%12$s"]},
  {"round":2,"order":2,"team1":["%1$s","%5$s"],"team2":["%2$s","%6$s"]}]',
  (:'r'::uuid[])[1], (:'r'::uuid[])[2], (:'r'::uuid[])[3], (:'r'::uuid[])[4], (:'r'::uuid[])[5], (:'r'::uuid[])[6],
  (:'r'::uuid[])[7], (:'r'::uuid[])[8], (:'r'::uuid[])[9], (:'r'::uuid[])[10], (:'r'::uuid[])[11], (:'r'::uuid[])[12])::jsonb);
select publish_schedule(:S);

-- 선수4만 빼고 모두 도착
select set_checked_in(x, true) from unnest(:'r'::uuid[]) with ordinality t(x, i) where i <> 4;
reset role;
select pg_temp.ok((select status = 'playing' and court_no = 2 from matches where session_id = :S and round_no = 1 and order_no = 2),
  '코트2 매치1은 시작');
select pg_temp.ok(not exists (select 1 from matches where session_id = :S and status = 'playing' and court_no = 1),
  '코트1 매치1 선수가 안 왔으면 코트1은 기다림');
select pg_temp.ok((select status from matches where session_id = :S and round_no = 2 and order_no = 1) = 'queued',
  '다 와 있어도 코트1 매치2가 앞질러 들어가지 않음');

-- 선수4 도착 → 코트1 매치1
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select set_checked_in((:'r'::uuid[])[4], true);
reset role;
select pg_temp.ok((select status = 'playing' and court_no = 1 from matches where session_id = :S and round_no = 1 and order_no = 1),
  '앞 경기 선수가 오면 그 경기부터');

-- 코트2 먼저 끝남 → 코트2 매치2 선수(1·2)는 코트1에서 경기 중이라 기다림
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select finish_match((select id from matches where session_id = :S and round_no = 1 and order_no = 2));
reset role;
select pg_temp.ok((select status from matches where session_id = :S and round_no = 2 and order_no = 2) = 'queued'
              and not exists (select 1 from matches where session_id = :S and status = 'playing' and court_no = 2),
  '다음 경기 선수가 다른 코트에서 경기 중이면 그 코트는 기다림');

-- 코트1 끝남 → 코트1 매치2, 코트2 매치2 함께 시작
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select finish_match((select id from matches where session_id = :S and round_no = 1 and order_no = 1));
reset role;
select pg_temp.ok((select court_no from matches where session_id = :S and round_no = 2 and order_no = 1) = 1
              and (select court_no from matches where session_id = :S and round_no = 2 and order_no = 2) = 2,
  '앞 경기가 끝나면 각 코트의 다음 매치가 자기 코트로');
