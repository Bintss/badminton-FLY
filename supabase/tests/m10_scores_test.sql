-- T2 점수 기록: 규칙 경계값, 권한, 경기 종료와 함께 입력, 나중에 입력, 동시 수정 충돌, 기권, 대회 종료 후
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
  select ('a0000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- ── 점수 규칙 경계값 (25점제, 최대 30) ───────────────────────
select pg_temp.ok(score_problem(25, 30, 25, 23) is null, '25:23 인정');
select pg_temp.ok(score_problem(25, 30, 23, 25) is null, '23:25 인정 (팀 2 승)');
select pg_temp.ok(score_problem(25, 30, 25, 0) is null, '25:0 인정');
select pg_temp.ok(score_problem(25, 30, 26, 24) is null, '26:24 인정 (듀스)');
select pg_temp.ok(score_problem(25, 30, 29, 27) is null, '29:27 인정');
select pg_temp.ok(score_problem(25, 30, 30, 28) is null, '30:28 인정');
select pg_temp.ok(score_problem(25, 30, 30, 29) is null, '30:29 인정 (최대 점수 도달)');
select pg_temp.ok(score_problem(25, 30, 25, 24) = 'need_two_point_lead', '25:24 거부');
select pg_temp.ok(score_problem(25, 30, 27, 24) = 'need_two_point_lead', '27:24 거부 (듀스 뒤엔 2점 차만)');
select pg_temp.ok(score_problem(25, 30, 29, 28) = 'need_two_point_lead', '29:28 거부');
select pg_temp.ok(score_problem(25, 30, 31, 29) = 'over_cap', '31:29 거부 (최대 점수 초과)');
select pg_temp.ok(score_problem(25, 30, 24, 22) = 'below_target', '24:22 거부 (목표 미달)');
select pg_temp.ok(score_problem(25, 30, 25, 25) = 'tie', '25:25 거부 (동점)');
select pg_temp.ok(score_problem(25, 30, 25, null) = 'missing', '한쪽 점수 없음 거부');
select pg_temp.ok(score_problem(21, null, 32, 30) is null, '21점제 최대 없음: 32:30 인정');
select pg_temp.ok(score_problem(21, null, 31, 30) = 'need_two_point_lead', '21점제 최대 없음: 31:30 거부');

-- ── 준비: 운영진 1, 회원 2~10 (10은 대회 밖). 9명 참석, 2코트, 2매치 ───
insert into auth.users (id, raw_user_meta_data)
select pg_temp.u(n), jsonb_build_object('name', '선수' || n) from generate_series(1, 10) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('점수 테스트') as club \gset
select set_config('my.club', :'club', false);
do $$ declare i int; begin
  for i in 2..10 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(current_setting('my.club')::uuid); end loop;
end $$;
reset role;
update club_members set status = 'approved' where club_id = :'club';
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count, score_target, score_cap)
values ('a0000000-0000-0000-0000-0000000000a1', :'club', 'flash', '점수 대회', now() + interval '1 hour', now() + interval '4 hour', 30, 2,
        now() - interval '1 day', 'tournament', 'draft', 2, 25, 30);
\set S 'a0000000-0000-0000-0000-0000000000a1'
set role authenticated;
do $$ declare i int; begin
  for i in 1..9 loop perform pg_temp.as_user(pg_temp.u(i)); perform register('a0000000-0000-0000-0000-0000000000a1'); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select array_agg(id order by seq)::text as regs from registrations where session_id = :'S' \gset
select set_config('my.r', :'regs', false);
create or replace function pg_temp.r(i int) returns text language sql as $$ select (current_setting('my.r')::uuid[])[i]::text $$;
grant execute on function pg_temp.r(int) to authenticated;
select save_schedule(:'S', format('[
  {"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":1,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]},
  {"round":2,"order":2,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4), pg_temp.r(5), pg_temp.r(6), pg_temp.r(7), pg_temp.r(8),
  pg_temp.r(1), pg_temp.r(5), pg_temp.r(2), pg_temp.r(6), pg_temp.r(3), pg_temp.r(7), pg_temp.r(4), pg_temp.r(9))::jsonb);
