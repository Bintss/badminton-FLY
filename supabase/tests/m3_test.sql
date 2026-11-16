-- M3 검증: 템플릿 → 세션 생성, 번개, 세션 수정/취소, 일정 목록 뷰
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

\set A '00000000-0000-0000-0000-0000000003a1'
\set B '00000000-0000-0000-0000-0000000003b1'
\set C '00000000-0000-0000-0000-0000000003c1'
\set E '00000000-0000-0000-0000-0000000003e1'
insert into auth.users (id, raw_user_meta_data) values
  (:'A', '{"name":"운영진"}'), (:'B', '{"name":"비"}'), (:'C', '{"name":"씨"}'), (:'E', '{"name":"외부인"}');

set role authenticated;
select pg_temp.as_user(:'A');
select create_club('M3 테스트') as club \gset
select pg_temp.as_user(:'B'); select request_join(:'club');
select pg_temp.as_user(:'C'); select request_join(:'club');
select pg_temp.as_user(:'A'); select decide_member(:'club', :'B', true), decide_member(:'club', :'C', true);

-- 서울 기준 "모레"의 요일로 템플릿: 19:00~22:00, 3일 전 21:00 오픈
select extract(dow from ((now() at time zone 'Asia/Seoul')::date + 2))::smallint as wd \gset

-- ── 템플릿 권한 ──────────────────────────────────────────────
select pg_temp.as_user(:'B');
select pg_temp.fails(format($$select save_template('%s', null, '정기', %s::smallint, '19:00', '22:00', '체육관', 30, 5, 3, '21:00')$$, :'club', :wd),
                     'forbidden', '일반 회원은 템플릿 저장 불가');
select pg_temp.as_user(:'A');
select pg_temp.fails(format($$select save_template('%s', null, '정기', %s::smallint, '22:00', '19:00', '체육관', 30, 5, 3, '21:00')$$, :'club', :wd),
                     'invalid_time', '종료가 시작보다 빠르면 거부');

-- ── 저장 즉시 생성 ──────────────────────────────────────────
select save_template(:'club', null, '수요 정기', :wd::smallint, '19:00', '22:00', '체육관', 30, 5, 3, '21:00') as tpl \gset
-- 모레(오픈은 이미 지남)와 9일 뒤(오픈 6일 뒤 ≤ 7일) → 2개. 16일 뒤는 범위 밖
select pg_temp.ok((select count(*) from sessions where template_id = :'tpl') = 2, '저장 즉시 세션 2개 생성 (오픈 7일 이내 회차만)');
select pg_temp.ok((select bool_and(type = 'regular' and capacity = 30 and court_count = 5 and title = '수요 정기') from sessions where template_id = :'tpl'), '템플릿 값 복사');
select pg_temp.ok((select min(starts_at) from sessions where template_id = :'tpl')
                  = (((now() at time zone 'Asia/Seoul')::date + 2) + time '19:00') at time zone 'Asia/Seoul', '시작 시각 = 모레 19:00 (서울)');
select pg_temp.ok((select min(opens_at) from sessions where template_id = :'tpl')
                  = (((now() at time zone 'Asia/Seoul')::date - 1) + time '21:00') at time zone 'Asia/Seoul', '오픈 시각 = 3일 전 21:00 (어제 21:00)');
select pg_temp.ok((select bool_and(template_slot = starts_at) from sessions where template_id = :'tpl'), 'template_slot = 원래 시작 시각');

-- ── 멱등성 ───────────────────────────────────────────────────
select pg_temp.as_user(:'B');
select pg_temp.ok(ensure_upcoming_sessions(:'club') = 0, '다시 호출해도 새로 만들지 않음 (회원 호출 가능)');
select pg_temp.as_user(:'E');
select pg_temp.fails(format($$select ensure_upcoming_sessions('%s')$$, :'club'), 'forbidden', '비회원은 생성 호출 불가');
select pg_temp.fails('select generate_all_sessions()', 'permission denied', 'generate_all_sessions는 RPC로 노출되지 않음');

-- ── 운영진이 날짜를 옮기거나 취소해도 같은 회차를 다시 만들지 않음 ──
select pg_temp.as_user(:'A');
select id as s1, starts_at as s1_start, opens_at as s1_open from sessions where template_id = :'tpl' order by starts_at limit 1 \gset
select id as s2, opens_at as s2_open from sessions where template_id = :'tpl' order by starts_at desc limit 1 \gset
select update_session(:'s1', '수요 정기(장소 변경)', '다른 체육관', :'s1_start'::timestamptz + interval '1 day',
                      :'s1_start'::timestamptz + interval '1 day 3 hour', 6, :'s1_open'::timestamptz);
select cancel_session(:'s2');
select pg_temp.ok(ensure_upcoming_sessions(:'club') = 0, '옮긴 회차·취소한 회차는 재생성되지 않음');
select pg_temp.ok((select count(*) from sessions where template_id = :'tpl') = 2, '세션은 여전히 2개');

