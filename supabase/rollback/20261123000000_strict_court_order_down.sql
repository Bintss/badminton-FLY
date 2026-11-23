-- 20261123000000_strict_court_order.sql 되돌리기 (앱 변경은 문구뿐이라 순서 상관없음)
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
      -- 이 코트에 배정된 경기 중 준비된 것 (매치 순). 없으면 이 코트는 비워 두고 다음 코트
      select m.id into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'scheduled'
         and public.scheduled_court(m.order_no, v_courts) = v_court
         and public.match_ready(m.id)
       order by m.round_no, m.order_no, m.created_at
       limit 1;
      continue when v_match is null;
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
