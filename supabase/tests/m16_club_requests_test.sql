-- 동아리 개설 승인제: 신청, 서비스 관리자만 승인·거절, 바로 만들기는 서비스 관리자만
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
  select ('e1600000-0000-0000-0000-0000000000' || lpad(n::text, 2, '0'))::uuid;
$$;
grant execute on all functions in schema pg_temp to authenticated;

-- 1 = 서비스 관리자, 2·3 = 일반 사용자
insert into auth.users (id, raw_user_meta_data) select pg_temp.u(n), jsonb_build_object('name', '사람' || n) from generate_series(1, 3) n;
delete from platform_admins where user_id in (pg_temp.u(2), pg_temp.u(3));   -- 로컬 테스트 설정이 자동 등록한 것 취소

set role authenticated;
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok(not is_platform_admin(), '일반 사용자는 서비스 관리자 아님');
select pg_temp.fails($$select create_club('몰래 동아리')$$, 'club_needs_approval', '일반 사용자는 바로 만들 수 없음');
select pg_temp.fails($$insert into platform_admins (user_id) values (auth.uid())$$, 'permission denied', '스스로 서비스 관리자가 될 수 없음');
select pg_temp.fails($$select request_club('   ')$$, 'invalid_name', '빈 이름 거부');
select request_club('  수요 배드민턴 ', '단국대 죽전, 매주 수요일') as req2 \gset
select pg_temp.ok((select name = '수요 배드민턴' and requester_name = '사람2' and status = 'pending' from club_requests where id = :'req2'),
  '신청 저장 (이름 다듬기, 신청자 이름)');
select pg_temp.fails($$select request_club('또 신청')$$, 'request_pending', '대기 중인 신청은 한 사람당 하나');
select pg_temp.fails(format('select decide_club_request(%L, true)', :'req2'), 'forbidden', '신청자가 스스로 승인 불가');

select pg_temp.as_user(pg_temp.u(3));
select pg_temp.ok((select count(*) from club_requests) = 0, '남의 신청은 안 보임');
select pg_temp.fails(format('select cancel_club_request(%L)', :'req2'), 'request_not_found', '남의 신청 취소 불가');
select request_club('토요 번개단') as req3 \gset

reset role;
select pg_temp.ok((select count(*) from notifications where user_id = pg_temp.u(1) and kind = 'club_request') = 2
              and (select url from notifications where user_id = pg_temp.u(1) and kind = 'club_request' limit 1) = '/admin/clubs',
  '서비스 관리자에게 신청 알림 (관리 화면으로 이동)');
select pg_temp.ok((select count(*) from notifications where user_id in (pg_temp.u(2), pg_temp.u(3)) and kind = 'club_request') = 0,
  '일반 사용자에게는 신청 알림 없음');

-- 서비스 관리자: 모든 신청을 보고 승인·거절
set role authenticated;
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.ok(is_platform_admin(), '서비스 관리자 확인');
select pg_temp.ok((select count(*) from club_requests where id in (:'req2', :'req3')) = 2, '서비스 관리자는 모든 신청을 봄');
select decide_club_request(:'req2', true) as club2 \gset
select pg_temp.ok((select status = 'approved' and club_id = :'club2' from club_requests where id = :'req2'), '승인 → 동아리 연결');
select pg_temp.fails(format('select decide_club_request(%L, false)', :'req2'), 'request_not_found', '이미 처리한 신청은 다시 처리 불가');
select decide_club_request(:'req3', false, '  이름이 너무 짧아요 ');
select pg_temp.ok((select status = 'rejected' and reason = '이름이 너무 짧아요' and club_id is null from club_requests where id = :'req3'), '거절 이유 저장');
select pg_temp.ok((select count(*) from club_members where club_id = :'club2' and user_id = pg_temp.u(1)) = 0, '승인한 관리자는 그 동아리 회원이 되지 않음');
select create_club('관리자 동아리') as club1 \gset
select pg_temp.ok(:'club1' is not null, '서비스 관리자는 바로 만들 수 있음');

-- 신청자: 운영진이 되고 알림을 받음
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok(is_club_admin(:'club2'), '신청자가 첫 운영진');
select pg_temp.ok((select name from clubs where id = :'club2') = '수요 배드민턴', '신청한 이름으로 만들어짐');
select pg_temp.ok((select url = '/c/' || :'club2' and title = '동아리 개설 승인' from notifications where kind = 'club_decided'), '승인 알림 → 동아리로 이동');
select pg_temp.as_user(pg_temp.u(3));
select pg_temp.ok((select body like '%거절됐어요. 이름이 너무 짧아요' and url = '/clubs' from notifications where kind = 'club_decided'), '거절 알림에 이유');
select request_club('토요 번개단 시즌2') as req3b \gset
select cancel_club_request(:'req3b');
select pg_temp.ok((select status from club_requests where id = :'req3b') = 'canceled', '거절 뒤 다시 신청, 내 신청 취소');

-- ── 서비스 관리자의 동아리 삭제 ─────────────────────────────────
select pg_temp.as_user(pg_temp.u(3));
select pg_temp.fails(format('select delete_club(%L, %L)', :'club2', '수요 배드민턴'), 'forbidden', '일반 사용자는 남의 동아리 삭제 불가');
select pg_temp.as_user(pg_temp.u(1));
select pg_temp.fails(format('select delete_club(%L, %L)', :'club2', '수요'), 'confirm_name_mismatch', '이름이 다르면 삭제 안 됨');
select delete_club(:'club2', '수요 배드민턴');
select pg_temp.ok(not exists (select 1 from clubs where id = :'club2'), '회원이 아니어도 서비스 관리자는 삭제');
select pg_temp.as_user(pg_temp.u(2));
select pg_temp.ok((select body = '''수요 배드민턴'' 동아리가 서비스 관리자에 의해 삭제됐어요' and url = '/clubs'
                     from notifications where kind = 'club_deleted'), '그 동아리 운영진에게 삭제 알림');
select pg_temp.ok((select count(*) from notifications where kind = 'club_decided') = 0, '지운 동아리에 딸린 알림(개설 승인)은 함께 지워짐');
reset role;
