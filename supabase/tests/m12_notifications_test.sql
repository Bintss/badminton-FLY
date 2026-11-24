-- 알림: 가입 신청·승인, 운동 생김, 투표 10분 전, 코트 배정, 끄기, 읽음, 구독, 보내기용 함수 권한
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
  select ('c0000000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
-- 검사용: 다른 사람 알림도 세야 하므로 RLS를 우회 (함수 소유자 권한)
create or replace function pg_temp.n(p uuid, k text) returns bigint language sql security definer as $$
  select count(*) from public.notifications where user_id = p and kind = k;
$$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '회원' || n) from generate_series(1, 6) n;
\set A '''c0000000-0000-0000-0000-000000000001'''

-- ── 가입 신청 → 운영진, 승인 → 본인 ──────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('알림 테스트') as club \gset
select pg_temp.as_user(pg_temp.u(2));
select request_join(:'club');
select pg_temp.ok(pg_temp.n(pg_temp.u(1), 'join_request') = 1, '가입 신청 → 운영진에게 알림');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok((select body like '회원2님이 알림 테스트에 가입을 신청했어요' and url = '/c/' || :'club' || '/admin/members'
                     from notifications where user_id = pg_temp.u(1) and kind = 'join_request'), '알림 내용·이동 경로');
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok(pg_temp.n(pg_temp.u(2), 'join_request') = 0, '신청한 본인에게는 신청 알림 없음');
select request_join(:'club');
select pg_temp.ok(pg_temp.n(pg_temp.u(1), 'join_request') = 1, '같은 신청을 다시 눌러도 알림은 한 번');
select pg_temp.as_user(pg_temp.u(1));
select decide_member(:'club', pg_temp.u(2), true);
select pg_temp.ok(pg_temp.n(pg_temp.u(2), 'join_approved') = 1, '가입 승인 → 본인에게 알림');
-- 나머지 회원
do $$ declare i int; begin
  for i in 3..5 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join((select id from clubs where name = '알림 테스트')); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 3..5 loop perform decide_member((select id from clubs where name = '알림 테스트'), pg_temp.u(i), true); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(4));
select pg_temp.ok((select count(*) from notifications where kind = 'join_request') = 0, '다른 사람 알림은 안 보임 (RLS)');

-- ── 끄기 ─────────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.u(5));
select set_notification_pref('vote_created', false);
select pg_temp.fails($$select set_notification_pref('spam', false)$$, 'invalid_kind', '없는 종류 거부');

-- ── 운동 생김 → 회원 전체 (만든 사람·끈 사람 제외) ───────────
select pg_temp.as_user(pg_temp.u(2));
select create_flash(:'club', '금요 번개', '체육관', now() + interval '2 day', now() + interval '2 day 2 hour', 12, 2, null) as s1 \gset
select pg_temp.ok(pg_temp.n(pg_temp.u(1), 'vote_created') = 1 and pg_temp.n(pg_temp.u(3), 'vote_created') = 1, '번개 생김 → 회원에게 알림');
select pg_temp.ok(pg_temp.n(pg_temp.u(2), 'vote_created') = 0, '만든 사람에게는 알림 없음');
select pg_temp.ok(pg_temp.n(pg_temp.u(5), 'vote_created') = 0, '운동 알림을 끈 사람에게는 없음');
select pg_temp.as_user(pg_temp.u(3));
select pg_temp.ok((select title = '알림 테스트 새 번개' and body like '금요 번개, %. 지금 투표 중이에요'
                     from notifications where user_id = pg_temp.u(3) and kind = 'vote_created'), '바로 열린 번개는 "지금 투표 중"');
select pg_temp.as_user(pg_temp.u(5));
select set_notification_pref('vote_created', true);
-- 정기운동은 홈을 연 사람이 자동 생성을 일으켜도 모두에게 (host 없음)
select pg_temp.as_user(pg_temp.u(1));
select save_template(:'club', null, '수요 정기운동', 3::smallint, '19:00', '22:00', '체육관', 30, 4, 3, '21:00', true) as tpl \gset
select pg_temp.ok((select count(*) from sessions where template_id = :'tpl') > 0, '(정기운동 생성됨)');
select pg_temp.ok(pg_temp.n(pg_temp.u(5), 'vote_created') >= 1 and pg_temp.n(pg_temp.u(1), 'vote_created') >= 2, '자동 생성 정기운동은 만든 계기가 된 사람도 포함해 모두에게');

