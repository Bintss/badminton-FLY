-- T1 검증: 자체대회 설정, 대진 저장 검증, 초안 비공개, 확정/확정 취소, 대회 중 자율 경기 차단,
--          체크인 기반 우선 코트 배정, 30명·6코트·5매치 전체 진행(코트 중복 0, 인당 4게임),
--          선수 교체, 참석 취소된 사람 경기 건너뛰기, 일찍 끝내기, 대회 끄기
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
  select ('00000000-0000-0000-0000-0000000007' || lpad(n::text, 2, '0'))::uuid;
$$;
-- 30명 대진: 매치 r(1..5)마다 24명 출전, 6명 휴식. 휴식 블록이 매치마다 달라 모두 정확히 4게임
--   p_regs: seq 순 신청 id 배열(30개)
create or replace function pg_temp.schedule30(p_regs uuid[]) returns jsonb language sql immutable as $$
  select jsonb_agg(jsonb_build_object(
           'round', r, 'order', o,
           'team1', jsonb_build_array(p_regs[((r - 1) * 24 + (o - 1) * 4 + 0) % 30 + 1], p_regs[((r - 1) * 24 + (o - 1) * 4 + 1) % 30 + 1]),
           'team2', jsonb_build_array(p_regs[((r - 1) * 24 + (o - 1) * 4 + 2) % 30 + 1], p_regs[((r - 1) * 24 + (o - 1) * 4 + 3) % 30 + 1])))
    from generate_series(1, 5) r, generate_series(1, 6) o;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 회원 31명: 01 운영진, 01~30 참석, 31 미신청. 99 비회원
insert into auth.users (id, raw_user_meta_data)
select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 31) n;
insert into auth.users (id, raw_user_meta_data) values (pg_temp.u(99), '{"name":"외부인"}');

set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('T1 대회 테스트') as club \gset
select set_config('my.club', :'club', false);
do $$ declare i int; begin
  for i in 2..31 loop
    perform pg_temp.as_user(pg_temp.u(i));
    perform request_join(current_setting('my.club')::uuid);
  end loop;
end $$;
reset role;
update club_members set status = 'approved' where club_id = :'club';
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  ('70000000-0000-0000-0000-000000000001', :'club', 'flash', '자체대회', now() + interval '1 hour', now() + interval '5 hour', 30, 6, now() - interval '1 day', 'tournament', 'draft', 5),
  ('70000000-0000-0000-0000-000000000002', :'club', 'flash', '작은 대회', now() + interval '1 hour', now() + interval '5 hour', 30, 2, now() - interval '1 day', 'tournament', 'draft', 2),
  ('70000000-0000-0000-0000-000000000003', :'club', 'flash', '일반 번개', now() + interval '1 hour', now() + interval '5 hour', 30, 2, now() - interval '1 day', 'normal', null, null);
\set S3 '70000000-0000-0000-0000-000000000003'
\set S '70000000-0000-0000-0000-000000000001'
\set S2 '70000000-0000-0000-0000-000000000002'
set role authenticated;
do $$ declare i int; begin
  for i in 1..30 loop
    perform pg_temp.as_user(pg_temp.u(i));
    perform register('70000000-0000-0000-0000-000000000001');
  end loop;
  for i in 1..8 loop
    perform pg_temp.as_user(pg_temp.u(i));
    perform register('70000000-0000-0000-0000-000000000002');
  end loop;
end $$;

select pg_temp.as_user(pg_temp.u(1));
select array_agg(id order by seq)::text as regs from registrations where session_id = :'S' \gset
select pg_temp.ok(cardinality(:'regs'::uuid[]) = 30, '30명 참석 확정');

-- ── 대회 설정 ────────────────────────────────────────────────
-- 자체대회 만들기: 운영진만, 운동 + 대회 설정 한 번에
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format($$select create_tournament('%s', '대회', '', now() + interval '1 day', now() + interval '1 day 3 hour', 30, 6, null, 5, 25, 30, 15)$$, :'club'),
  'forbidden', '일반 회원은 자체대회를 만들 수 없음');
select pg_temp.fails(format($$select save_tournament_settings('%s', 5, 25, 30, 15)$$, :'S'), 'forbidden', '일반 회원은 대회 설정 불가');
select pg_temp.fails(format($$select save_schedule('%s', '[]')$$, :'S'), 'forbidden', '일반 회원은 대진 저장 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format($$select create_tournament('%s', '대회', '', now() + interval '1 day', now() + interval '1 day 3 hour', 30, 6, null, 0, 25, 30, 15)$$, :'club'),
  'invalid_round_count', '매치 수 0 거부');
