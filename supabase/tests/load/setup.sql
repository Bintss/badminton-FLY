-- 부하 테스트 데이터: 회원 150명(전원 승인), 세션 3개
\set ON_ERROR_STOP on
insert into auth.users (id, raw_user_meta_data)
select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid, jsonb_build_object('name', '회원' || n)
from generate_series(1, 150) n;

insert into clubs (id, name) values ('40000000-0000-0000-0000-000000000000', '부하 테스트');
insert into club_members (club_id, user_id, role, status)
select '40000000-0000-0000-0000-000000000000', id, 'member', 'approved' from auth.users
where id::text like '00000000-0000-0000-0000-%';

-- S1: 100명 동시 신청 / S2: 같은 사람 동시 중복 신청 / S3: 취소·신청 경합
insert into sessions (id, club_id, type, title, starts_at, ends_at, capacity, court_count, opens_at)
select ('40000000-0000-0000-0000-00000000000' || k)::uuid, '40000000-0000-0000-0000-000000000000', 'flash',
       'load ' || k, now() + interval '1 day', now() + interval '1 day 3 hour', 30, 5, now() - interval '1 second'
from generate_series(1, 3) k;

-- S3 사전 상태: 회원 1~30 확정, 31~60 대기 (seq 순서대로)
do $$
declare i int;
begin
  for i in 1..60 loop
    perform set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(i::text, 12, '0'), true);
    perform public.register('40000000-0000-0000-0000-000000000003');
  end loop;
end $$;
