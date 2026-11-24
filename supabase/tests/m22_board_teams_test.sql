-- 대진판: 일반 경기 팀(고른 순서)
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
  select ('d2200000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 5) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('팀 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '팀 테스트'); begin
  for i in 2..5 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..5 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
select create_flash(:'club', '번개', '', now() + interval '1 hour', now() + interval '3 hour', 8, 1, now() - interval '1 hour') as fs \gset
do $$ declare i int; s uuid := (select id from sessions where title = '번개' and club_id = (select id from clubs where name = '팀 테스트')); begin
  for i in 1..5 loop perform pg_temp.as_user(pg_temp.u(i)); perform register(s); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select array_agg(r.id order by p.n)::text as r
  from registrations r join (select pg_temp.u(n) as uid, n from generate_series(1, 5) n) p on p.uid = r.user_id
 where r.session_id = :'fs' \gset
select set_checked_in(x, true) from unnest(:'r'::uuid[]) x;
-- 4, 1, 3, 2 순서로 고름
select (create_match(:'fs', array[(:'r'::uuid[])[4], (:'r'::uuid[])[1], (:'r'::uuid[])[3], (:'r'::uuid[])[2]])).match_id as m \gset
reset role;
select pg_temp.ok((select array_agg(registration_id order by registration_id) from match_players where match_id = :'m' and team = 1)
                = (select array_agg(x order by x) from unnest(array[(:'r'::uuid[])[4], (:'r'::uuid[])[1]]) x)
              and (select count(*) from match_players where match_id = :'m' and team = 2) = 2,
  '고른 순서대로 1·2번이 한 팀, 3·4번이 한 팀');
select pg_temp.ok((select body from notifications where user_id = pg_temp.u(4) and kind = 'court_assigned' order by id desc limit 1) like '파트너 선수1, 상대%',
  '코트 배정 알림에 파트너·상대가 나옴');

