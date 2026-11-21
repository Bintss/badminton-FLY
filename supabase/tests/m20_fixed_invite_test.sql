-- 고정 참석자(정기운동) / 초대 링크 자동 가입
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
  select ('e2000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid $$;
-- 그 정기운동의 (가장 가까운) 일정에서 그 사람의 살아있는 신청
create or replace function pg_temp.reg(t uuid, n int) returns text language sql security definer as $$
  select r.status::text || case when r.is_fixed then '/fixed' else '' end
    from public.registrations r join public.sessions s on s.id = r.session_id
   where s.template_id = t and r.user_id = pg_temp.u(n) and r.status <> 'canceled'
   order by s.starts_at limit 1 $$;
grant execute on all functions in schema pg_temp to authenticated;

insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '회원' || n) from generate_series(1, 9) n;
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select create_club('고정 테스트') as club \gset
do $$ declare i int; c uuid := (select id from clubs where name = '고정 테스트'); begin
  for i in 2..6 loop perform pg_temp.as_user(pg_temp.u(i)); perform request_join(c); end loop;
  perform pg_temp.as_user(pg_temp.u(1));
  for i in 2..5 loop perform decide_member(c, pg_temp.u(i), true); end loop;   -- 6은 신청만
end $$;

-- ── 고정 참석자 ────────────────────────────────────────────────
\set WD '((extract(dow from now() at time zone ''Asia/Seoul'')::int + 2) % 7)::smallint'
select pg_temp.fails(format($$select save_template(%L, null, '레슨', %s::smallint, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false, array[%L::uuid])$$,
  :'club', :WD, pg_temp.u(6)), 'not_member', '승인 회원이 아니면 고정 참석자 불가');
select pg_temp.fails(format($$select save_template(%L, null, '레슨', %s::smallint, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false, array[%L, %L, %L, %L]::uuid[])$$,
  :'club', :WD, pg_temp.u(2), pg_temp.u(3), pg_temp.u(4), pg_temp.u(5)), 'fixed_over_capacity', '정원보다 많으면 불가');

select save_template(:'club', null, '레슨', :WD, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false,
  array[pg_temp.u(2), pg_temp.u(3), pg_temp.u(2)]) as tpl \gset
select pg_temp.ok((select fixed_user_ids = array[pg_temp.u(2), pg_temp.u(3)] from session_templates where id = :'tpl'), '명단 저장 (중복 제거, 순서 유지)');
select id as s1, opens_at > now() as before_open from sessions where template_id = :'tpl' order by starts_at limit 1 \gset
select pg_temp.ok(:'before_open'::boolean, '테스트 일정은 아직 투표 전');
select pg_temp.ok(pg_temp.reg(:'tpl', 2) = 'confirmed/fixed' and pg_temp.reg(:'tpl', 3) = 'confirmed/fixed', '일정이 만들어지면 고정 참석자는 투표 전에 바로 확정');
select pg_temp.ok((select confirmed_count from session_overview where id = :'s1') = 2, '정원에 포함');

-- 본인이 취소 → 명단을 다시 저장해도 다시 넣지 않는다
select pg_temp.as_user(pg_temp.u(2));
select cancel_registration((select id from registrations where session_id = :'s1' and user_id = pg_temp.u(2)));
select pg_temp.as_user(pg_temp.u(1));
select save_template(:'club', :'tpl', '레슨', :WD, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false,
  array[pg_temp.u(2), pg_temp.u(3), pg_temp.u(4)]);
select pg_temp.ok(pg_temp.reg(:'tpl', 2) is null, '스스로 취소한 일정에는 다시 넣지 않음');
select pg_temp.ok(pg_temp.reg(:'tpl', 4) = 'confirmed/fixed', '명단에 추가하면 이미 만들어진 일정에도 신청');

-- 명단에서 빼면 고정 신청만 취소
select save_template(:'club', :'tpl', '레슨', :WD, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false, array[pg_temp.u(4)]);
select pg_temp.ok(pg_temp.reg(:'tpl', 3) is null and pg_temp.reg(:'tpl', 4) = 'confirmed/fixed', '명단에서 빠지면 그 고정 신청은 취소');
-- p_fixed 없이 저장(예전 앱) → 명단 그대로
select save_template(:'club', :'tpl', '레슨 이름만', :WD, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false);
select pg_temp.ok((select fixed_user_ids = array[pg_temp.u(4)] from session_templates where id = :'tpl'), '명단을 안 보내면 그대로 둔다');

