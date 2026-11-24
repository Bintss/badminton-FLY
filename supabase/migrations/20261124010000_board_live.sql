-- =====================================================================
-- 대진판 실사용 피드백
--   1) 코트를 그 자리에서 닫고 열기, 코트 수 늘리고 줄이기 (대진판 조작 권한)
--      닫힌 코트에는 새 경기를 넣지 않는다. 진행 중인 경기는 끝까지 그대로
--      대회 진행 중에는 코트 수를 못 바꾼다 (경기마다 코트가 정해져 있어서)
--   2) 퇴근 처리: 운영진(교류전은 그 편 운영진) 또는 본인. 게임판에서 빠지고
--      그 사람이 들어간 대기 경기(자율)는 취소된다. 경기 중이면 끝난 뒤에
--      다시 도착을 누르면 복귀
-- 되돌리기: supabase/rollback/20261124010000_board_live_down.sql
-- =====================================================================

alter table public.sessions add column closed_courts smallint[] not null default '{}';
alter table public.registrations add column left_at timestamptz;

create or replace view public.session_player_stats
with (security_invoker = true)
as
select
  r.id            as registration_id,
  r.session_id,
  r.kind,
  r.user_id,
  r.guest_name,
  r.seq,
  r.late_eta,
  r.checked_in_at,
  (count(m.id) filter (where m.status = 'finished' and m.started_at is not null))::int  as games,
  max(m.finished_at) filter (where m.status = 'finished' and m.started_at is not null)  as last_finished_at,
  coalesce(bool_or(m.status = 'playing'), false)           as is_playing,
  (count(m.id) filter (where m.status = 'queued'
     and (m.phase = 'free' or s.tournament_state in ('published', 'in_progress'))))::int as queued_count,
  r.left_at
from public.registrations r
join public.sessions s on s.id = r.session_id
left join public.match_players mp on mp.registration_id = r.id
left join public.matches m on m.id = mp.match_id
where r.status = 'confirmed'
group by r.id;

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
  v_closed  smallint[];
begin
  select court_count, tournament_state, club_id, closed_courts into v_courts, v_state, v_club, v_closed
    from public.sessions where id = p_session;
  v_active := v_state in ('published', 'in_progress');

  for v_court in 1..v_courts loop
    continue when v_court = any (v_closed);          -- 운영진이 닫은 코트에는 넣지 않는다
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

create or replace function public.set_checked_in(p_registration uuid, p_checked_in boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
begin
  select session_id into v_session from public.registrations where id = p_registration;
  if v_session is null then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);

  update public.registrations
     set checked_in_at = case when p_checked_in then coalesce(checked_in_at, now()) else null end,
         left_at = case when p_checked_in then null else left_at end    -- 퇴근했다 다시 오면 복귀
   where id = p_registration and status = 'confirmed';
  if not found then
    raise exception 'not_confirmed' using errcode = 'P0001';
  end if;

  perform public.log_activity(v_club, v_session, case when p_checked_in then 'board.check_in' else 'board.check_out' end,
    jsonb_build_object('registration_id', p_registration));
  if p_checked_in then
    perform public.fill_courts(v_session);
  end if;
end;
$$;

-- 코트 열기·닫기
create or replace function public.set_court_open(p_session uuid, p_court int, p_open boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_club   uuid;
  v_courts int;
begin
  v_club := public.lock_board(p_session);
  select court_count into v_courts from public.sessions where id = p_session;
  if p_court is null or p_court < 1 or p_court > v_courts then
    raise exception 'invalid_court' using errcode = '22023';
  end if;
  update public.sessions
     set closed_courts = case when p_open then array_remove(closed_courts, p_court::smallint)
                              else array(select distinct x from unnest(closed_courts || p_court::smallint) x order by x) end
   where id = p_session;
  perform public.log_activity(v_club, p_session, case when p_open then 'board.court_open' else 'board.court_close' end,
    jsonb_build_object('court', p_court));
  if p_open then
    perform public.fill_courts(p_session);
  end if;
end;
$$;

-- 코트 수 바꾸기 (자율 경기 중에만). 줄일 때 없어지는 코트에서 경기 중이면 안 된다
create or replace function public.set_court_count(p_session uuid, p_count int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_club  uuid;
  v_state text;
begin
  v_club := public.lock_board(p_session);
  if p_count is null or p_count < 1 or p_count > 20 then
    raise exception 'invalid_court' using errcode = '22023';
  end if;
  select tournament_state into v_state from public.sessions where id = p_session;
  if v_state in ('published', 'in_progress') then
    raise exception 'tournament_running' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.matches where session_id = p_session and status = 'playing' and court_no > p_count) then
    raise exception 'court_in_use' using errcode = 'P0001';
  end if;
  update public.sessions
     set court_count = p_count,
         closed_courts = array(select x from unnest(closed_courts) x where x <= p_count order by x)
   where id = p_session;
  perform public.log_activity(v_club, p_session, 'board.court_count', jsonb_build_object('count', p_count));
  perform public.fill_courts(p_session);
end;
$$;

-- 퇴근 처리 / 복귀. 퇴근하면서 취소된 대기 경기 수
create or replace function public.set_left(p_registration uuid, p_left boolean)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  r        public.registrations%rowtype;
  v_club   uuid;
  v_n      int := 0;
begin
  select * into r from public.registrations where id = p_registration;
  if not found then
    raise exception 'registration_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(r.session_id);
  if not (coalesce(r.user_id = auth.uid(), false)
          or public.is_side_admin(r.session_id, coalesce(r.side_club_id, v_club))) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if r.status <> 'confirmed' then
    raise exception 'not_confirmed' using errcode = 'P0001';
  end if;

  if p_left then
    if exists (select 1 from public.match_players mp join public.matches m on m.id = mp.match_id
                where mp.registration_id = p_registration and m.status = 'playing') then
      raise exception 'playing_now' using errcode = 'P0001';
    end if;
    -- 이 사람이 들어간 자율 대기 경기는 취소 (대회 경기는 선수 교체로 처리)
    with c as (
      update public.matches m set status = 'canceled', queue_pos = null, finished_at = now()
       where m.session_id = r.session_id and m.status = 'queued' and m.phase = 'free'
         and exists (select 1 from public.match_players mp where mp.match_id = m.id and mp.registration_id = p_registration)
      returning 1
    )
    select count(*) into v_n from c;
    update public.registrations set left_at = now(), checked_in_at = null where id = p_registration;
  else
    update public.registrations set left_at = null, checked_in_at = coalesce(checked_in_at, now()) where id = p_registration;
    perform public.fill_courts(r.session_id);
  end if;
  perform public.log_activity(v_club, r.session_id, case when p_left then 'board.left' else 'board.back' end,
    jsonb_build_object('registration_id', p_registration, 'canceled_matches', v_n));
  return v_n;
end;
$$;

revoke execute on function public.set_court_open(uuid, int, boolean) from public, anon;
revoke execute on function public.set_court_count(uuid, int)         from public, anon;
revoke execute on function public.set_left(uuid, boolean)            from public, anon;
grant execute on function public.set_court_open(uuid, int, boolean)  to authenticated;
grant execute on function public.set_court_count(uuid, int)          to authenticated;
grant execute on function public.set_left(uuid, boolean)             to authenticated;
