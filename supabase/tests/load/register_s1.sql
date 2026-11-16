-- 클라이언트마다 서로 다른 회원 (1~100)
\set n :client_id + 1
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(:n::text, 12, '0'), false);
set role authenticated;
select * from register('40000000-0000-0000-0000-000000000001');
reset role;