select pg_temp.fails(format($$select create_tournament('%s', '대회', '', now() + interval '1 day', now() + interval '1 day 3 hour', 30, 6, null, 5, 25, 21, 15)$$, :'club'),
  'invalid_score_rule', '최대 점수 < 목표 점수 거부');
select create_tournament(:'club', '  ', '단국대 체육관', now() + interval '1 day', now() + interval '1 day 3 hour', 30, 6, null, 5, 21, null, 12) as t_new \gset
select pg_temp.ok((select kind = 'tournament' and tournament_state = 'draft' and round_count = 5 and score_target = 21 and score_cap is null
                     and minutes_per_game = 12 and title = '자체대회' and opens_at <= now() and capacity = 30 and court_count = 6
                     from session_overview where id = :'t_new'),
  '자체대회 만들기 → 대진 준비 중, 설정 저장, 제목 비면 "자체대회", 투표 바로 오픈');
select pg_temp.fails(format($$select save_tournament_settings('%s', 5, 25, 21, 15)$$, :'S'), 'invalid_score_rule', '설정 수정: 최대 점수 < 목표 점수 거부');
select pg_temp.fails(format($$select save_tournament_settings('%s', 5, 25, 30, 15)$$, :'S3'), 'not_tournament', '일반 운동은 대회 설정 불가 (대회로 바꾸기 없음)');
select pg_temp.fails(format($$select save_schedule('%s', '[]')$$, :'S3'), 'tournament_locked', '일반 운동엔 대진 저장 불가');

-- ── 대진 저장 검증 ───────────────────────────────────────────
select set_config('my.r', :'regs', false);
create or replace function pg_temp.r(i int) returns text language sql as $$ select (current_setting('my.r')::uuid[])[i]::text $$;
grant execute on function pg_temp.r(int) to authenticated;

select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3)), 'need_four_players', '3명 경기 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(1)), 'need_four_players', '같은 사람 두 번 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":6,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4)), 'invalid_round', '매치 수보다 큰 매치 번호 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(8)), 'duplicate_order', '같은 매치·순서 중복 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},{"round":1,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(1)), 'duplicate_in_round', '같은 매치에 한 사람 두 경기 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$,
  :'S', pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), gen_random_uuid()), 'invalid_players', '참석자가 아닌 id 거부');
select pg_temp.fails(format($$select save_schedule('%s', '[{"round":1,"order":1,"team1":["x","y"],"team2":["z","w"]}]')$$, :'S'),
  'invalid_schedule', '형식이 잘못된 입력 거부');
select pg_temp.ok((select count(*) from matches where session_id = :'S') = 0, '실패한 저장은 아무것도 남기지 않음');

select pg_temp.ok(save_schedule(:'S', pg_temp.schedule30(:'regs'::uuid[])) = 30, '30경기 대진 저장');
select pg_temp.ok(save_schedule(:'S', pg_temp.schedule30(:'regs'::uuid[])) = 30, '다시 저장해도 30경기 (전체 교체)');
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'scheduled') = 30, '대회 경기 30개');
select pg_temp.ok((select bool_and(c = 4) from (
    select count(*) c from match_players mp join matches m on m.id = mp.match_id
     where m.session_id = :'S' group by mp.registration_id) x)
  and (select count(distinct mp.registration_id) from match_players mp join matches m on m.id = mp.match_id where m.session_id = :'S') = 30,
  '30명 모두 정확히 4게임 배정');
select pg_temp.ok((select count(*) from match_players mp join matches m on m.id = mp.match_id where m.session_id = :'S' and mp.team is null) = 0,
  '팀 정보 저장');
select pg_temp.ok((select coalesce(max(queued_count), 0) from session_player_stats where session_id = :'S') = 0,
  '초안 경기는 대기 경기 수에 안 들어감');
select pg_temp.fails(format($$select save_tournament_settings('%s', 4, 25, 30, 15)$$, :'S'), 'rounds_in_use',
  '쓰고 있는 매치보다 매치 수를 줄일 수 없음');

