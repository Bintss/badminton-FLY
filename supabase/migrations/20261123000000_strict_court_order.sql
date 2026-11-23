-- =====================================================================
-- 자체대회: 코트마다 매치 순서 고정
--   빈 코트에는 그 코트의 바로 다음 경기(매치 순)만 들어간다.
--   그 경기 선수가 아직 안 왔거나 다른 코트에서 경기 중이면 뒤 매치 경기를 당겨오지 않고 기다린다.
--   (전에는 그 코트 경기 중 먼저 준비된 것을 넣어서, 먼저 온 사람 경기가 앞질러 들어갔다)
-- 되돌리기: supabase/rollback/20261123000000_strict_court_order_down.sql
-- =====================================================================

create or replace function public.fill_courts(p_session uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_courts  int;
  v_state   text;
  v_club    uuid;
  v_active  boolean;
  v_court   int;
  v_match   uuid;
  v_started int := 0;
begin
  select court_count, tournament_state, club_id into v_courts, v_state, v_club
    from public.sessions where id = p_session;
  v_active := v_state in ('published', 'in_progress');

  for v_court in 1..v_courts loop
    continue when exists (
      select 1 from public.matches
       where session_id = p_session and status = 'playing' and court_no = v_court
    );

    if v_active then
      -- 이 코트의 바로 다음 경기(매치 순)만. 그 경기 선수가 안 왔거나 다른 코트에서 경기 중이면
      -- 뒤 경기를 당겨오지 않고 이 코트는 기다린다 (매치·코트 순서를 지킨다)
      select m.id into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'scheduled'
         and public.scheduled_court(m.order_no, v_courts) = v_court
       order by m.round_no, m.order_no, m.created_at
       limit 1;
      continue when v_match is null;
      if not public.match_ready(v_match) then
        v_match := null;
        continue;
      end if;
    else
      select m.id into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'free'
       order by m.queue_pos, m.created_at
       limit 1;
      exit when v_match is null;
    end if;

    update public.matches
       set status = 'playing', court_no = v_court, queue_pos = null, started_at = now()
     where id = v_match;
    v_started := v_started + 1;
    v_match := null;
  end loop;

  if v_active then
    if v_state = 'published' and exists (
         select 1 from public.matches
          where session_id = p_session and phase = 'scheduled' and status in ('playing', 'finished')) then
      update public.sessions set tournament_state = 'in_progress' where id = p_session;
      perform public.log_activity(v_club, p_session, 'tournament.start', '{}'::jsonb);
    end if;
    if not exists (
         select 1 from public.matches
          where session_id = p_session and phase = 'scheduled' and status in ('queued', 'playing')) then
      update public.sessions set tournament_state = 'finished' where id = p_session;
      perform public.log_activity(v_club, p_session, 'tournament.finish', jsonb_build_object('auto', true));
    end if;
    -- 코트를 다 채운 뒤에 "다음 차례"를 정해야 정확하다
    perform public.notify_court_next(p_session);
  end if;

  return v_started;
end;
$$;
