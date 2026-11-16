-- 새 회원 61~100이 동시에 신청
\set n :client_id + 61
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(:n::text, 12, '0'), false);
set role authenticated;
select * from register('40000000-0000-0000-0000-000000000003');
reset role;
