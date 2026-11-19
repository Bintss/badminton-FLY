-- 동아리 정보 검증: 소개·링크·로고 경로·장소, 권한
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

\set A '00000000-0000-0000-0000-0000000006a1'
\set B '00000000-0000-0000-0000-0000000006b1'
\set E '00000000-0000-0000-0000-0000000006e1'
insert into auth.users (id, raw_user_meta_data) values (:'A', '{"name":"운영진"}'), (:'B', '{"name":"회원"}'), (:'E', '{"name":"외부인"}');

set role authenticated;
select pg_temp.as_user(:'A');
select create_club('프로필 테스트') as club \gset
select pg_temp.as_user(:'B'); select request_join(:'club');
select pg_temp.as_user(:'A'); select decide_member(:'club', :'B', true);

-- ── 기본 정보 ────────────────────────────────────────────────
select update_club_profile(:'club', '  단국대 FLY  ', E'매주 수·토 운동해요.\n초보 환영', 'https://open.kakao.com/o/abc');
select pg_temp.ok((select name = '단국대 FLY' and description like '매주%' and link_url = 'https://open.kakao.com/o/abc' from clubs where id = :'club'), '운영진이 이름·소개·링크 수정');
select pg_temp.fails(format($$select update_club_profile('%s', 'x', '', 'http://insecure.example')$$, :'club'), 'invalid_link', 'https가 아닌 링크 거부');
select pg_temp.fails(format($$select update_club_profile('%s', '   ', '', null)$$, :'club'), 'invalid_name', '빈 이름 거부');
select update_club_profile(:'club', '단국대 FLY', '', '  ');
select pg_temp.ok((select link_url is null from clubs where id = :'club'), '링크 비우면 null');
select pg_temp.as_user(:'B');
select pg_temp.fails(format($$select update_club_profile('%s', 'x', '', null)$$, :'club'), 'forbidden', '일반 회원은 수정 불가');

-- ── 로고 경로 ────────────────────────────────────────────────
select pg_temp.as_user(:'A');
select set_club_logo(:'club', :'club' || '/logo-1700000000.webp');
select pg_temp.ok((select logo_path = :'club' || '/logo-1700000000.webp' from clubs where id = :'club'), '로고 경로 저장');
select pg_temp.fails(format($$select set_club_logo('%s', 'other-club/logo.png')$$, :'club'), 'invalid_logo_path', '다른 폴더 경로 거부');
select pg_temp.fails(format($$select set_club_logo('%s', '%s/../x.png')$$, :'club', :'club'), 'invalid_logo_path', '경로 조작 거부');
select set_club_logo(:'club', null);
select pg_temp.ok((select logo_path is null from clubs where id = :'club'), '로고 해제');
reset role;
delete from platform_admins where user_id in (:'A', :'B');   -- 로컬 테스트 설정이 넣은 서비스 관리자 표시를 빼고 동아리 운영진 권한만 본다
set role authenticated;
select pg_temp.ok(is_admin_of_logo_path(:'club' || '/a.png'), 'Storage 정책: 운영진은 자기 동아리 폴더에 업로드 가능');
select pg_temp.ok(not is_admin_of_logo_path('not-a-uuid/a.png'), 'Storage 정책: 형식 틀린 경로는 false (에러 아님)');
select pg_temp.as_user(:'B');
select pg_temp.ok(not is_admin_of_logo_path(:'club' || '/a.png'), 'Storage 정책: 일반 회원은 업로드 불가');

-- ── 장소 ─────────────────────────────────────────────────────
select pg_temp.as_user(:'A');
select save_place(:'club', null, '단국대 체육관', '경기 용인시 수지구 죽전로 152', '2층, 실내화 필수') as p1 \gset
select save_place(:'club', null, '죽전 시민체육관', '', '') as p2 \gset
select pg_temp.ok((select count(*) from club_places where club_id = :'club') = 2, '장소 2곳 추가');
select pg_temp.ok((select sort from club_places where id = :'p2') > (select sort from club_places where id = :'p1'), '추가한 순서대로 정렬');
select save_place(:'club', :'p2', '죽전 체육관', '죽전동', '');
select pg_temp.ok((select name = '죽전 체육관' and address = '죽전동' from club_places where id = :'p2'), '장소 수정');
select pg_temp.fails(format($$select save_place('%s', null, '  ', '', '')$$, :'club'), 'invalid_name', '빈 장소 이름 거부');
select pg_temp.as_user(:'B');
select pg_temp.fails(format($$select save_place('%s', null, 'x', '', '')$$, :'club'), 'forbidden', '일반 회원은 장소 추가 불가');
select pg_temp.fails(format($$select delete_place('%s')$$, :'p1'), 'forbidden', '일반 회원은 장소 삭제 불가');
select pg_temp.fails(format($$insert into club_places (club_id, name) values ('%s', 'x')$$, :'club'), 'permission denied', 'club_places 직접 insert 불가');

-- 가입 전에도 소개·장소 열람 가능
select pg_temp.as_user(:'E');
select pg_temp.ok((select count(*) from club_places where club_id = :'club') = 2, '비회원도 장소 열람 (가입 전 확인용)');
select pg_temp.ok((select name from clubs where id = :'club') = '단국대 FLY', '비회원도 동아리 이름·소개 열람');
select pg_temp.fails(format($$select update_club_profile('%s', 'x', '', null)$$, :'club'), 'forbidden', '비회원은 수정 불가');

select pg_temp.as_user(:'A');
select delete_place(:'p1');
select pg_temp.ok((select count(*) from club_places where club_id = :'club') = 1, '운영진 장소 삭제');

reset role;
select 'ALL CLUB PROFILE TESTS PASSED' as result;