-- ── 초안 비공개 ──────────────────────────────────────────────
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok((select count(*) from matches where session_id = :'S') = 0, '초안은 일반 회원에게 안 보임');
select pg_temp.ok((select count(*) from match_players mp join matches m on m.id = mp.match_id where m.session_id = :'S') = 0, '초안 선수 명단도 안 보임');
select pg_temp.fails(format($$select publish_schedule('%s')$$, :'S'), 'forbidden', '일반 회원은 확정 불가');

-- 초안 단계에서는 자율 경기 가능 (몸풀기). 4명이 바로 1코트에 들어감
select create_match(:'S', array[pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4)]::uuid[]);
select create_match(:'S', array[pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(8)]::uuid[]);
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'free' and status = 'playing') = 2, '초안 중 자율 경기 진행');
reset role;
-- 대기 중 자율 경기 하나 (코트가 차 있는 상황을 흉내)
insert into matches (session_id, phase, status, queue_pos) values (:'S', 'free', 'queued', 1) returning id as free_q \gset
set role authenticated;

-- ── 확정 / 확정 취소 ─────────────────────────────────────────
select pg_temp.as_user(pg_temp.u(1));
select publish_schedule(:'S');
select pg_temp.ok((select tournament_state = 'published' from sessions where id = :'S'), '확정 → published (아무도 도착 안 해서 시작 전)');
select pg_temp.ok((select status = 'canceled' from matches where id = :'free_q'), '대기 중이던 자율 경기는 정리');
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'free' and status = 'playing') = 2, '진행 중 자율 경기는 그대로');
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'scheduled' and status = 'playing') = 0, '체크인 전엔 대회 경기 시작 안 함');
select pg_temp.fails(format($$select save_tournament_settings('%s', 6, 25, 30, 15)$$, :'S'), 'tournament_locked', '확정 후 매치 수 변경 불가');
select pg_temp.fails(format($$select save_schedule('%s', '[]')$$, :'S'), 'tournament_locked', '확정 후 대진 저장 불가');
select save_tournament_settings(:'S', 5, 21, 30, 12);
select pg_temp.ok((select score_target = 21 and minutes_per_game = 12 from sessions where id = :'S'), '확정 후에도 점수제·경기당 시간은 첫 점수 전까지 변경 가능');
select unpublish_schedule(:'S');
select pg_temp.ok((select tournament_state = 'draft' from sessions where id = :'S'), '확정 취소 → draft');
select publish_schedule(:'S');

select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'scheduled') = 30, '확정 즉시 회원에게 공개');
select pg_temp.fails(format($$select create_match('%s', array['%s','%s','%s','%s']::uuid[])$$, :'S', pg_temp.r(9), pg_temp.r(10), pg_temp.r(11), pg_temp.r(12)),
  'tournament_running', '대회 중 자율 경기 생성 불가');
select (select id from matches where session_id = :'S' and phase = 'scheduled' order by round_no, order_no limit 1) as m1 \gset
select pg_temp.fails(format($$select move_match('%s', 1)$$, :'m1'), 'scheduled_order_locked', '대회 경기 순서는 바꿀 수 없음');
select pg_temp.fails(format($$select cancel_match('%s')$$, :'m1'), 'forbidden', '일반 회원은 대회 경기 취소 불가');
select pg_temp.fails(format($$select substitute_player('%s', '%s', '%s')$$, :'m1', pg_temp.r(1), pg_temp.r(30)), 'forbidden', '일반 회원은 교체 불가');

-- ── 선수 교체 ────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.u(1));
-- 매치 1 휴식: 25~30번. 1번 → 30번 교체 성공, 2번 → 5번(같은 매치 출전 중)은 거부
select pg_temp.fails(format($$select substitute_player('%s', '%s', '%s')$$, :'m1', pg_temp.r(2), pg_temp.r(5)), 'duplicate_in_round', '같은 매치에 경기 있는 사람으로 교체 불가');
select pg_temp.fails(format($$select substitute_player('%s', '%s', '%s')$$, :'m1', pg_temp.r(9), pg_temp.r(30)), 'invalid_players', '그 경기에 없는 사람은 뺄 수 없음');
select substitute_player(:'m1', pg_temp.r(1)::uuid, pg_temp.r(30)::uuid);
select pg_temp.ok((select count(*) from match_players where match_id = :'m1' and registration_id = pg_temp.r(30)::uuid) = 1, '교체 성공');
select substitute_player(:'m1', pg_temp.r(30)::uuid, pg_temp.r(1)::uuid);
select pg_temp.ok((select team from match_players where match_id = :'m1' and registration_id = pg_temp.r(1)::uuid) = 1, '되돌리면 팀도 그대로');

