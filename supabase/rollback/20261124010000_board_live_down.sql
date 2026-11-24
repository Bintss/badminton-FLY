-- 20261124010000_board_live.sql 되돌리기
-- 순서: 앱 커밋을 먼저 revert하고 배포한 뒤 이 SQL을 실행 (앱이 closed_courts·left_at을 읽기 때문)
drop function public.set_left(uuid, boolean);
drop function public.set_court_count(uuid, int);
drop function public.set_court_open(uuid, int, boolean);

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
     set checked_in_at = case when p_checked_in then coalesce(checked_in_at, now()) else null end
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

drop view public.session_player_stats;
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
     and (m.phase = 'free' or s.tournament_state in ('published', 'in_progress'))))::int as queued_count
from public.registrations r
join public.sessions s on s.id = r.session_id
left join public.match_players mp on mp.registration_id = r.id
left join public.matches m on m.id = mp.match_id
where r.status = 'confirmed'
group by r.id;
revoke all on public.session_player_stats from anon, authenticated;
grant select on public.session_player_stats to authenticated;

alter table public.registrations drop column left_at;
alter table public.sessions drop column closed_courts;
