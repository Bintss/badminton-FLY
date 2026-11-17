-- =====================================================================
-- T2: 대회 경기 점수 기록
--   - 경기 종료와 함께 점수 입력(finish_with_score) 또는 나중에 입력·수정(record_score)
--   - 권한: 대회 중에는 그 경기 선수(회원) 4명 + 운영진. 대회가 끝난 뒤 수정은 운영진만
--     (아직 점수가 없는 경기는 끝난 뒤에도 선수가 입력 가능: 마지막 경기 '나중에 입력' 대비)
--   - 규칙(목표 T, 상한 U): 이긴 팀 ≥ T, 진 팀 < 이긴 팀.
--       이긴 팀 = T 이면 진 팀 ≤ T-2 (25:24 거부)
--       이긴 팀 > T 이면 2점 차 (듀스), 단 이긴 팀 = U 이면 1점 차도 허용 (30:29). U 초과 불가
--   - 기권(walkover1 = 팀 1 기권승, walkover2 = 팀 2 기권승)은 점수 없이 승패만
--   - 두 폰 동시 입력: 세션 잠금으로 한 줄씩 + 마지막으로 본 result_at 비교 → 다르면 score_conflict
--   - 끝내 안 온 경기: 운영진이 기권 처리(forfeit_match). 실제로 치지 않았으므로 게임 수에 안 들어감
--   - 모든 입력·수정은 activity_log에 이전 값과 함께 남김
-- =====================================================================

-- 점수 규칙 검사. 맞으면 null, 아니면 이유
create or replace function public.score_problem(p_target int, p_cap int, p_s1 int, p_s2 int)
returns text
language plpgsql immutable set search_path = ''
as $$
declare
  w int := greatest(p_s1, p_s2);
  l int := least(p_s1, p_s2);
begin
  if p_s1 is null or p_s2 is null or p_s1 < 0 or p_s2 < 0 then return 'missing'; end if;
  if p_s1 = p_s2 then return 'tie'; end if;
  if w < p_target then return 'below_target'; end if;
  if p_cap is not null and w > p_cap then return 'over_cap'; end if;
  if w = p_target then
    if l > p_target - 2 then return 'need_two_point_lead'; end if;
    return null;
  end if;
  -- 듀스 이후
  if w - l = 2 then return null; end if;
  if p_cap is not null and w = p_cap and w - l = 1 then return null; end if;
  return 'need_two_point_lead';
end;
$$;

-- 점수를 넣을 수 있는가: 운영진, 또는 그 경기 선수(대회 중이거나 아직 점수가 없을 때)
create or replace function public.can_score_match(p_match uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match and m.phase = 'scheduled'
       and (
         public.is_club_admin(s.club_id)
         or ((s.tournament_state in ('published', 'in_progress') or m.result_at is null)
             and exists (select 1 from public.match_players mp
                           join public.registrations r on r.id = mp.registration_id
                          where mp.match_id = m.id and r.user_id = auth.uid() and r.kind = 'member'))
       )
  );
$$;

