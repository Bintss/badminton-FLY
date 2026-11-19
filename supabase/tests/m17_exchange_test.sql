-- 교류전: 초대·수락, 편별 정원·대기, 상대 회원 보기 권한, 편 규칙(대진·교체), 상대 운영진 권한, 알림 경로
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
-- h1..h5 = 주최 동아리(1 운영진), p1..p5 = 상대 동아리(1 운영진), x1 = 다른 동아리
create or replace function pg_temp.h(n int) returns uuid language sql immutable as $$ select ('e1700000-0000-0000-0000-00000000010' || n)::uuid $$;
create or replace function pg_temp.p(n int) returns uuid language sql immutable as $$ select ('e1700000-0000-0000-0000-00000000020' || n)::uuid $$;
create or replace function pg_temp.st(r uuid) returns text language sql security definer as $$ select status::text from public.registrations where id = r $$;
create or replace function pg_temp.reg(s uuid, u uuid) returns uuid language sql security definer as $$
  select id from public.registrations where session_id = s and user_id = u and status <> 'canceled' $$;
create or replace function pg_temp.notes(u uuid, k text) returns setof public.notifications language sql security definer as $$
  select * from public.notifications where user_id = u and kind = k order by id $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data)
select pg_temp.h(n), jsonb_build_object('name', '주최' || n) from generate_series(1, 5) n
union all select pg_temp.p(n), jsonb_build_object('name', '상대' || n) from generate_series(1, 5) n
union all select 'e1700000-0000-0000-0000-000000000301', '{"name":"딴동아리"}';

set role authenticated;
select pg_temp.as_user(pg_temp.h(1)); select create_club('주최 클럽') as hc \gset
select pg_temp.as_user(pg_temp.p(1)); select create_club('상대 클럽') as pc \gset
select pg_temp.as_user('e1700000-0000-0000-0000-000000000301'); select create_club('딴 클럽') as xc \gset
do $$ declare i int;
  h uuid := (select id from clubs where name = '주최 클럽'); p uuid := (select id from clubs where name = '상대 클럽');
begin
  for i in 2..5 loop
    perform pg_temp.as_user(pg_temp.h(i)); perform request_join(h);
    perform pg_temp.as_user(pg_temp.p(i)); perform request_join(p);
  end loop;
  perform pg_temp.as_user(pg_temp.h(1)); for i in 2..5 loop perform decide_member(h, pg_temp.h(i), true); end loop;
  perform pg_temp.as_user(pg_temp.p(1)); for i in 2..5 loop perform decide_member(p, pg_temp.p(i), true); end loop;
  -- 급수
  perform pg_temp.as_user(pg_temp.h(2)); perform set_my_level(h, 'A조');
  perform pg_temp.as_user(pg_temp.p(2)); perform set_my_level(p, 'D조');
end $$;

-- ── 만들기 ─────────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.h(2));
select pg_temp.fails(format($$select create_exchange(%L, %L, '교류', '', now() + interval '1 day', now() + interval '1 day 3 hour', 2, 2, 2, null, 2, 25, 30, 15)$$, :'hc', :'pc'),
  'forbidden', '일반 회원은 교류전을 못 만듦');
select pg_temp.as_user(pg_temp.h(1));
select pg_temp.fails(format($$select create_exchange(%L, %L, '교류', '', now() + interval '1 day', now() + interval '1 day 3 hour', 2, 2, 2, null, 2, 25, 30, 15)$$, :'hc', :'hc'),
  'invalid_partner', '자기 동아리와는 교류전 불가');
select create_exchange(:'hc', :'pc', '주최 vs 상대', '체육관', now() + interval '1 day', now() + interval '1 day 3 hour', 2, 2, 2, null, 2, 25, 30, 15) as ex \gset
select pg_temp.ok((select kind = 'exchange' and tournament_state = 'draft' and partner_status = 'invited' and partner_capacity = 2 from sessions where id = :'ex'),
  '교류전 생성: 대진 준비 중, 상대는 초대 상태');

-- 수락 전: 상대 운영진만 보고, 상대 회원은 못 봄
select pg_temp.as_user(pg_temp.p(2));
select pg_temp.ok(not exists (select 1 from sessions where id = :'ex'), '수락 전에는 상대 회원에게 안 보임');
select pg_temp.fails(format('select register(%L)', :'ex'), 'forbidden', '수락 전에는 상대 회원이 신청 못 함');
select pg_temp.as_user(pg_temp.p(1));
select pg_temp.ok(exists (select 1 from sessions where id = :'ex'), '상대 운영진은 초대를 봄');
select pg_temp.ok((select url = '/c/' || :'pc' from pg_temp.notes(pg_temp.p(1), 'exchange_invite')), '상대 운영진에게 초대 알림 (자기 동아리 홈으로)');
select pg_temp.as_user('e1700000-0000-0000-0000-000000000301');
select pg_temp.ok(not exists (select 1 from sessions where id = :'ex'), '상관없는 동아리는 못 봄');

