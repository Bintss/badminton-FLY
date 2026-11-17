-- =====================================================================
-- 실시간 갱신 보강
--   match_players(경기 선수)는 실시간 구독 대상이 아니라서, 선수 교체처럼 선수만 바뀌면
--   다른 폰의 대진판·대진표가 그대로였다. 선수가 바뀌면 그 경기 행을 한 번 갱신해서
--   matches 구독(세션별 필터)으로 변경이 전달되게 한다.
-- =====================================================================
create or replace function public.touch_match_on_players()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  update public.matches set status = status where id = coalesce(new.match_id, old.match_id);
  return null;
end;
$$;

-- UPDATE만: 경기를 만들 때(INSERT)는 matches 행이 이미 새로 생겨 이벤트가 나간다
create trigger match_players_touch_match
  after update on public.match_players
  for each row execute function public.touch_match_on_players();

revoke execute on function public.touch_match_on_players() from public, anon, authenticated;