-- ── 투표 10분 전 ──────────────────────────────────────────────
reset role;
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at) values
  ('c0000000-0000-0000-0000-0000000000a1', :'club', 'flash', '곧 열리는 운동', now() + interval '1 day', now() + interval '1 day 2 hour', 10, 1, now() + interval '9 minutes'),
  ('c0000000-0000-0000-0000-0000000000a2', :'club', 'flash', '나중에 열리는 운동', now() + interval '2 day', now() + interval '2 day 2 hour', 10, 1, now() + interval '30 minutes');
select pg_temp.ok((select body like '곧 열리는 운동, %. 투표는 %에 열려요' from notifications where user_id = pg_temp.u(1) and session_id = 'c0000000-0000-0000-0000-0000000000a1'),
  '나중에 열리는 운동은 "투표는 …에 열려요"');
select enqueue_vote_soon();
select pg_temp.ok((select vote_soon_notified_at is not null from sessions where id = 'c0000000-0000-0000-0000-0000000000a1')
  and (select vote_soon_notified_at is null from sessions where id = 'c0000000-0000-0000-0000-0000000000a2'), '10분 안에 열리는 운동만 처리');
select enqueue_vote_soon();
select pg_temp.ok((select count(*) from notifications where kind = 'vote_soon' and session_id = 'c0000000-0000-0000-0000-0000000000a1') = 5, '같은 운동은 한 번만');
select pg_temp.ok((select count(distinct user_id) from notifications where kind = 'vote_soon' and session_id = 'c0000000-0000-0000-0000-0000000000a1') = 5, '회원 5명 모두에게 10분 전 알림');
select pg_temp.ok((select title from notifications where kind = 'vote_soon' and session_id = 'c0000000-0000-0000-0000-0000000000a1' limit 1) in ('9분 뒤 투표 오픈', '10분 뒤 투표 오픈'), '남은 분 표시');
select notifications_tick();   -- pg_net 없는 환경에서도 오류 없이

-- ── 코트 배정 → 그 경기의 회원 선수 ──────────────────────────
set role authenticated;
do $$ declare i int; begin
  for i in 1..4 loop perform pg_temp.as_user(pg_temp.u(i)); perform register((select id from sessions where title = '금요 번개')); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select add_guest(:'s1', '게스트 철수') as g \gset
select array_agg(id order by seq)::text as regs from registrations where session_id = :'s1' and kind = 'member' and status = 'confirmed' \gset
select create_match(:'s1', array[(:'regs'::uuid[])[1], (:'regs'::uuid[])[2], (:'regs'::uuid[])[3], :'g'::uuid]);
reset role;
select pg_temp.ok((select count(*) from notifications where kind = 'court_assigned' and session_id = :'s1') = 3, '코트 배정 → 회원 선수 3명에게 (게스트 제외)');
select pg_temp.ok((select title = '코트 1에서 경기 시작' and body like '파트너 %, 상대 %게스트 철수%' from notifications where kind = 'court_assigned' and user_id = pg_temp.u(1)),
  '자율 경기: 고른 순서대로 파트너·상대 이름');
select pg_temp.ok((select url = '/c/' || :'club' || '/s/' || :'s1' || '/board' from notifications where kind = 'court_assigned' and user_id = pg_temp.u(1)), '대진판으로 이동');
-- 이미 진행 중인 경기가 다시 갱신돼도 중복 알림 없음
update matches set status = status where session_id = :'s1';
select pg_temp.ok((select count(*) from notifications where kind = 'court_assigned' and session_id = :'s1') = 3, '진행 중 경기 갱신으로는 다시 알리지 않음');