-- 내부: 점수 값 검증 후 matches에 기록 (잠금·권한·충돌 검사는 호출하는 쪽에서)
create or replace function public.write_score(p_match uuid, p_score1 int, p_score2 int, p_kind text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m        public.matches%rowtype;
  s        public.sessions%rowtype;
  v_reason text;
begin
  select * into m from public.matches where id = p_match;
  select * into s from public.sessions where id = m.session_id;

  if p_kind = 'normal' then
    v_reason := public.score_problem(s.score_target, s.score_cap, p_score1, p_score2);
    if v_reason is not null then
      raise exception 'invalid_score' using errcode = '22023', detail = v_reason;
    end if;
  elsif p_kind in ('walkover1', 'walkover2') then
    p_score1 := null;
    p_score2 := null;
  elsif p_kind = 'clear' then
    p_score1 := null;
    p_score2 := null;
  else
    raise exception 'invalid_score' using errcode = '22023', detail = 'kind';
  end if;

  update public.matches
     set score1 = p_score1, score2 = p_score2,
         result_kind = case when p_kind = 'clear' then null else p_kind end,
         result_by = case when p_kind = 'clear' then null else auth.uid() end,
         result_at = case when p_kind = 'clear' then null else clock_timestamp() end
   where id = p_match;

  perform public.log_activity(s.club_id, s.id, 'tournament.score',
    jsonb_build_object('match_id', p_match,
                       'before', jsonb_build_object('score1', m.score1, 'score2', m.score2, 'kind', m.result_kind),
                       'after',  jsonb_build_object('score1', p_score1, 'score2', p_score2, 'kind', p_kind)));
end;
$$;

-- 경기 종료 + 점수 (대회 경기). 점수가 규칙에 안 맞으면 경기도 끝나지 않는다
--   p_kind: 'normal' | 'walkover1' | 'walkover2' | null(점수는 나중에)
create or replace function public.finish_with_score(p_match uuid, p_score1 int, p_score2 int, p_kind text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  m      public.matches%rowtype;
  s      public.sessions%rowtype;
  v_next uuid;
begin
  select * into m from public.matches where id = p_match;
  if not found then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  if m.phase <> 'scheduled' then
    raise exception 'not_scheduled' using errcode = 'P0001';
  end if;
  perform public.lock_board(m.session_id);
  select * into s from public.sessions where id = m.session_id;

  if p_kind is not null then
    if not public.can_score_match(p_match) then
      raise exception 'score_forbidden' using errcode = '42501';
    end if;
    if p_kind = 'normal' and public.score_problem(s.score_target, s.score_cap, p_score1, p_score2) is not null then
      raise exception 'invalid_score' using errcode = '22023',
        detail = public.score_problem(s.score_target, s.score_cap, p_score1, p_score2);
    end if;
    if p_kind not in ('normal', 'walkover1', 'walkover2') then
      raise exception 'invalid_score' using errcode = '22023', detail = 'kind';
    end if;
  end if;

  v_next := public.finish_match(p_match);
  if p_kind is not null then
    perform public.write_score(p_match, p_score1, p_score2, p_kind);
  end if;
  return v_next;
end;
$$;

-- 점수 입력·수정 (끝난 대회 경기). p_expected = 화면이 마지막으로 본 result_at (없으면 null)
--   p_kind: 'normal' | 'walkover1' | 'walkover2' | 'clear'
create or replace function public.record_score(p_match uuid, p_score1 int, p_score2 int, p_kind text, p_expected timestamptz)
returns timestamptz
language plpgsql security definer set search_path = ''
as $$
declare
  m public.matches%rowtype;
begin
  select * into m from public.matches where id = p_match;
  if not found then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  perform 1 from public.sessions where id = m.session_id for update;   -- 세션 단위로 한 줄씩
  select * into m from public.matches where id = p_match for update;

  if m.phase <> 'scheduled' then
    raise exception 'not_scheduled' using errcode = 'P0001';
  end if;
  if not public.can_score_match(p_match) then
    raise exception 'score_forbidden' using errcode = '42501';
  end if;
  if m.status <> 'finished' then
    raise exception 'match_not_finished' using errcode = 'P0001';
  end if;
  if m.result_at is distinct from p_expected then
    raise exception 'score_conflict' using errcode = 'P0001';
  end if;

  perform public.write_score(p_match, p_score1, p_score2, p_kind);
  return (select result_at from public.matches where id = p_match);
end;
$$;

-- 끝내 안 온 경기 기권 처리 (운영진): 시작 안 한 대회 경기를 기권승으로 끝낸다. 게임 수에는 안 들어감
create or replace function public.forfeit_match(p_match uuid, p_winner int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  m public.matches%rowtype;
  s public.sessions%rowtype;
begin
  select * into m from public.matches where id = p_match;
  if not found then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  s := public.lock_tournament(m.session_id);
  select * into m from public.matches where id = p_match for update;
  if m.phase <> 'scheduled' or m.status <> 'queued' or s.tournament_state not in ('published', 'in_progress') then
    raise exception 'not_forfeitable' using errcode = 'P0001';
  end if;
  if p_winner not in (1, 2) then
    raise exception 'invalid_score' using errcode = '22023', detail = 'kind';
  end if;

  update public.matches set status = 'finished', queue_pos = null, finished_at = now() where id = p_match;
  perform public.write_score(p_match, null, null, case when p_winner = 1 then 'walkover1' else 'walkover2' end);
  perform public.log_activity(s.club_id, s.id, 'tournament.forfeit', jsonb_build_object('match_id', p_match, 'winner', p_winner));
  perform public.fill_courts(s.id);
end;
$$;

-- 게임 수: 실제로 친 경기만 (기권 처리로 끝난 경기는 started_at이 없음)
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

revoke execute on function public.score_problem(int, int, int, int)              from public, anon, authenticated;
revoke execute on function public.can_score_match(uuid)                           from public, anon, authenticated;
revoke execute on function public.write_score(uuid, int, int, text)               from public, anon, authenticated;
revoke execute on function public.finish_with_score(uuid, int, int, text)         from public, anon, authenticated;
revoke execute on function public.record_score(uuid, int, int, text, timestamptz) from public, anon, authenticated;
revoke execute on function public.forfeit_match(uuid, int)                        from public, anon, authenticated;
grant execute on function public.finish_with_score(uuid, int, int, text)          to authenticated;
grant execute on function public.record_score(uuid, int, int, text, timestamptz)  to authenticated;
grant execute on function public.forfeit_match(uuid, int)                         to authenticated;