-- ── 도착 → 우선 코트 배정 ────────────────────────────────────
-- 1~8은 자율 경기 중. 9~24가 매치 1의 3~6번 경기. 9~20 도착
do $$ declare i int; begin
  for i in 9..20 loop perform set_checked_in(pg_temp.r(i)::uuid, true); end loop;
end $$;
select pg_temp.ok((select count(*) from matches where session_id = :'S' and phase = 'scheduled' and status = 'playing') = 3, '4명 모두 도착한 대회 경기 3개가 빈 코트로');
select pg_temp.ok((select tournament_state = 'in_progress' from sessions where id = :'S'), '첫 대회 경기 시작 → in_progress');
select pg_temp.fails(format($$select unpublish_schedule('%s')$$, :'S'), 'tournament_locked', '시작 후 확정 취소 불가');
select pg_temp.ok((select array_agg(order_no order by order_no) = '{3,4,5}' from matches where session_id = :'S' and phase = 'scheduled' and status = 'playing'),
  '준비된 경기부터 순서대로 (1·2번 경기는 선수가 자율 경기 중이라 건너뜀)');
select pg_temp.ok((select count(*) from matches where session_id = :'S' and status = 'playing') = 5, '코트 6개 중 5개 사용, 1개는 준비된 경기 없어서 빔');

-- 나머지 모두 도착
do $$ declare i int; begin
  for i in 1..30 loop
    if i < 9 or i > 20 then perform set_checked_in(pg_temp.r(i)::uuid, true); end if;
  end loop;
end $$;
select pg_temp.ok((select count(*) from matches where session_id = :'S' and status = 'playing') = 6, '모두 도착 → 6코트 꽉 참');

-- ── 끝까지 진행: 아무 경기나 끝내기를 반복하며 매번 불변식 확인 ───
do $$
declare
  v_s uuid := '70000000-0000-0000-0000-000000000001';
  v_m uuid;
  v_n int := 0;
begin
  loop
    select id into v_m from matches where session_id = v_s and status = 'playing'
     order by random() limit 1;
    exit when v_m is null;
    perform finish_match(v_m);
    v_n := v_n + 1;
    if v_n > 200 then raise exception 'FAIL: 끝나지 않음'; end if;
    if exists (select 1 from match_players mp join matches m on m.id = mp.match_id
                where m.session_id = v_s and m.status = 'playing'
                group by mp.registration_id having count(*) > 1) then
      raise exception 'FAIL: 한 사람이 두 코트에서 동시에 경기 (%번째)', v_n;
    end if;
    if exists (select 1 from matches where session_id = v_s and status = 'playing'
                group by court_no having count(*) > 1) then
      raise exception 'FAIL: 한 코트에 두 경기 (%번째)', v_n;
    end if;
    if exists (select 1 from matches where session_id = v_s and status = 'playing' and court_no > 6) then
      raise exception 'FAIL: 없는 코트 사용';
    end if;
  end loop;
  perform set_config('my.finished', v_n::text, false);
end $$;
select pg_temp.ok(current_setting('my.finished')::int = 32, '자율 2 + 대회 30 경기 모두 종료, 코트·선수 중복 0');
select pg_temp.ok((select tournament_state = 'finished' from sessions where id = :'S'), '마지막 대회 경기 종료 → finished 자동 전환');
select pg_temp.ok((select bool_and(c = 4) and count(*) = 30 from (
    select count(*) c from match_players mp join matches m on m.id = mp.match_id
     where m.session_id = :'S' and m.phase = 'scheduled' and m.status = 'finished' group by mp.registration_id) x),
  '30명 모두 대회 경기 4게임 완료');
select pg_temp.ok((select min(games) = 4 and max(games) = 5 from session_player_stats where session_id = :'S'), '게임 수 통계: 대회 4 + 자율 경기 1 (1~8번)');

select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok((select status from create_match(:'S', array[pg_temp.r(9), pg_temp.r(10), pg_temp.r(11), pg_temp.r(12)]::uuid[])) = 'playing',
  '대회가 끝나면 다시 자율 대진');

