-- =====================================================================
-- 일반 경기(정기·번개)도 고른 순서대로 팀을 저장: 1·2번 한 팀, 3·4번 한 팀
--   (전에는 팀이 비어 있어서 대진판이 DB가 돌려준 순서로 반씩 나눠 보여줬다. 고른 팀과 다를 수 있었다)
--   팀이 있으면 코트 배정 알림도 "파트너 · 상대"로 나간다
-- 되돌리기: supabase/rollback/20261124000000_board_teams_down.sql
-- =====================================================================

create or replace function public.create_match(p_session uuid, p_registrations uuid[])
returns table (match_id uuid, status public.match_status, court_no int, warnings uuid[])
language plpgsql security definer set search_path = ''
as $$
declare
  v_club     uuid;
  v_ids      uuid[];
  v_match    uuid;
  v_warnings uuid[];
  v_pos      int;
  v_state    text;
begin
  select array_agg(distinct x) into v_ids from unnest(p_registrations) x;
  if coalesce(array_length(v_ids, 1), 0) <> 4 or array_length(p_registrations, 1) <> 4 then
    raise exception 'need_four_players' using errcode = '22023';
  end if;

  v_club := public.lock_board(p_session);
  select tournament_state into v_state from public.sessions where id = p_session;
  if v_state in ('published', 'in_progress') then
    raise exception 'tournament_running' using errcode = 'P0001';
  end if;

  if (select count(*) from public.registrations r
       where r.id = any(v_ids) and r.session_id = p_session and r.status = 'confirmed') <> 4 then
    raise exception 'invalid_players' using errcode = '22023';
  end if;

  select array_agg(distinct mp.registration_id) into v_warnings
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
   where m.session_id = p_session and m.phase = 'free' and m.status in ('queued', 'playing')
     and mp.registration_id = any(v_ids);

  select coalesce(max(q.queue_pos), 0) + 1 into v_pos
    from public.matches q where q.session_id = p_session and q.status = 'queued' and q.phase = 'free';

  insert into public.matches (session_id, queue_pos, status, created_by, phase)
  values (p_session, v_pos, 'queued', auth.uid(), 'free')
  returning id into v_match;

  -- 고른 순서대로 1·2번이 한 팀, 3·4번이 한 팀 (대진판·알림에 팀이 그대로 보인다)
  insert into public.match_players (match_id, registration_id, team)
  select v_match, x, case when o <= 2 then 1 else 2 end
    from unnest(p_registrations) with ordinality as t(x, o);

  perform public.fill_courts(p_session);
  perform public.log_activity(v_club, p_session, 'board.create_match',
    jsonb_build_object('match_id', v_match, 'players', v_ids, 'warnings', coalesce(v_warnings, '{}')));

  return query
    select m.id, m.status, m.court_no, coalesce(v_warnings, '{}'::uuid[])
      from public.matches m where m.id = v_match;
end;
$$;