-- ── 오픈 시각 수정 규칙 ──────────────────────────────────────
select pg_temp.fails(format($$select update_session('%s', 't', 'p', '%s'::timestamptz + interval '1 day', '%s'::timestamptz + interval '1 day 3 hour', 5, now())$$, :'s1', :'s1_start', :'s1_start'),
                     'already_open', '이미 열린 투표의 오픈 시각은 변경 불가');
select pg_temp.fails(format($$select update_session('%s', 't', 'p', now() + interval '3 day', now() + interval '3 day 3 hour', 5, now())$$, :'s2'),
                     'session_canceled', '취소된 세션은 수정 불가');

-- ── 템플릿 수정은 이후 생성분부터 ────────────────────────────
select save_template(:'club', :'tpl', '수요 정기', :wd::smallint, '19:00', '22:00', '체육관', 40, 5, 3, '21:00');
select pg_temp.ok((select bool_and(capacity = 30) from sessions where template_id = :'tpl'), '템플릿 정원 변경은 기존 세션에 영향 없음');

-- 비활성 템플릿은 생성 안 함
select save_template(:'club', null, '쉬는 날', :wd::smallint, '07:00', '09:00', '', 10, 2, 1, '07:00', false) as tpl_off \gset
select pg_temp.ok((select count(*) from sessions where template_id = :'tpl_off') = 0, '비활성 템플릿은 세션 생성 안 함');

-- ── 번개 ─────────────────────────────────────────────────────
select pg_temp.as_user(:'B');
select create_flash(:'club', '토요 번개', '학교 체육관', now() + interval '2 day', now() + interval '2 day 2 hour', 12, 2) as flash \gset
select pg_temp.ok((select type = 'flash' and host_user_id = :'B' and opens_at <= now() from sessions where id = :'flash'), '회원 누구나 번개 개설 (기본: 즉시 오픈)');
select create_flash(:'club', '예약 번개', '', now() + interval '3 day', now() + interval '3 day 2 hour', 8, 2, now() + interval '1 day') as flash2 \gset
select pg_temp.ok((select opens_at > now() from sessions where id = :'flash2'), '번개 오픈 시각 예약');
select pg_temp.fails(format($$select create_flash('%s', 'x', '', now() - interval '1 hour', now() + interval '1 hour', 8, 2)$$, :'club'), 'invalid_time', '지난 시각 번개 불가');
select pg_temp.fails(format($$select create_flash('%s', 'x', '', now() + interval '1 day', now() + interval '1 day 1 hour', 0, 2)$$, :'club'), 'invalid_capacity', '정원 0 번개 불가');
select pg_temp.as_user(:'E');
select pg_temp.fails(format($$select create_flash('%s', 'x', '', now() + interval '1 day', now() + interval '1 day 1 hour', 8, 2)$$, :'club'), 'forbidden', '비회원 번개 불가');

-- 번개 관리 권한
select pg_temp.as_user(:'C');
select pg_temp.fails(format($$select cancel_session('%s')$$, :'flash'), 'forbidden', '남의 번개는 취소 불가');
select pg_temp.fails(format($$select update_session('%s', 'x', '', now() + interval '2 day', now() + interval '2 day 2 hour', 2, now())$$, :'flash'), 'forbidden', '남의 번개는 수정 불가');
select pg_temp.as_user(:'B');
select update_session(:'flash2', '예약 번개(변경)', '체육관', now() + interval '3 day', now() + interval '3 day 2 hour', 3, now() + interval '2 day');
select pg_temp.ok((select title = '예약 번개(변경)' and court_count = 3 from sessions where id = :'flash2'), '개설자는 오픈 전 번개 수정 가능 (오픈 시각 포함)');
select pg_temp.fails(format($$select update_session('%s', 'x', '', now() + interval '3 day', now() + interval '3 day 2 hour', 3, now() + interval '4 day')$$, :'flash2'),
                     'invalid_time', '오픈 시각이 시작보다 늦으면 거부');
select pg_temp.as_user(:'A');
select cancel_session(:'flash2');
select pg_temp.ok((select canceled_at is not null from sessions where id = :'flash2'), '운영진은 번개 취소 가능');
select cancel_session(:'flash2');
select pg_temp.ok(true, '이미 취소된 세션 재취소는 무시');

-- ── 일정 목록 뷰 ─────────────────────────────────────────────
select pg_temp.as_user(:'B'); select register(:'flash');
select pg_temp.as_user(:'C'); select register(:'flash');
select pg_temp.ok((select confirmed_count = 2 and waitlist_count = 0 and my_status = 'confirmed' from session_overview where id = :'flash'), '뷰: 확정 2, 내 상태 confirmed');
select pg_temp.as_user(:'A');
select pg_temp.ok((select my_status is null from session_overview where id = :'flash'), '뷰: 신청 안 한 사람은 my_status null');
select pg_temp.ok((select count(*) from session_overview where club_id = :'club') = 4, '뷰: 동아리 세션 4개 (정기 2 + 번개 2, 취소 포함)');
select pg_temp.as_user(:'E');
select pg_temp.ok((select count(*) from session_overview) = 0, '뷰: 비회원은 아무것도 안 보임 (RLS 적용)');
select pg_temp.fails('delete from session_overview', 'session_overview', '뷰로 쓰기 불가');

reset role;
select 'ALL M3 TESTS PASSED' as result;
