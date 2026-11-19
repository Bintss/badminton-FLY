-- 점검 정리: 조사 붙이기, 대진판 게스트 급수, 교류전 알림 문장
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
create or replace function pg_temp.body(u uuid, k text) returns text language sql security definer as $$
  select body from public.notifications where user_id = u and kind = k order by id desc limit 1 $$;
grant execute on all functions in schema pg_temp to authenticated;

-- ── 조사 ───────────────────────────────────────────────────────
select pg_temp.ok(josa('죽전 셔틀콕', '이', '가') = '죽전 셔틀콕이', '받침 있으면 이');
select pg_temp.ok(josa('단국대 배드민턴', '이', '가') = '단국대 배드민턴이', '받침 ㄴ도 이');
select pg_temp.ok(josa('FLY 클럽 하나', '이', '가') = 'FLY 클럽 하나가', '받침 없으면 가');
select pg_temp.ok(josa('주최 클럽', '과', '와') = '주최 클럽과', '받침 있으면 과');
select pg_temp.ok(josa('FLY', '을', '를') = 'FLY를', '영문은 받침 없는 쪽');
select pg_temp.ok(josa('2026', '이', '가') = '2026이' and josa('2025', '이', '가') = '2025가', '숫자는 읽는 소리로 (육 → 이, 오 → 가)');

-- ── 준비 ───────────────────────────────────────────────────────
insert into auth.users (id, raw_user_meta_data) values
  ('e1900000-0000-0000-0000-000000000001', '{"name":"주최운영"}'),
  ('e1900000-0000-0000-0000-000000000002', '{"name":"상대운영"}');
set role authenticated;
select pg_temp.as_user('e1900000-0000-0000-0000-000000000001'); select create_club('주최 클럽') as hc \gset
select pg_temp.as_user('e1900000-0000-0000-0000-000000000002'); select create_club('상대 셔틀콕') as pc \gset

-- ── 대진판 게스트 급수 ─────────────────────────────────────────
select pg_temp.as_user('e1900000-0000-0000-0000-000000000001');
select create_flash(:'hc', '번개', '체육관', now() + interval '1 hour', now() + interval '3 hour', 4, 1, now() - interval '1 hour', true) as fs \gset
select add_guest(:'fs', '  현장 손님 ', 'F', 'C조') as g1 \gset
select add_guest(:'fs', '급수 모름') as g2 \gset
select pg_temp.ok((select guest_level = 'C조' and guest_gender = 'F' and guest_name = '현장 손님' and status = 'confirmed' and checked_in_at is not null
                     from registrations where id = :'g1'), '대진판 게스트: 급수·성별 저장, 바로 확정·도착');
select pg_temp.ok((select guest_level is null from registrations where id = :'g2'), '급수 없이도 추가 (예전 호출 그대로)');
select pg_temp.fails(format($$select add_guest(%L, '손님', null, 'E조')$$, :'fs'), 'invalid_level', '급수는 목록에서만');
select pg_temp.ok((select level = 'C조' from session_player_meta(:'fs') where registration_id = :'g1'), '대진판 급수 표시용 메타에 게스트 급수가 나옴');

-- ── 교류전 알림 문장 ───────────────────────────────────────────
select create_exchange(:'hc', :'pc', '교류전', '체육관', now() + interval '1 day', now() + interval '1 day 3 hour', 4, 2, 4, null, 2, 25, 30, 15) as ex \gset
select pg_temp.as_user('e1900000-0000-0000-0000-000000000002');
select respond_exchange(:'ex', true);
reset role;
select pg_temp.ok(pg_temp.body('e1900000-0000-0000-0000-000000000001', 'exchange_reply') = '상대 셔틀콕이 ''교류전'' 초대를 수락했어요',
  '수락 알림: 조사 맞춤, "교류전" 중복 없음');