-- 응답
select pg_temp.as_user(pg_temp.h(1));
select pg_temp.fails(format('select respond_exchange(%L, true)', :'ex'), 'forbidden', '주최가 대신 수락 불가');
select pg_temp.as_user(pg_temp.p(2));
select pg_temp.fails(format('select respond_exchange(%L, true)', :'ex'), 'forbidden', '상대 일반 회원은 수락 불가');
select pg_temp.as_user(pg_temp.p(1));
select respond_exchange(:'ex', true);
select pg_temp.fails(format('select respond_exchange(%L, false)', :'ex'), 'not_invited', '이미 응답한 초대');
select pg_temp.ok((select url = '/c/' || :'pc' || '/s/' || :'ex' from pg_temp.notes(pg_temp.p(2), 'vote_created') where session_id = :'ex'),
  '수락 → 상대 회원에게 새 교류전 알림 (자기 동아리 경로)');
select pg_temp.ok((select title = '교류전 수락' from pg_temp.notes(pg_temp.h(1), 'exchange_reply')), '주최 운영진에게 수락 알림');

-- ── 편별 정원 (주최 2, 상대 2) ─────────────────────────────────
do $$ declare i int; e uuid := (select id from sessions where title = '주최 vs 상대'); begin
  for i in 2..4 loop
    perform pg_temp.as_user(pg_temp.h(i)); perform register(e);
    perform pg_temp.as_user(pg_temp.p(i)); perform register(e);
  end loop;
end $$;
select pg_temp.as_user(pg_temp.p(4));
select pg_temp.ok((select status::text || queue_position from register(:'ex')) = 'waitlisted1', '상대 편 대기 1번 (주최 편 대기와 따로)');
select pg_temp.ok(pg_temp.st(pg_temp.reg(:'ex', pg_temp.h(4))) = 'waitlisted', '주최 편도 정원 2에서 대기');
select pg_temp.ok((select side_club_id = :'pc' from registrations where id = pg_temp.reg(:'ex', pg_temp.p(2))), '상대 회원 신청은 상대 편');
select pg_temp.ok((select confirmed_count = 2 and partner_confirmed_count = 2 and waitlist_count = 1 and partner_waitlist_count = 1
                     from session_overview where id = :'ex'), '목록 뷰: 편별 확정·대기');
select pg_temp.ok((select count(*) from registrations r join profiles pr on pr.id = r.user_id where r.session_id = :'ex') = 6,
  '상대 회원도 함께 신청한 주최 회원 이름을 봄');
select pg_temp.fails(format('select cancel_registration(%L)', pg_temp.reg(:'ex', pg_temp.p(3))), 'forbidden', '남의 신청은 취소 불가');
select pg_temp.as_user(pg_temp.p(3));
select cancel_registration(pg_temp.reg(:'ex', pg_temp.p(3)));
select pg_temp.ok(pg_temp.st(pg_temp.reg(:'ex', pg_temp.p(4))) = 'confirmed' and pg_temp.st(pg_temp.reg(:'ex', pg_temp.h(4))) = 'waitlisted',
  '상대 편이 빠지면 상대 편 대기만 승격');

-- 상대 정원: 상대 운영진·주최 운영진만
select pg_temp.as_user(pg_temp.h(2));
select pg_temp.fails(format('select update_partner_capacity(%L, 3)', :'ex'), 'forbidden', '일반 회원은 상대 정원 변경 불가');
select pg_temp.as_user(pg_temp.p(1));
select update_partner_capacity(:'ex', 3);
select pg_temp.fails(format('select update_capacity(%L, 5)', :'ex'), 'forbidden', '상대 운영진은 주최 정원 변경 불가');

-- ── 명단: 상대 운영진은 상대 편만 ─────────────────────────────
select pg_temp.fails(format('select roster_add_member(%L, %L)', :'ex', pg_temp.h(5)), 'forbidden', '상대 운영진은 주최 회원을 못 넣음');
select roster_add_member(:'ex', pg_temp.p(5)) as rp5 \gset
select pg_temp.ok((select side_club_id = :'pc' and status = 'confirmed' from registrations where id = :'rp5'), '상대 운영진이 자기 회원 추가');
select roster_add_guest(:'ex', '상대 손님', 'M', 'C조') as gp \gset
select pg_temp.ok((select side_club_id = :'pc' from registrations where id = :'gp'), '상대 운영진의 게스트는 상대 편');
select pg_temp.fails(format('select roster_remove(%L)', pg_temp.reg(:'ex', pg_temp.h(2))), 'forbidden', '상대 운영진은 주최 회원을 못 뺌');
select pg_temp.as_user(pg_temp.h(1));
select roster_add_member(:'ex', pg_temp.h(4));
select pg_temp.ok((select capacity = 3 from sessions where id = :'ex'), '주최 운영진이 대기자 확정 → 주최 정원 증가');

