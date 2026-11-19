-- 투표 때 게스트 추가 + 게스트를 정원에 넣을지 설정
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
  select ('e1400000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
-- 검사용: RLS 우회
create or replace function pg_temp.st(p uuid) returns text language sql security definer as $$
  select status::text from public.registrations where id = p;
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '회원' || n) from generate_series(1, 6) n;

set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('게스트 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '게스트 테스트'); begin
  for i in 2..6 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..6 loop perform decide_member(c, pg_temp.u(i), true); end loop;
end $$;
reset role;

\set OFF '''e1400000-0000-0000-0000-0000000000a1'''
\set ON  '''e1400000-0000-0000-0000-0000000000a2'''
\set LATER '''e1400000-0000-0000-0000-0000000000a3'''
\set TOUR '''e1400000-0000-0000-0000-0000000000a4'''
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, guests_in_capacity) values
  (:OFF,   :'club', 'regular', '정원 밖', now() + interval '1 day', now() + interval '1 day 3 hour', 2, 2, now() - interval '1 hour', false),
  (:ON,    :'club', 'regular', '정원 안', now() + interval '1 day', now() + interval '1 day 3 hour', 3, 2, now() - interval '1 hour', true),
  (:LATER, :'club', 'regular', '오픈 전', now() + interval '3 day', now() + interval '3 day 3 hour', 4, 2, now() + interval '1 day', false);
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  (:TOUR, :'club', 'flash', '대회', now() + interval '1 day', now() + interval '1 day 3 hour', 8, 2, now() - interval '1 hour', 'tournament', 'published', 2);

-- ── 정원에 안 넣는 운동 ──────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u(2)); select register(:OFF);
select pg_temp.as_user(pg_temp.u(3)); select register(:OFF);
select pg_temp.as_user(pg_temp.u(2));
select registration_id as g_off, status as g_off_status from add_vote_guest(:OFF, '  친구A ', 'M', 'B조') \gset
select pg_temp.ok(:'g_off_status' = 'confirmed', '정원이 찼어도 게스트는 확정 (정원 밖)');
select pg_temp.ok((select guest_name = '친구A' and guest_gender = 'M' and guest_level = 'B조' and added_by = pg_temp.u(2) and checked_in_at is null
                     from registrations where id = :'g_off'), '이름 다듬기, 성별·급수, 데려온 사람 기록, 아직 도착 전');
select pg_temp.ok((select confirmed_count = 2 and guest_count = 1 and not guests_in_capacity from session_overview where id = :OFF),
  '확정 인원은 회원만, 게스트 수는 따로');
select pg_temp.as_user(pg_temp.u(4));
select pg_temp.ok((select status from register(:OFF)) = 'waitlisted', '회원은 그대로 정원에 따라 대기');
select pg_temp.as_user(pg_temp.u(2));
select add_vote_guest(:OFF, '친구B', null);
select add_vote_guest(:OFF, '친구C', 'F');
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a1', '친구D', null)$$, 'guest_limit', '회원 한 명당 게스트 3명까지');
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a1', '   ', null)$$, 'invalid_name', '빈 이름 거부');
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a1', '친구', 'X')$$, 'invalid_gender', '성별 값 확인');
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a1', '친구', null, 'E조')$$, 'invalid_level', '급수는 목록에 있는 것만');

-- 취소 권한: 데려온 사람·운영진·참석 확정자(대진판)만
select pg_temp.as_user(pg_temp.u(5));
select pg_temp.fails(format('select cancel_registration(%L)', :'g_off'), 'forbidden', '상관없는 회원은 남의 게스트 취소 불가');
select pg_temp.as_user(pg_temp.u(2));
select cancel_registration(:'g_off');
select pg_temp.ok(pg_temp.st(:'g_off') = 'canceled', '데려온 사람이 취소');
select pg_temp.ok((select status from registrations where session_id = :OFF and user_id = pg_temp.u(4)) = 'waitlisted',
  '정원 밖 게스트가 빠져도 대기 회원은 그대로');

-- 오픈 전: 회원은 안 되고 운영진은 됨
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a3', '친구', null)$$, 'not_open', '오픈 전에는 회원이 게스트 추가 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok((select status from add_vote_guest(:LATER, '운영진 손님', null)) = 'confirmed', '운영진은 오픈 전에도 추가');
select pg_temp.fails($$select add_vote_guest('e1400000-0000-0000-0000-0000000000a4', '친구', null)$$, 'tournament_locked', '대진이 공개된 대회에는 추가 불가');

