-- 회원 1명당 클라이언트 2개가 동시에 신청 (연타·다중 탭 흉내): 100 클라이언트 → 50명
\set n (:client_id % 50) + 1
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(:n::text, 12, '0'), false);
set role authenticated;
select * from register('40000000-0000-0000-0000-000000000002');
reset role;