-- ── 대진: 주최 2명 vs 상대 2명 ────────────────────────────────
select pg_temp.as_user(pg_temp.p(1));
select pg_temp.fails(format($$select save_schedule(%L, '[]')$$, :'ex'), 'forbidden', '상대 운영진은 대진을 못 짬');
select pg_temp.as_user(pg_temp.h(1));
select pg_temp.fails(format($$select save_schedule(%L, '[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]')$$, :'ex',
  pg_temp.reg(:'ex', pg_temp.h(2)), pg_temp.reg(:'ex', pg_temp.p(2)), pg_temp.reg(:'ex', pg_temp.h(3)), pg_temp.reg(:'ex', pg_temp.p(4))),
  'exchange_sides', '한 팀에 두 편이 섞이면 거부');
select save_schedule(:'ex', format('[{"round":1,"order":1,"team1":["%s","%s"],"team2":["%s","%s"]}]',
  pg_temp.reg(:'ex', pg_temp.h(2)), pg_temp.reg(:'ex', pg_temp.h(3)), pg_temp.reg(:'ex', pg_temp.p(2)), pg_temp.reg(:'ex', pg_temp.p(4)))::jsonb);
select publish_schedule(:'ex');
select pg_temp.fails(format('select substitute_player(%L, %L, %L)', (select id from matches where session_id = :'ex'),
  pg_temp.reg(:'ex', pg_temp.p(2)), pg_temp.reg(:'ex', pg_temp.h(4))), 'exchange_sides', '교체는 같은 편끼리만');
select substitute_player((select id from matches where session_id = :'ex'), pg_temp.reg(:'ex', pg_temp.p(2)), :'rp5');

-- 상대 회원도 대진·급수를 봄
select pg_temp.as_user(pg_temp.p(4));
select pg_temp.ok((select count(*) from match_players mp join matches m on m.id = mp.match_id where m.session_id = :'ex') = 4, '공개 후 상대 회원도 대진을 봄');
select pg_temp.ok((select level from session_player_meta(:'ex') where registration_id = pg_temp.reg(:'ex', pg_temp.h(2))) = 'A조',
  '대진용 급수: 주최 회원 급수도 보임');
select pg_temp.ok((select level from session_player_meta(:'ex') where registration_id = :'gp') = 'C조', '게스트 급수');

-- 경기 시작 → 상대 선수 알림은 상대 동아리 경로
select pg_temp.as_user(pg_temp.h(1));
select set_checked_in(r, true) from unnest(array[pg_temp.reg(:'ex', pg_temp.h(2)), pg_temp.reg(:'ex', pg_temp.h(3)),
                                               :'rp5'::uuid, pg_temp.reg(:'ex', pg_temp.p(4))]) r;
select pg_temp.as_user(pg_temp.p(5));
select pg_temp.ok((select url = '/c/' || :'pc' || '/s/' || :'ex' || '/board' from pg_temp.notes(pg_temp.p(5), 'court_assigned')),
  '코트 배정 알림: 상대 선수는 자기 동아리 경로');
select pg_temp.ok((select url = '/c/' || :'hc' || '/s/' || :'ex' || '/board' from pg_temp.notes(pg_temp.h(2), 'court_assigned')),
  '주최 선수는 주최 동아리 경로');

-- 점수: 상대 운영진도 고칠 수 있음
select pg_temp.as_user(pg_temp.h(1));
select finish_with_score((select id from matches where session_id = :'ex'), 25, 20, 'normal');
select pg_temp.as_user(pg_temp.p(1));
select record_score((select id from matches where session_id = :'ex'), 23, 25, 'normal',
                    (select result_at from matches where session_id = :'ex'));
select pg_temp.ok((select score2 = 25 from matches where session_id = :'ex'), '상대 운영진이 점수 수정');
select pg_temp.fails(format('select end_tournament(%L)', :'ex'), 'forbidden', '대회 종료는 주최 운영진만');

-- ── 거절 ──────────────────────────────────────────────────────
select pg_temp.as_user(pg_temp.h(1));
select create_exchange(:'hc', :'pc', '거절될 교류전', '', now() + interval '2 day', now() + interval '2 day 3 hour', 4, 4, 2, null, 2, 25, null, 15) as ex2 \gset
select pg_temp.as_user(pg_temp.p(1));
select respond_exchange(:'ex2', false);
select pg_temp.as_user(pg_temp.p(2));
select pg_temp.ok(not exists (select 1 from sessions where id = :'ex2'), '거절된 교류전은 상대 회원에게 안 보임');
select pg_temp.as_user(pg_temp.h(1));
select pg_temp.ok((select count(*) from pg_temp.notes(pg_temp.h(1), 'exchange_reply') where title = '교류전 거절') = 1, '주최 운영진에게 거절 알림');
select pg_temp.fails(format('select publish_schedule(%L)', :'ex2'), 'partner_not_accepted', '상대가 수락하지 않은 교류전은 대진 공개 불가');
reset role;