-- ── 작은 대회: 참석 취소, 일찍 끝내기, 대회 끄기 ─────────────
select pg_temp.as_user(pg_temp.u(1));
select array_agg(id order by seq)::text as regs2 from registrations where session_id = :'S2' \gset
select set_config('my.r', :'regs2', false);
select save_schedule(:'S2', format('[
  {"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":1,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(8),
  pg_temp.r(1), pg_temp.r(5), pg_temp.r(2), pg_temp.r(6), pg_temp.r(3), pg_temp.r(7), pg_temp.r(4), pg_temp.r(8))::jsonb);

select save_schedule(:'S2', format('[
  {"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":1,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(8),
  pg_temp.r(1), pg_temp.r(5), pg_temp.r(2), pg_temp.r(6), pg_temp.r(3), pg_temp.r(7), pg_temp.r(4), pg_temp.r(8))::jsonb);

-- 초안 후 참석 취소 → 확정 거부
select pg_temp.as_user(pg_temp.u(8));
select cancel_registration(pg_temp.r(8)::uuid);
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format($$select publish_schedule('%s')$$, :'S2'), 'schedule_stale', '초안 이후 참석 취소자 있으면 확정 거부');
-- 다시 참석 (새 신청 id) → 교체는 확정 후에만 가능하므로 대진을 새 id로 다시 저장
select pg_temp.as_user(pg_temp.u(8));
select registration_id as r8b from register(:'S2') \gset
select pg_temp.as_user(pg_temp.u(1));
select save_schedule(:'S2', format('[
  {"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":1,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), :'r8b',
  pg_temp.r(1), pg_temp.r(5), pg_temp.r(2), pg_temp.r(6), pg_temp.r(3), pg_temp.r(7), pg_temp.r(4), :'r8b')::jsonb);
select publish_schedule(:'S2');
select set_checked_in(id, true) from registrations where session_id = :'S2' and status = 'confirmed';
select pg_temp.ok((select count(*) from matches where session_id = :'S2' and status = 'playing') = 2, '작은 대회 매치 1 두 경기 시작');

-- 대회 중 참석 취소 허용 → 그 사람 경기는 건너뜀
select pg_temp.as_user(pg_temp.u(7));
select cancel_registration(pg_temp.r(7)::uuid);
select pg_temp.as_user(pg_temp.u(1));
select finish_match(id) from matches where session_id = :'S2' and status = 'playing' and round_no = 1 and order_no = 1;
select finish_match(id) from matches where session_id = :'S2' and status = 'playing' and round_no = 1 and order_no = 2;
select pg_temp.ok((select array_agg(order_no order by order_no) = '{1}' from matches where session_id = :'S2' and status = 'playing'),
  '취소한 7번이 있는 매치 2-2는 건너뛰고 2-1만 시작');
select pg_temp.ok((select tournament_state = 'in_progress' from sessions where id = :'S2'), '건너뛴 경기가 남아 있으면 끝나지 않음');
select pg_temp.fails(format($$select substitute_player(id, '%s', '%s') from matches where session_id = '%s' and round_no = 2 and order_no = 2$$,
  pg_temp.r(7), pg_temp.r(1), :'S2'), 'duplicate_in_round', '같은 매치 출전자로 교체 불가');

-- 일찍 끝내기: 시작 안 한 경기 취소, 진행 중인 경기는 끝까지
select pg_temp.ok(end_tournament(:'S2') = 1, '일찍 끝내기 → 남은 1경기 취소');
select pg_temp.ok((select tournament_state = 'finished' from sessions where id = :'S2'), 'finished');
select pg_temp.ok((select count(*) from matches where session_id = :'S2' and status = 'playing') = 1, '진행 중이던 경기는 계속');
select pg_temp.fails(format($$select end_tournament('%s')$$, :'S2'), 'tournament_locked', '이미 끝난 대회는 다시 끝낼 수 없음');
select pg_temp.fails(format($$select save_tournament_settings('%s', 2, 25, null, 15)$$, :'S2'), 'tournament_locked', '끝난 대회는 설정을 바꿀 수 없음 (기록 보존)');

-- 비회원
select pg_temp.as_user(pg_temp.u(99));
select pg_temp.ok((select count(*) from matches where session_id in (:'S', :'S2')) = 0, '비회원은 경기 안 보임');
select pg_temp.fails(format($$select end_tournament('%s')$$, :'S'), 'forbidden', '비회원은 대회 조작 불가');

reset role;