select publish_schedule(:'S');
-- 9번은 아직 안 옴
select set_checked_in(pg_temp.r(i)::uuid, true) from generate_series(1, 8) i;
select (select id from matches where session_id = :'S' and round_no = 1 and order_no = 1) as m11,
       (select id from matches where session_id = :'S' and round_no = 1 and order_no = 2) as m12,
       (select id from matches where session_id = :'S' and round_no = 2 and order_no = 1) as m21,
       (select id from matches where session_id = :'S' and round_no = 2 and order_no = 2) as m22 \gset
select pg_temp.ok((select count(*) from matches where session_id = :'S' and status = 'playing') = 2, '매치 1 두 경기 진행 중');

-- ── 경기 종료와 함께 점수 ───────────────────────────────────
select pg_temp.as_user(pg_temp.u(9));   -- 참석자지만 이 경기 선수 아님
select pg_temp.fails(format($$select finish_with_score('%s', 25, 20, 'normal')$$, :'m11'), 'score_forbidden', '경기 선수가 아니면 점수 입력 불가');
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format($$select finish_with_score('%s', 25, 24, 'normal')$$, :'m11'), 'invalid_score', '규칙에 안 맞는 점수 거부');
select pg_temp.ok((select status = 'playing' from matches where id = :'m11'), '점수 거부되면 경기도 안 끝남');
select pg_temp.fails(format($$select finish_with_score('%s', 25, 20, 'draw')$$, :'m11'), 'invalid_score', '알 수 없는 결과 종류 거부');
select finish_with_score(:'m11', 25, 21, 'normal');
select pg_temp.ok((select status = 'finished' and score1 = 25 and score2 = 21 and result_kind = 'normal' and result_by = pg_temp.u(2) and result_at is not null
                     from matches where id = :'m11'), '선수가 경기 종료와 함께 25:21 기록');
select pg_temp.fails(format($$select save_tournament_settings('%s', 2, 21, 30, 15)$$, :'S'), 'forbidden', '(일반 회원 설정 불가)');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format($$select save_tournament_settings('%s', 2, 21, 30, 15)$$, :'S'), 'score_rule_locked', '첫 점수 뒤엔 점수 규칙 변경 불가');

-- 점수 없이 종료 (나중에 입력): 경기 선수가 아닌 참석자도 코트는 비울 수 있다
select pg_temp.as_user(pg_temp.u(9));
select finish_with_score(:'m12', null, null, null);
select pg_temp.ok((select status = 'finished' and result_at is null from matches where id = :'m12'), '점수 없이 종료 → 나중에 입력');

-- ── 나중에 입력 / 수정 / 동시 수정 충돌 ─────────────────────
select pg_temp.as_user(pg_temp.u(9));
select pg_temp.fails(format($$select record_score('%s', 25, 10, 'normal', null)$$, :'m12'), 'score_forbidden', '선수 아닌 사람은 나중 입력도 불가');
select pg_temp.as_user(pg_temp.u(7));
select record_score(:'m12', 18, 25, 'normal', null) as t12 \gset
select pg_temp.ok((select score1 = 18 and score2 = 25 from matches where id = :'m12'), '선수가 나중에 18:25 입력');
-- 같은 경기를 두 폰이 같은 값을 보고 동시에 수정 → 먼저 저장한 쪽만
select pg_temp.as_user(pg_temp.u(5));
select record_score(:'m12', 20, 25, 'normal', :'t12');
select pg_temp.as_user(pg_temp.u(8));
select pg_temp.fails(format($$select record_score('%s', 25, 23, 'normal', '%s')$$, :'m12', :'t12'), 'score_conflict', '늦게 저장한 폰은 충돌로 거부');
select pg_temp.fails(format($$select record_score('%s', 25, 23, 'normal', null)$$, :'m12'), 'score_conflict', '이미 점수가 있는데 없던 걸로 보고 저장해도 충돌');
select pg_temp.ok((select score1 = 20 and score2 = 25 from matches where id = :'m12'), '먼저 저장한 20:25가 남음');
select pg_temp.as_user(pg_temp.u(5));
select pg_temp.fails(format($$select record_score('%s', 25, 23, 'normal', null)$$, :'m21'), 'match_not_finished', '진행 중인 경기는 record_score 불가 (종료할 때 입력)');