-- ── 정원에 넣는 운동 (정원 3) ────────────────────────────────
select pg_temp.as_user(pg_temp.u(2)); select register(:ON);
select registration_id as g1, status as g1s, queue_position as g1p from add_vote_guest(:ON, '손님1', 'F') \gset
select pg_temp.ok(:'g1s' = 'confirmed' and :'g1p' = '2', '게스트도 선착순: 2번째 확정');
select pg_temp.as_user(pg_temp.u(3)); select register(:ON);
select pg_temp.as_user(pg_temp.u(2));
select registration_id as g2, status as g2s, queue_position as g2p from add_vote_guest(:ON, '손님2', 'M') \gset
select pg_temp.ok(:'g2s' = 'waitlisted' and :'g2p' = '1', '정원이 차면 게스트도 대기 1번');
select pg_temp.as_user(pg_temp.u(4));
select pg_temp.ok((select status::text || queue_position from register(:ON)) = 'waitlisted2', '뒤에 온 회원은 대기 2번 (게스트와 같은 줄)');
select pg_temp.ok((select confirmed_count = 3 and waitlist_count = 2 and guest_count = 2 and guests_in_capacity from session_overview where id = :ON),
  '일정 목록: 확정·대기에 게스트 포함');

select pg_temp.as_user(pg_temp.u(3));
select cancel_registration((select id from registrations where session_id = :ON and user_id = pg_temp.u(3)));
select pg_temp.ok(pg_temp.st(:'g2') = 'confirmed', '회원이 취소하면 먼저 기다린 게스트가 승격');
select pg_temp.as_user(pg_temp.u(2));
select cancel_registration(:'g1');
select pg_temp.ok((select status from registrations where session_id = :ON and user_id = pg_temp.u(4)) = 'confirmed', '게스트가 취소하면 대기 회원 승격');

-- 정원 변경도 게스트를 센다
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails($$select update_capacity('e1400000-0000-0000-0000-0000000000a2', 2)$$, 'capacity_below_confirmed', '확정 인원(게스트 포함)보다 적게 못 줄임');

-- 설정 바꾸기
select pg_temp.as_user(pg_temp.u(5)); select register(:ON);
select pg_temp.as_user(pg_temp.u(2));
select registration_id as g3 from add_vote_guest(:ON, '손님3', null) \gset
select pg_temp.ok(pg_temp.st(:'g3') = 'waitlisted', '정원이 차서 손님3 대기');
select pg_temp.fails($$select set_guests_in_capacity('e1400000-0000-0000-0000-0000000000a2', false)$$, 'forbidden', '일반 회원은 설정 못 바꿈');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok(set_guests_in_capacity(:ON, false) = 2, '정원 밖으로 바꾸면: 대기 게스트 확정 + 빈자리만큼 회원 승격');
select pg_temp.ok(pg_temp.st(:'g3') = 'confirmed'
              and (select status from registrations where session_id = :ON and user_id = pg_temp.u(5)) = 'confirmed',
  '손님3, 회원5 모두 확정');
select pg_temp.ok((select confirmed_count from session_overview where id = :ON) = 3, '확정 인원은 다시 회원만');
select pg_temp.ok(set_guests_in_capacity(:ON, true) = 0, '정원 안으로 바꿔도 이미 확정된 사람은 그대로');
select pg_temp.ok((select confirmed_count from session_overview where id = :ON) = 5, '정원을 넘은 채로 유지 (내보내지 않음)');

-- ── 만들 때 설정 ────────────────────────────────────────────
select create_flash(:'club', '게스트 번개', '', now() + interval '2 day', now() + interval '2 day 2 hour', 8, 2, null, true) as fl \gset
select pg_temp.ok((select guests_in_capacity from sessions where id = :'fl'), '번개 만들 때 게스트 정원 포함');
select save_template(:'club', null, '정기', ((extract(dow from now())::int + 2) % 7)::smallint, '19:00', '22:00', '', 20, 4, 1, '09:00', true, true) as tpl \gset
select pg_temp.ok((select guests_in_capacity from session_templates where id = :'tpl'), '정기운동 설정에 저장');
select pg_temp.ok(exists (select 1 from sessions where template_id = :'tpl') and not exists (select 1 from sessions where template_id = :'tpl' and not guests_in_capacity),
  '정기운동으로 만들어진 운동에 설정이 따라감');
select create_tournament(:'club', '대회2', '', now() + interval '2 day', now() + interval '2 day 3 hour', 16, 4, null, 3, 25, 30, 15, true) as t2 \gset
select pg_temp.ok((select guests_in_capacity from sessions where id = :'t2'), '자체대회 만들 때도');
select create_flash(:'club', '기본', '', now() + interval '2 day', now() + interval '2 day 2 hour', 8, 2) as fl2 \gset
select pg_temp.ok((select not guests_in_capacity from sessions where id = :'fl2'), '기본값은 정원 밖 (예전과 같음)');
reset role;