-- 정원이 차 있으면 대기로
reset role;
update sessions set opens_at = now() - interval '1 minute' where id = :'s1';
set role authenticated;
select pg_temp.as_user(pg_temp.u(5)); select register(:'s1');
select pg_temp.as_user(pg_temp.u(3)); select register(:'s1');
select pg_temp.as_user(pg_temp.u(1));
select save_template(:'club', :'tpl', '레슨', :WD, '19:00', '22:00', '', 3, 2, 1, '09:00', true, false, array[pg_temp.u(4), pg_temp.u(1)]);
select pg_temp.ok(pg_temp.reg(:'tpl', 1) = 'waitlisted/fixed', '정원이 차 있으면 고정 참석자도 대기');
select pg_temp.ok(pg_temp.reg(:'tpl', 3) = 'confirmed', '스스로 신청한 사람은 고정 신청으로 바뀌지 않음');

-- 투표 곧 오픈 알림: 이미 신청된 사람 제외
reset role;
select create_flash(:'club', '번개', '', now() + interval '1 day', now() + interval '1 day 2 hour', 8, 2, now() + interval '30 minute') as dummy \gset
update sessions set opens_at = now() + interval '5 minute', vote_soon_notified_at = null where id = :'s1';
update sessions set vote_soon_notified_at = now() where id <> :'s1';
select enqueue_vote_soon();
select pg_temp.ok(not exists (select 1 from notifications where session_id = :'s1' and kind = 'vote_soon' and user_id in (pg_temp.u(4), pg_temp.u(3)))
              and exists (select 1 from notifications where session_id = :'s1' and kind = 'vote_soon' and user_id = pg_temp.u(2)),
  '투표 곧 오픈 알림은 아직 신청 안 한 사람에게만');

-- ── 초대 링크 ──────────────────────────────────────────────────
set role authenticated;
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.fails(format('select get_invite(%L)', :'club'), 'forbidden', '일반 회원은 링크를 못 봄');
select pg_temp.fails(format('select reset_invite(%L)', :'club'), 'forbidden', '일반 회원은 링크를 못 만듦');
select pg_temp.fails('select * from club_invites', 'permission denied', '링크 테이블 직접 조회 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok(get_invite(:'club') is null, '처음엔 링크 없음');
select reset_invite(:'club') as tok \gset
select pg_temp.ok(get_invite(:'club') = :'tok' and length(:'tok') = 40, '링크 만들기');

select pg_temp.as_user(pg_temp.u(7));
select pg_temp.ok((select name = '고정 테스트' and my_status is null from invite_info(:'tok')), '링크 열면 동아리 확인');
select pg_temp.ok(join_by_invite(:'tok') = :'club'::uuid, '링크로 가입');
select pg_temp.ok(is_club_member(:'club'), '승인 없이 바로 회원');
select pg_temp.ok(join_by_invite(:'tok') = :'club'::uuid, '두 번 눌러도 그대로');
select pg_temp.as_user(pg_temp.u(6));
select join_by_invite(:'tok');
select pg_temp.ok((select status = 'approved' from club_members where club_id = :'club' and user_id = pg_temp.u(6)), '가입 신청 중이던 사람도 링크로 바로 가입');
reset role;
select pg_temp.ok((select count(*) from notifications where user_id = pg_temp.u(1) and kind = 'join_request' and title = '새 회원') = 2,
  '운영진에게 새 회원 알림');
set role authenticated;

-- 재발급 → 예전 링크 무효
select pg_temp.as_user(pg_temp.u(1));
select reset_invite(:'club') as tok2 \gset
select pg_temp.as_user(pg_temp.u(8));
select pg_temp.fails(format('select join_by_invite(%L)', :'tok'), 'invite_invalid', '재발급하면 예전 링크는 무효');
select pg_temp.ok(not exists (select 1 from invite_info(:'tok')), '예전 링크는 정보도 안 나옴');
-- 강퇴된 사람은 링크로도 못 들어온다
select join_by_invite(:'tok2');
select pg_temp.as_user(pg_temp.u(1));
select remove_member(:'club', pg_temp.u(8), true);
select pg_temp.as_user(pg_temp.u(8));
select pg_temp.ok((select banned from invite_info(:'tok2')), '강퇴된 사람: 링크 화면에서 알 수 있음');
select pg_temp.fails(format('select join_by_invite(%L)', :'tok2'), 'banned', '강퇴된 사람은 링크로도 가입 불가');
-- 끄기
select pg_temp.as_user(pg_temp.u(1));
select disable_invite(:'club');
select pg_temp.as_user(pg_temp.u(9));
select pg_temp.fails(format('select join_by_invite(%L)', :'tok2'), 'invite_invalid', '끄면 링크 가입 불가');
reset role;