-- 기권승 기록 + 지우기
select pg_temp.as_user(pg_temp.u(1));
select record_score(:'m12', 0, 0, 'walkover2', (select result_at from matches where id = :'m12'));
select pg_temp.ok((select result_kind = 'walkover2' and score1 is null and score2 is null from matches where id = :'m12'), '운영진이 팀 2 기권승으로 수정');
select record_score(:'m12', null, null, 'clear', (select result_at from matches where id = :'m12'));
select pg_temp.ok((select result_kind is null and result_at is null from matches where id = :'m12'), '점수 지우기');
select record_score(:'m12', 20, 25, 'normal', null);

-- ── 끝내 안 온 경기 기권 처리 ───────────────────────────────
select pg_temp.ok((select status = 'playing' from matches where id = :'m21'), '매치 2-1 진행 중 (9번 없는 경기)');
select pg_temp.ok((select status = 'queued' from matches where id = :'m22'), '9번이 안 와서 2-2는 대기');
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format($$select forfeit_match('%s', 1)$$, :'m22'), 'forbidden', '일반 회원은 기권 처리 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format($$select forfeit_match('%s', 1)$$, :'m21'), 'not_forfeitable', '진행 중인 경기는 기권 처리 대상 아님');
select forfeit_match(:'m22', 1);
select pg_temp.ok((select status = 'finished' and result_kind = 'walkover1' and started_at is null from matches where id = :'m22'), '2-2 팀 1 기권승');
select pg_temp.ok((select games from session_player_stats where registration_id = pg_temp.r(9)::uuid) = 0, '기권 처리된 경기는 게임 수에 안 들어감');
select pg_temp.ok((select games from session_player_stats where registration_id = pg_temp.r(3)::uuid) = 1, '3번: 실제로 친 1경기만');

-- ── 마지막 경기 종료 → 대회 종료, 이후 권한 ─────────────────
select pg_temp.as_user(pg_temp.u(6));
select finish_with_score(:'m21', null, null, null);
select pg_temp.ok((select tournament_state = 'finished' from sessions where id = :'S'), '마지막 경기 끝 → 대회 종료');
select record_score(:'m21', 23, 25, 'normal', null);
select pg_temp.ok((select score2 = 25 from matches where id = :'m21'), '대회가 끝나도 점수 없던 경기는 선수가 입력 가능');
select pg_temp.fails(format($$select record_score('%s', 21, 25, 'normal', (select result_at from matches where id = '%s'))$$, :'m21', :'m21'),
  'score_forbidden', '대회가 끝나면 선수는 점수 수정 불가');
select pg_temp.as_user(pg_temp.u(1));
select record_score(:'m21', 21, 25, 'normal', (select result_at from matches where id = :'m21'));
select pg_temp.ok((select score1 = 21 from matches where id = :'m21'), '대회가 끝나도 운영진은 수정 가능');

-- 자율 경기에는 점수 없음
select create_match(:'S', array[pg_temp.r(1), pg_temp.r(2), pg_temp.r(3), pg_temp.r(4)]::uuid[]);
select pg_temp.fails(format($$select finish_with_score(id, 25, 20, 'normal') from matches where session_id = '%s' and phase = 'free' and status = 'playing'$$, :'S'),
  'not_scheduled', '자율 경기는 점수 기록 대상 아님');

-- 변경 이력
reset role;
select pg_temp.ok((select count(*) from activity_log where session_id = :'S' and action = 'tournament.score') >= 7
  and exists (select 1 from activity_log where session_id = :'S' and action = 'tournament.score'
               and payload -> 'before' ->> 'score1' = '23' and payload -> 'after' ->> 'score1' = '21'), '모든 입력·수정이 이전 값과 함께 기록');
