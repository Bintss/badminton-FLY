-- M5 검증: 체크인, 게스트, 경기 생성/종료/취소/순서, 자동 코트 배정, 게임 수 집계
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

-- 회원 10명: 01(운영진) 02~09 참석, 10은 회원이지만 미신청. 99는 비회원
insert into auth.users (id, raw_user_meta_data)
select ('00000000-0000-0000-0000-0000000005' || lpad(n::text, 2, '0'))::uuid, jsonb_build_object('name', '회원' || n)
from generate_series(1, 10) n;
insert into auth.users (id, raw_user_meta_data) values ('00000000-0000-0000-0000-000000000599', '{"name":"외부인"}');

set role authenticated;
select pg_temp.as_user('00000000-0000-0000-0000-000000000501');
select create_club('M5 테스트') as club \gset
select set_config('my.club', :'club', false);
do $$ declare i int; begin
  for i in 2..10 loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000005' || lpad(i::text, 2, '0'), false);
    perform request_join(current_setting('my.club', true)::uuid);
  end loop;
end $$;
reset role;
-- 승인과 세션은 superuser로 (가입 흐름은 M1에서 검증)
update club_members set status = 'approved' where club_id = :'club';
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at)
values ('50000000-0000-0000-0000-000000000001', :'club', 'flash', '대진 테스트', now() + interval '1 hour', now() + interval '4 hour', 30, 2, now() - interval '1 day');
\set S '50000000-0000-0000-0000-000000000001'
set role authenticated;
do $$ declare i int; begin
  for i in 2..9 loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-0000000005' || lpad(i::text, 2, '0'), false);
    perform register('50000000-0000-0000-0000-000000000001');
  end loop;
end $$;

-- 신청 id를 변수로: r2..r9
select pg_temp.as_user('00000000-0000-0000-0000-000000000502');
select max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000502') as r2,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000503') as r3,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000504') as r4,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000505') as r5,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000506') as r6,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000507') as r7,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000508') as r8,
       max(id::text) filter (where user_id = '00000000-0000-0000-0000-000000000509') as r9
  from registrations where session_id = :'S' \gset

-- ── 권한 ─────────────────────────────────────────────────────
select pg_temp.as_user('00000000-0000-0000-0000-000000000510');
select pg_temp.fails(format($$select add_guest('%s', '민수')$$, :'S'), 'forbidden', '신청 안 한 회원은 대진판 조작 불가');
select pg_temp.as_user('00000000-0000-0000-0000-000000000599');
select pg_temp.fails(format($$select set_checked_in('%s', true)$$, :'r2'), 'forbidden', '비회원은 체크인 불가');
select pg_temp.ok((select count(*) from session_player_stats) = 0, '비회원은 통계 뷰에서 아무것도 안 보임');

-- ── 체크인 / 게스트 ──────────────────────────────────────────
select pg_temp.as_user('00000000-0000-0000-0000-000000000502');
select set_checked_in(:'r3', true);
select pg_temp.ok((select checked_in_at is not null from registrations where id = :'r3'), '참석자는 다른 사람 체크인 대신 가능');
select set_checked_in(:'r3', false);
select pg_temp.ok((select checked_in_at is null from registrations where id = :'r3'), '체크인 취소');
select add_guest(:'S', '  게스트민수  ') as g1 \gset
select pg_temp.ok((select kind = 'guest' and guest_name = '게스트민수' and status = 'confirmed' and checked_in_at is not null from registrations where id = :'g1'), '게스트 추가 (이름만, 바로 체크인)');
select pg_temp.fails(format($$select add_guest('%s', '   ')$$, :'S'), 'invalid_name', '빈 이름 게스트 불가');
select pg_temp.as_user('00000000-0000-0000-0000-000000000501');
select pg_temp.ok((select count(*) from registrations where id = :'g1') = 1, '운영진(미신청)도 대진판 조회·조작 가능');

-- ── 경기 만들기 검증 ─────────────────────────────────────────
select pg_temp.as_user('00000000-0000-0000-0000-000000000502');
select pg_temp.fails(format($$select create_match('%s', array['%s','%s','%s']::uuid[])$$, :'S', :'r2', :'r3', :'r4'), 'need_four_players', '3명은 불가');
select pg_temp.fails(format($$select create_match('%s', array['%s','%s','%s','%s']::uuid[])$$, :'S', :'r2', :'r2', :'r3', :'r4'), 'need_four_players', '같은 사람 중복 불가');
select pg_temp.fails(format($$select create_match('%s', array['%s','%s','%s','00000000-0000-0000-0000-000000000000']::uuid[])$$, :'S', :'r2', :'r3', :'r4'), 'invalid_players', '이 운동 참석자가 아니면 불가');

