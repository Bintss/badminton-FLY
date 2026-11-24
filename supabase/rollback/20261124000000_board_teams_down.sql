-- 20261124000000_board_teams.sql 되돌리기 (앱은 그대로 둬도 동작한다)

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

  insert into public.match_players (match_id, registration_id)
  select v_match, x from unnest(v_ids) x;

  perform public.fill_courts(p_session);
  perform public.log_activity(v_club, p_session, 'board.create_match',
    jsonb_build_object('match_id', v_match, 'players', v_ids, 'warnings', coalesce(v_warnings, '{}')));

  return query
    select m.id, m.status, m.court_no, coalesce(v_warnings, '{}'::uuid[])
      from public.matches m where m.id = v_match;
end;
$$;