-- 대회 경기: 파트너·상대
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at, kind, tournament_state, round_count) values
  ('c0000000-0000-0000-0000-0000000000b1', :'club', 'flash', '알림 대회', now() + interval '1 hour', now() + interval '4 hour', 10, 1, now() - interval '1 day', 'tournament', 'draft', 1);
set role authenticated;
do $$ declare i int; begin
  for i in 1..4 loop perform pg_temp.as_user(pg_temp.u(i)); perform register('c0000000-0000-0000-0000-0000000000b1'); end loop;
end $$;
select pg_temp.as_user(pg_temp.u(1));
select array_agg(id order by seq)::text as tr from registrations where session_id = 'c0000000-0000-0000-0000-0000000000b1' \gset
select save_schedule('c0000000-0000-0000-0000-0000000000b1', format('[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  (:'tr'::uuid[])[1], (:'tr'::uuid[])[2], (:'tr'::uuid[])[3], (:'tr'::uuid[])[4])::jsonb);
select publish_schedule('c0000000-0000-0000-0000-0000000000b1');
select set_checked_in(r, true) from unnest(:'tr'::uuid[]) r;
reset role;
select pg_temp.ok((select title = '코트 1에서 경기 시작 (매치 1)' and body = '파트너 회원2, 상대 회원3, 회원4'
                     from notifications where kind = 'court_assigned' and user_id = pg_temp.u(1) and session_id = 'c0000000-0000-0000-0000-0000000000b1'),
  '대회 경기: 매치 번호, 파트너·상대');

-- ── 읽음 ──────────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u(3));
select mark_notifications_read(array[(select min(id) from notifications where user_id = pg_temp.u(3))]);
select pg_temp.ok((select count(*) from notifications where read_at is not null) = 1, '하나만 읽음');
select mark_notifications_read(null);
select pg_temp.ok((select count(*) from notifications where read_at is null) = 0, '모두 읽음');

-- ── 푸시 구독 ─────────────────────────────────────────────────
select pg_temp.fails($$select save_push_subscription('http://x', 'k', 'a', 'ua')$$, 'invalid_subscription', 'https 아닌 주소 거부');
select save_push_subscription('https://push.example/abc', 'key', 'auth', 'test');
select pg_temp.ok((select count(*) from push_subscriptions) = 1, '구독 저장 (본인 것만 보임)');
select pg_temp.as_user(pg_temp.u(4));
select save_push_subscription('https://push.example/abc', 'key2', 'auth2', 'test');
select pg_temp.ok((select count(*) from push_subscriptions) = 1, '같은 기기를 다른 계정으로 쓰면 그 계정으로 옮김');
select pg_temp.as_user(pg_temp.u(3));
select pg_temp.ok((select count(*) from push_subscriptions) = 0, '이전 계정에서는 사라짐');
select pg_temp.ok(push_public_key() is null, '공개 키 설정 전에는 null (화면: 알림 서버 준비 전)');

-- ── 보내기용 함수는 서비스 키만 ───────────────────────────────
select pg_temp.fails($$select * from claim_push_batch(10)$$, 'permission denied', '일반 사용자는 보낼 알림을 가져갈 수 없음');
select pg_temp.fails($$select finish_push(array[1::bigint], null)$$, 'permission denied', '일반 사용자는 보냄 처리 불가');
reset role;
select pg_temp.ok((select count(*) from claim_push_batch(100000)) = (select count(*) from notifications where pushed_at is null), '보낼 알림 가져가기');
select pg_temp.ok((select count(*) from claim_push_batch(100000)) = 0, '가져간 건 2분 동안 다시 안 가져감 (중복 발송 방지)');
select finish_push(array(select id from notifications), null);
select pg_temp.ok((select count(*) from notifications where pushed_at is null) = 0, '보냄 처리');

-- ── 알림이 실패해도 원래 작업은 진행 ──────────────────────────
alter table notifications add constraint _break check (false) not valid;
set role authenticated;
select pg_temp.as_user(pg_temp.u(6));
select pg_temp.ok(request_join(:'club') = 'pending', '알림 저장이 실패해도 가입 신청은 성공');
reset role;
alter table notifications drop constraint _break;
