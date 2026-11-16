-- 확정자 1~20이 동시에 취소
\set n :client_id + 1
select set_config('request.jwt.claim.sub', '00000000-0000-0000-0000-' || lpad(:n::text, 12, '0'), false);
set role authenticated;
select cancel_registration((select id from registrations
  where session_id = '40000000-0000-0000-0000-000000000003' and user_id = auth.uid() and status <> 'canceled'));
reset role;
