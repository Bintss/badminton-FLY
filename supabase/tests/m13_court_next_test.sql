-- 자체대회: 경기마다 코트 고정 + 코트 대기(court_next) 알림
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
  select ('d1300000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 코트 번호 규칙
select pg_temp.ok(scheduled_court(1, 2) = 1 and scheduled_court(2, 2) = 2 and scheduled_court(3, 2) = 1 and scheduled_court(5, 4) = 1,
  '순서 번호 = 코트 번호, 코트보다 많으면 돌아가며');

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 8) n;

set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('코트대기 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '코트대기 테스트'); begin
  for i in 2..8 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..8 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
reset role;

\set S '''d1300000-0000-0000-0000-0000000000a1'''
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  (:S, :'club', 'flash', '코트대기 대회', now() + interval '1 hour', now() + interval '4 hour', 10, 2, now() - interval '1 day', 'tournament', 'draft', 2);

set role authenticated;
do $$ declare i int; begin
  for i in 1..8 loop perform pg_temp.as_user(pg_temp.u(i)); perform register('d1300000-0000-0000-0000-0000000000a1'); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
-- r[n] = 선수n의 신청
select array_agg(r.id order by p.n)::text as r
  from registrations r join (select pg_temp.u(n) as uid, n from generate_series(1, 8) n) p on p.uid = r.user_id
 where r.session_id = :S \gset
-- 매치1: 코트1 [1,2 vs 3,4], 코트2 [5,6 vs 7,8] / 매치2: 코트1 [1,5 vs 2,6], 코트2 [3,7 vs 4,8]
select save_schedule(:S, format('[
  {"round":1,"order":1,"team1":["%1$s","%2$s"],"team2":["%3$s","%4$s"]},
  {"round":1,"order":2,"team1":["%5$s","%6$s"],"team2":["%7$s","%8$s"]},
  {"round":2,"order":1,"team1":["%1$s","%5$s"],"team2":["%2$s","%6$s"]},
  {"round":2,"order":2,"team1":["%3$s","%7$s"],"team2":["%4$s","%8$s"]}]',
  (:'r'::uuid[])[1], (:'r'::uuid[])[2], (:'r'::uuid[])[3], (:'r'::uuid[])[4],
  (:'r'::uuid[])[5], (:'r'::uuid[])[6], (:'r'::uuid[])[7], (:'r'::uuid[])[8])::jsonb);
select publish_schedule(:S);
reset role;
select pg_temp.ok((select count(*) from notifications where kind = 'court_next' and session_id = :S) = 0,
  '공개만 하고 아무도 안 왔으면 대기 알림 없음 (몇 시간 전에 울리지 않게)');

set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select set_checked_in(x, true) from unnest(:'r'::uuid[]) x;
reset role;

select pg_temp.ok((select court_no from matches where session_id = :S and round_no = 1 and order_no = 1) = 1
               and (select court_no from matches where session_id = :S and round_no = 1 and order_no = 2) = 2,
  '매치1: 1경기 → 코트1, 2경기 → 코트2');
select pg_temp.ok((select count(*) from notifications where kind = 'court_next' and session_id = :S) = 8,
  '매치2 선수 8명에게 코트 대기 알림');
select pg_temp.ok((select title = '코트 1 다음 경기 (매치 2)'
                      and body = '지금 경기가 끝나면 바로 들어가요. 파트너 선수5, 상대 선수2, 선수6'
                      and url = '/c/' || :'club' || '/s/' || :S || '/board'
                     from notifications where kind = 'court_next' and user_id = pg_temp.u(1)),
  '제목에 코트·매치, 내용에 파트너·상대, 대진판으로 이동');
select pg_temp.ok((select title from notifications where kind = 'court_next' and user_id = pg_temp.u(4)) = '코트 2 다음 경기 (매치 2)',
  '코트2 다음 경기 선수에게는 코트 2');

-- 코트2가 먼저 끝남: 코트2 다음 경기(선수3·4가 아직 코트1)는 못 들어가고, 코트1 경기를 끌어오지도 않음
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select finish_match((select id from matches where session_id = :S and round_no = 1 and order_no = 2));
reset role;
select pg_temp.ok(not exists (select 1 from matches where session_id = :S and status = 'playing' and court_no = 2),
  '코트2는 자기 경기 선수가 올 때까지 비워 둠');
select pg_temp.ok((select status from matches where session_id = :S and round_no = 2 and order_no = 1) = 'queued',
  '코트1 경기를 코트2로 끌어오지 않음');

set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select finish_match((select id from matches where session_id = :S and round_no = 1 and order_no = 1));
reset role;
select pg_temp.ok((select court_no from matches where session_id = :S and round_no = 2 and order_no = 1) = 1
               and (select court_no from matches where session_id = :S and round_no = 2 and order_no = 2) = 2,
  '코트1이 끝나면 매치2 두 경기가 각자 코트로');
select pg_temp.ok((select count(*) from notifications where kind = 'court_next' and session_id = :S) = 8,
  '대기 알림은 경기마다 한 번');
select pg_temp.ok((select title from notifications where kind = 'court_assigned' and user_id = pg_temp.u(3) order by id desc limit 1) = '코트 2에서 경기 시작 (매치 2)',
  '들어갈 때는 코트 배정 알림');

-- 끄기
set role authenticated;
select pg_temp.as_user(pg_temp.u(2));
select set_notification_pref('court_next', false);
select pg_temp.ok((select count(*) from notification_mutes where kind = 'court_next') = 1, '코트 대기 알림 끄기');
reset role;