-- 코트 2면: 경기 1, 2는 바로 코트에 들어가고 3은 대기
select match_id as m1, status as m1_status, court_no as m1_court from create_match(:'S', array[:'r2', :'r3', :'r4', :'r5']::uuid[]) \gset
select match_id as m2, status as m2_status, court_no as m2_court from create_match(:'S', array[:'r6', :'r7', :'r8', :'r9']::uuid[]) \gset
select match_id as m3, status as m3_status, warnings as m3_warn from create_match(:'S', array[:'r2', :'r6', :'g1', :'r9']::uuid[]) \gset
select match_id as m4, status as m4_status from create_match(:'S', array[:'r3', :'r4', :'r7', :'r8']::uuid[]) \gset
select pg_temp.ok(:'m1_status' = 'playing' and :m1_court = 1, '빈 코트가 있으면 바로 1번 코트로');
select pg_temp.ok(:'m2_status' = 'playing' and :m2_court = 2, '두 번째 경기는 2번 코트로');
select pg_temp.ok(:'m3_status' = 'queued' and :'m4_status' = 'queued', '코트가 차면 대기');
select pg_temp.ok(cardinality(:'m3_warn'::uuid[]) = 3, '이미 경기 중인 3명은 경고로 반환 (막지는 않음)');
select pg_temp.ok((select queue_pos from matches where id = :'m3') = 1 and (select queue_pos from matches where id = :'m4') = 2, '대기 순서 1, 2');

-- ── 대기 순서 변경 ───────────────────────────────────────────
select move_match(:'m4', -1);
select pg_temp.ok((select queue_pos from matches where id = :'m4') < (select queue_pos from matches where id = :'m3'), 'm4를 위로 → m4가 대기 1번');
select move_match(:'m4', -1);
select pg_temp.ok((select queue_pos from matches where id = :'m4') = 1, '맨 위에서 위로는 변화 없음');
select pg_temp.fails(format($$select move_match('%s', 1)$$, :'m1'), 'not_queued', '진행 중 경기는 순서 변경 불가');

-- ── 종료 → 대기 1번 자동 진입 ────────────────────────────────
select finish_match(:'m2') as next1 \gset
select pg_temp.ok(:'next1' = :'m4', '2번 코트 종료 → 대기 1번(m4)이 진입');
select pg_temp.ok((select status = 'playing' and court_no = 2 and queue_pos is null and started_at is not null from matches where id = :'m4'), 'm4: 2번 코트 진행 중');
select pg_temp.ok((select id from matches where session_id = :'S' and status = 'queued' order by queue_pos limit 1) = :'m3', '남은 m3가 대기 1번');
select pg_temp.fails(format($$select finish_match('%s')$$, :'m2'), 'not_playing', '이미 끝난 경기 재종료 불가 (다른 폰에서 먼저 누른 경우)');

-- 진행 중 경기 취소 → 빈 코트 채움, 게임 수 미포함
select cancel_match(:'m1');
select pg_temp.ok((select status = 'playing' and court_no = 1 from matches where id = :'m3'), '1번 코트 경기 취소 → m3 진입');
select pg_temp.fails(format($$select cancel_match('%s')$$, :'m1'), 'match_closed', '취소된 경기 재취소 불가');

select coalesce(finish_match(:'m3')::text, 'none') as next2 \gset
select pg_temp.ok(:'next2' = 'none', '대기 경기가 없으면 코트는 빈 채로');

-- ── 게임 수 집계 ─────────────────────────────────────────────
-- 끝난 경기: m2(r6 r7 r8 r9), m3(r2 r6 g1 r9). 취소: m1. 진행 중: m4(r3 r4 r7 r8)
select pg_temp.ok((select games from session_player_stats where registration_id = :'r6') = 2, 'r6: 2게임');
select pg_temp.ok((select games from session_player_stats where registration_id = :'r2') = 1, 'r2: 1게임 (취소된 m1 제외)');
select pg_temp.ok((select games from session_player_stats where registration_id = :'r5') = 0, 'r5: 0게임 (m1 취소)');
select pg_temp.ok((select games = 1 from session_player_stats where registration_id = :'g1'), '게스트도 게임 수 집계');
select pg_temp.ok((select is_playing and games = 1 from session_player_stats where registration_id = :'r7'), 'r7: 1게임 + 지금 경기 중');
select pg_temp.ok((select last_finished_at is not null from session_player_stats where registration_id = :'r9'), '마지막 경기 종료 시각 기록');

-- 취소한 참석자는 통계에서 빠짐
select pg_temp.as_user('00000000-0000-0000-0000-000000000505');
select cancel_registration(:'r5');
select pg_temp.ok((select count(*) from session_player_stats where registration_id = :'r5') = 0, '참석 취소자는 대진 후보에서 제외');
select pg_temp.fails(format($$select add_guest('%s', 'x')$$, :'S'), 'forbidden', '참석 취소하면 대진판 조작 권한도 없음');

-- ── 이력 (운영진만 읽음) ─────────────────────────────────────
select pg_temp.as_user('00000000-0000-0000-0000-000000000501');
select pg_temp.ok((select count(*) from activity_log where session_id = :'S' and action like 'board.%') >= 10, '대진판 변경 이력 기록');
select pg_temp.fails(format($$select fill_courts('%s')$$, :'S'), 'permission denied', 'fill_courts는 RPC로 노출되지 않음');

-- ── 취소된 운동은 대진판 잠김 ────────────────────────────────
reset role;
update sessions set canceled_at = now() where id = :'S';
set role authenticated;
select pg_temp.fails(format($$select add_guest('%s', 'x')$$, :'S'), 'session_canceled', '취소된 운동은 대진판 조작 불가');

reset role;
select 'ALL M5 TESTS PASSED' as result;
