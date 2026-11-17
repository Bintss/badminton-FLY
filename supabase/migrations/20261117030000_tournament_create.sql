-- =====================================================================
-- 자체대회는 번개처럼 따로 만든다 (운영진만)
--   - create_tournament: 운동 + 대회 설정을 한 번에. 처음 상태는 대진 준비 중(draft)
--   - save_tournament_settings: 대회 설정만 수정. 일반 운동을 대회로 바꾸는 기능은 없앤다
--     (대회를 그만두려면 운동 취소)
-- =====================================================================

create or replace function public.create_tournament(
  p_club             uuid,
  p_title            text,
  p_place            text,
  p_starts_at        timestamptz,
  p_ends_at          timestamptz,
  p_capacity         int,
  p_court_count      int,
  p_opens_at         timestamptz,      -- null = 지금 바로 오픈
  p_round_count      int,
  p_score_target     int,
  p_score_cap        int,              -- null = 최대 점수 없음
  p_minutes_per_game int
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_open timestamptz := coalesce(p_opens_at, now());
  v_id   uuid;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_starts_at <= now() or p_ends_at <= p_starts_at or v_open > p_starts_at then
    raise exception 'invalid_time' using errcode = '22023';
  end if;
  if p_capacity is null or p_capacity <= 0 then
    raise exception 'invalid_capacity' using errcode = '22023';
  end if;
  if p_court_count is null or p_court_count <= 0 then
    raise exception 'invalid_court_count' using errcode = '22023';
  end if;
  if p_round_count is null or p_round_count not between 1 and 20 then
    raise exception 'invalid_round_count' using errcode = '22023';
  end if;
  if p_score_target is null or p_score_target not between 5 and 50
     or (p_score_cap is not null and (p_score_cap < p_score_target or p_score_cap > 60)) then
    raise exception 'invalid_score_rule' using errcode = '22023';
  end if;
  if p_minutes_per_game is null or p_minutes_per_game not between 5 and 60 then
    raise exception 'invalid_minutes' using errcode = '22023';
  end if;

  insert into public.sessions
    (club_id, type, host_user_id, title, place, starts_at, ends_at, capacity, court_count, opens_at,
     kind, tournament_state, round_count, score_target, score_cap, minutes_per_game)
  values
    (p_club, 'flash', auth.uid(), coalesce(nullif(btrim(p_title), ''), '자체대회'), coalesce(btrim(p_place), ''),
     p_starts_at, p_ends_at, p_capacity, p_court_count, v_open,
     'tournament', 'draft', p_round_count, p_score_target, p_score_cap, p_minutes_per_game)
  returning id into v_id;

  perform public.log_activity(p_club, v_id, 'session.create_tournament',
    jsonb_build_object('round_count', p_round_count));
  return v_id;
end;
$$;

-- 대회 설정 수정 (운영진). 매치 수: 확정 전까지 / 점수 규칙: 첫 점수 입력 전까지 / 경기당 시간: 언제나
drop function if exists public.save_tournament_settings(uuid, text, int, int, int, int);

create or replace function public.save_tournament_settings(
  p_session          uuid,
  p_round_count      int,
  p_score_target     int,
  p_score_cap        int,
  p_minutes_per_game int
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s           public.sessions%rowtype;
  v_scored    boolean;
  v_max_round int;
begin
  s := public.lock_tournament(p_session);
  if s.kind <> 'tournament' then
    raise exception 'not_tournament' using errcode = 'P0001';
  end if;
  if p_round_count is null or p_round_count not between 1 and 20 then
    raise exception 'invalid_round_count' using errcode = '22023';
  end if;
  if p_score_target is null or p_score_target not between 5 and 50
     or (p_score_cap is not null and (p_score_cap < p_score_target or p_score_cap > 60)) then
    raise exception 'invalid_score_rule' using errcode = '22023';
  end if;
  if p_minutes_per_game is null or p_minutes_per_game not between 5 and 60 then
    raise exception 'invalid_minutes' using errcode = '22023';
  end if;
  if s.tournament_state = 'finished' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;

  if s.tournament_state <> 'draft' and p_round_count <> s.round_count then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  select max(round_no) into v_max_round from public.matches where session_id = p_session and phase = 'scheduled';
  if v_max_round is not null and p_round_count < v_max_round then
    raise exception 'rounds_in_use' using errcode = 'P0001';
  end if;
  select exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled' and result_at is not null)
    into v_scored;
  if v_scored and (p_score_target <> s.score_target or p_score_cap is distinct from s.score_cap) then
    raise exception 'score_rule_locked' using errcode = 'P0001';
  end if;

  update public.sessions
     set round_count = p_round_count, score_target = p_score_target,
         score_cap = p_score_cap, minutes_per_game = p_minutes_per_game
   where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.settings',
    jsonb_build_object('round_count', p_round_count, 'score_target', p_score_target, 'score_cap', p_score_cap));
end;
$$;

revoke execute on function public.create_tournament(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, int, int, int, int) from public, anon, authenticated;
revoke execute on function public.save_tournament_settings(uuid, int, int, int, int) from public, anon, authenticated;
grant execute on function public.create_tournament(uuid, text, text, timestamptz, timestamptz, int, int, timestamptz, int, int, int, int) to authenticated;
grant execute on function public.save_tournament_settings(uuid, int, int, int, int) to authenticated;
