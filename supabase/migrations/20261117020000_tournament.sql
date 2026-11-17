-- =====================================================================
-- T1: 자체대회 기반
--   대회 설정, 상태 전이(draft → published → in_progress → finished),
--   대회 경기(scheduled) 저장·확정·확정 취소·일찍 끝내기, 선수 교체,
--   대회 경기 우선 코트 배정, 대회 중 자율 경기 차단, 대진 초안은 운영진만 보기
--
-- 설계서: 자체대회·교류전 설계서 v0.1 (3, 4, 6, 8장)
-- =====================================================================

-- ---------------------------------------------------------------------
-- 컬럼
-- ---------------------------------------------------------------------
alter table public.sessions
  add column kind text not null default 'normal' check (kind in ('normal', 'tournament', 'exchange')),
  add column tournament_state text check (tournament_state in ('draft', 'published', 'in_progress', 'finished')),
  add column round_count int check (round_count between 1 and 20),
  add column score_target int not null default 25 check (score_target between 5 and 50),
  add column score_cap int default 30 check (score_cap is null or score_cap between 5 and 60),
  add column minutes_per_game int not null default 15 check (minutes_per_game between 5 and 60),
  add constraint sessions_tournament_state_kind check ((kind = 'normal') = (tournament_state is null)),
  add constraint sessions_score_cap_ge_target check (score_cap is null or score_cap >= score_target);

alter table public.registrations
  add column seed smallint check (seed between 1 and 5);   -- 대회용 실력 점수 (T3에서 편집 화면)

alter table public.matches
  add column phase text not null default 'free' check (phase in ('free', 'scheduled')),
  add column round_no int check (round_no between 1 and 20),
  add column order_no int check (order_no >= 1),
  add column score1 smallint check (score1 between 0 and 99),
  add column score2 smallint check (score2 between 0 and 99),
  add column result_kind text check (result_kind in ('normal', 'walkover1', 'walkover2')),
  add column result_by uuid references public.profiles(id) on delete set null,
  add column result_at timestamptz,
  add constraint matches_scheduled_round check (phase = 'free' or (round_no is not null and order_no is not null));

create index matches_scheduled_idx on public.matches (session_id, phase, status, round_no, order_no);

alter table public.match_players
  add column team smallint check (team in (1, 2));

-- ---------------------------------------------------------------------
-- 대진 초안은 운영진만 본다 (확정하면 참가 동아리 전체 공개)
-- ---------------------------------------------------------------------
create or replace function public.can_view_match(p_match uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
    select 1
      from public.matches m
      join public.sessions s on s.id = m.session_id
     where m.id = p_match
       and public.is_club_member(s.club_id)
       and (m.phase = 'free'
            or s.tournament_state is distinct from 'draft'
            or public.is_club_admin(s.club_id))
  );
$$;

drop policy matches_select on public.matches;
drop policy match_players_select on public.match_players;
create policy matches_select on public.matches
  for select to authenticated using (public.can_view_match(id));
create policy match_players_select on public.match_players
  for select to authenticated using (public.can_view_match(match_id));

-- ---------------------------------------------------------------------
-- 대회 경기를 지금 코트에 넣을 수 있는가
--   4명 모두 참석 확정 + 도착(체크인) + 다른 코트에서 경기 중이 아님
-- ---------------------------------------------------------------------
create or replace function public.match_ready(p_match uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select (select count(*) from public.match_players where match_id = p_match) = 4
     and not exists (
       select 1
         from public.match_players mp
         join public.registrations r on r.id = mp.registration_id
        where mp.match_id = p_match
          and (r.status <> 'confirmed'
               or r.checked_in_at is null
               or exists (
                    select 1
                      from public.match_players mp2
                      join public.matches m2 on m2.id = mp2.match_id
                     where mp2.registration_id = r.id and m2.status = 'playing' and m2.id <> p_match))
     );
$$;

-- ---------------------------------------------------------------------
-- 빈 코트 채우기 (교체) + 대회 상태 자동 전이
--   대회 진행 중(published / in_progress): 준비된 대회 경기를 (매치, 순서) 순으로. 준비 안 된 경기는 건너뜀
--   그 외: 자율 경기를 대기 순서대로
-- ---------------------------------------------------------------------
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
      select m.id into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'scheduled'
         and public.match_ready(m.id)
       order by m.round_no, m.order_no, m.created_at
       limit 1;
    else
      select m.id into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'free'
       order by m.queue_pos, m.created_at
       limit 1;
    end if;
    exit when v_match is null;

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
  end if;

  return v_started;
end;
$$;

-- 내부: 대회 관리 권한 = 세션 동아리 운영진. 세션을 잠그고 행을 돌려준다
create or replace function public.lock_tournament(p_session uuid)
returns public.sessions
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(s.club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  return s;
end;
$$;

-- ---------------------------------------------------------------------
-- 대회 설정 (운영진). 대회 설정 페이지의 저장 버튼
--   p_kind 'tournament'로 켜면 draft, 'normal'로 끄면 초안 삭제 (draft에서만)
--   매치 수: draft에서만 / 점수제: 첫 점수 입력 전까지 / 경기당 시간: 언제나
-- ---------------------------------------------------------------------
create or replace function public.save_tournament_settings(
  p_session          uuid,
  p_kind             text,
  p_round_count      int,
  p_score_target     int,
  p_score_cap        int,
  p_minutes_per_game int
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s          public.sessions%rowtype;
  v_scored   boolean;
  v_max_round int;
begin
  s := public.lock_tournament(p_session);

  if p_kind not in ('normal', 'tournament') then
    raise exception 'invalid_kind' using errcode = '22023';   -- 교류전은 T5
  end if;
  if p_round_count is not null and p_round_count not between 1 and 20 then
    raise exception 'invalid_round_count' using errcode = '22023';
  end if;
  if p_minutes_per_game is null or p_minutes_per_game not between 5 and 60 then
    raise exception 'invalid_minutes' using errcode = '22023';
  end if;
  if p_score_target is null or p_score_target not between 5 and 50 or (p_score_cap is not null and p_score_cap < p_score_target) then
    raise exception 'invalid_score_rule' using errcode = '22023';
  end if;

  select exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled' and result_at is not null)
    into v_scored;

  -- 끄기
  if p_kind = 'normal' then
    if s.kind <> 'normal' and s.tournament_state <> 'draft' then
      raise exception 'tournament_locked' using errcode = 'P0001';
    end if;
    delete from public.matches where session_id = p_session and phase = 'scheduled';
    update public.sessions
       set kind = 'normal', tournament_state = null, round_count = null,
           minutes_per_game = p_minutes_per_game
     where id = p_session;
    perform public.log_activity(s.club_id, p_session, 'tournament.disable', '{}'::jsonb);
    return;
  end if;

  -- 매치 수는 대진 확정 전까지
  if s.kind = 'tournament' and s.tournament_state <> 'draft' and p_round_count is distinct from s.round_count then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  select max(round_no) into v_max_round from public.matches where session_id = p_session and phase = 'scheduled';
  if v_max_round is not null and coalesce(p_round_count, 0) < v_max_round then
    raise exception 'rounds_in_use' using errcode = 'P0001';
  end if;
  -- 점수제는 첫 점수 입력 전까지
  if v_scored and (p_score_target <> s.score_target or p_score_cap is distinct from s.score_cap) then
    raise exception 'score_rule_locked' using errcode = 'P0001';
  end if;

  update public.sessions
     set kind = 'tournament',
         tournament_state = coalesce(tournament_state, 'draft'),
         round_count = p_round_count,
         score_target = p_score_target,
         score_cap = p_score_cap,
         minutes_per_game = p_minutes_per_game
   where id = p_session;

  perform public.log_activity(s.club_id, p_session,
    case when s.kind = 'normal' then 'tournament.enable' else 'tournament.settings' end,
    jsonb_build_object('round_count', p_round_count, 'score_target', p_score_target, 'score_cap', p_score_cap));
end;
$$;

-- ---------------------------------------------------------------------
-- 대진 초안 저장 (운영진, draft에서만). 초안 전체를 한 번에 바꾼다
--   p_matches: [{"round":1,"order":1,"team1":[reg,reg],"team2":[reg,reg]}, ...]
--   검증: 경기당 서로 다른 4명(팀당 2명), 모두 이 운동의 참석 확정자,
--         같은 매치에 같은 사람 한 번, (매치, 순서) 중복 없음, 매치 번호 ≤ 매치 수
-- ---------------------------------------------------------------------
create or replace function public.save_schedule(p_session uuid, p_matches jsonb)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s       public.sessions%rowtype;
  v_n     int;
  v_bad   int;
  rec     record;
  v_match uuid;
begin
  s := public.lock_tournament(p_session);
  if s.kind = 'normal' or s.tournament_state <> 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  if jsonb_typeof(p_matches) <> 'array' then
    raise exception 'invalid_schedule' using errcode = '22023';
  end if;
  v_n := jsonb_array_length(p_matches);
  if v_n > 400 then
    raise exception 'invalid_schedule' using errcode = '22023';
  end if;

  drop table if exists _sched_m, _sched_p;
  create temp table _sched_m (idx int, round_no int, order_no int) on commit drop;
  create temp table _sched_p (idx int, round_no int, team int, reg uuid) on commit drop;

  begin
    insert into _sched_m
    select ord::int, (e ->> 'round')::int, (e ->> 'order')::int
      from jsonb_array_elements(p_matches) with ordinality t(e, ord);

    insert into _sched_p
    select ord::int, (e ->> 'round')::int, 1, x::uuid
      from jsonb_array_elements(p_matches) with ordinality t(e, ord),
           jsonb_array_elements_text(coalesce(e -> 'team1', '[]'::jsonb)) x
    union all
    select ord::int, (e ->> 'round')::int, 2, x::uuid
      from jsonb_array_elements(p_matches) with ordinality t(e, ord),
           jsonb_array_elements_text(coalesce(e -> 'team2', '[]'::jsonb)) x;
  exception when others then
    raise exception 'invalid_schedule' using errcode = '22023';
  end;

  -- 매치·순서
  if exists (select 1 from _sched_m where round_no is null or order_no is null or order_no < 1
                or round_no < 1 or round_no > coalesce(s.round_count, 0)) then
    raise exception 'invalid_round' using errcode = '22023';
  end if;
  if exists (select 1 from _sched_m group by round_no, order_no having count(*) > 1) then
    raise exception 'duplicate_order' using errcode = '22023';
  end if;
  -- 경기당 팀별 2명, 서로 다른 4명
  if exists (
       select 1 from _sched_m m
        where (select count(*) from _sched_p p where p.idx = m.idx and p.team = 1) <> 2
           or (select count(*) from _sched_p p where p.idx = m.idx and p.team = 2) <> 2
           or (select count(distinct reg) from _sched_p p where p.idx = m.idx) <> 4) then
    raise exception 'need_four_players' using errcode = '22023';
  end if;
  -- 모두 이 운동의 참석 확정자
  select count(*) into v_bad from _sched_p p
   where not exists (select 1 from public.registrations r
                      where r.id = p.reg and r.session_id = p_session and r.status = 'confirmed');
  if v_bad > 0 then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  -- 같은 매치에 같은 사람 한 번
  if exists (select 1 from _sched_p group by round_no, reg having count(*) > 1) then
    raise exception 'duplicate_in_round' using errcode = '22023';
  end if;

  delete from public.matches where session_id = p_session and phase = 'scheduled';

  for rec in select * from _sched_m order by round_no, order_no loop
    insert into public.matches (session_id, phase, round_no, order_no, status, created_by)
    values (p_session, 'scheduled', rec.round_no, rec.order_no, 'queued', auth.uid())
    returning id into v_match;
    insert into public.match_players (match_id, registration_id, team)
    select v_match, p.reg, p.team from _sched_p p where p.idx = rec.idx;
  end loop;

  perform public.log_activity(s.club_id, p_session, 'tournament.save_schedule', jsonb_build_object('matches', v_n));
  return v_n;
end;
$$;

-- ---------------------------------------------------------------------
-- 대진 확정 (운영진): draft → published. 확정 즉시 참가자에게 공개
-- ---------------------------------------------------------------------
create or replace function public.publish_schedule(p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  s := public.lock_tournament(p_session);
  if s.kind = 'normal' or s.tournament_state <> 'draft' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled') then
    raise exception 'empty_schedule' using errcode = 'P0001';
  end if;
  -- 초안을 만든 뒤 참석을 취소한 사람이 있으면 먼저 고쳐야 한다
  if exists (
       select 1 from public.match_players mp
         join public.matches m on m.id = mp.match_id
         join public.registrations r on r.id = mp.registration_id
        where m.session_id = p_session and m.phase = 'scheduled' and r.status <> 'confirmed') then
    raise exception 'schedule_stale' using errcode = 'P0001';
  end if;

  -- 대회 중엔 대회 경기만: 대기 중인 자율 경기는 정리 (진행 중인 자율 경기는 끝까지)
  update public.matches set status = 'canceled', queue_pos = null, finished_at = now()
   where session_id = p_session and phase = 'free' and status = 'queued';

  update public.sessions set tournament_state = 'published' where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.publish', '{}'::jsonb);
  perform public.fill_courts(p_session);
end;
$$;

-- 확정 취소 (운영진): published → draft. 대회 경기가 하나도 시작 안 했을 때만
create or replace function public.unpublish_schedule(p_session uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  s := public.lock_tournament(p_session);
  if s.tournament_state <> 'published' then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;
  if exists (select 1 from public.matches where session_id = p_session and phase = 'scheduled'
               and status in ('playing', 'finished')) then
    raise exception 'tournament_started' using errcode = 'P0001';
  end if;
  update public.sessions set tournament_state = 'draft' where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.unpublish', '{}'::jsonb);
end;
$$;

-- 대회 일찍 끝내기 (운영진): 시작 안 한 대회 경기는 취소, 진행 중인 대회 경기는 끝까지
create or replace function public.end_tournament(p_session uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s       public.sessions%rowtype;
  v_count int;
begin
  s := public.lock_tournament(p_session);
  if s.tournament_state not in ('published', 'in_progress') then
    raise exception 'tournament_locked' using errcode = 'P0001';
  end if;

  update public.matches set status = 'canceled', queue_pos = null, finished_at = now()
   where session_id = p_session and phase = 'scheduled' and status = 'queued';
  get diagnostics v_count = row_count;

  update public.sessions set tournament_state = 'finished' where id = p_session;
  perform public.log_activity(s.club_id, p_session, 'tournament.finish', jsonb_build_object('auto', false, 'canceled', v_count));
  perform public.fill_courts(p_session);
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- 선수 교체 (운영진): 아직 시작 안 한 대회 경기에서 한 명을 다른 참석 확정자로
--   같은 매치에 이미 경기가 있는 사람은 안 됨. 팀은 그대로
-- ---------------------------------------------------------------------
create or replace function public.substitute_player(p_match uuid, p_out uuid, p_in uuid)
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

  if m.phase <> 'scheduled' or m.status <> 'queued' or s.tournament_state = 'finished' then
    raise exception 'not_substitutable' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.match_players where match_id = p_match and registration_id = p_out) then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  if not exists (select 1 from public.registrations
                  where id = p_in and session_id = m.session_id and status = 'confirmed') then
    raise exception 'invalid_players' using errcode = '22023';
  end if;
  if exists (
       select 1 from public.match_players mp
         join public.matches o on o.id = mp.match_id
        where mp.registration_id = p_in and o.session_id = m.session_id
          and o.phase = 'scheduled' and o.round_no = m.round_no and o.status <> 'canceled') then
    raise exception 'duplicate_in_round' using errcode = '22023';
  end if;

  update public.match_players set registration_id = p_in
   where match_id = p_match and registration_id = p_out;

  perform public.log_activity(s.club_id, m.session_id, 'tournament.substitute',
    jsonb_build_object('match_id', p_match, 'out', p_out, 'in', p_in));
  perform public.fill_courts(m.session_id);
end;
$$;

-- ---------------------------------------------------------------------
-- 기존 대진판 RPC 보강
-- ---------------------------------------------------------------------

-- 자율 경기 만들기: 대회 진행 중에는 거부. 경고는 실제로 대기·진행 중인 경기 기준
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

-- 경기 취소: 대회 경기는 운영진만
create or replace function public.cancel_match(p_match uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
  v_phase   text;
begin
  select session_id, phase into v_session, v_phase from public.matches where id = p_match;
  if v_session is null then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);
  if v_phase = 'scheduled' and not public.is_club_admin(v_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;

  update public.matches m
     set status = 'canceled', queue_pos = null, finished_at = now()
   where m.id = p_match and m.status in ('queued', 'playing');
  if not found then
    raise exception 'match_closed' using errcode = 'P0001';
  end if;

  perform public.fill_courts(v_session);
  perform public.log_activity(v_club, v_session, 'board.cancel_match', jsonb_build_object('match_id', p_match));
end;
$$;

-- 대기 순서 변경: 대회 경기는 확정된 순서를 따른다 (자율 경기만)
create or replace function public.move_match(p_match uuid, p_direction int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
  v_pos     int;
  v_phase   text;
  v_other   uuid;
  v_opos    int;
begin
  if p_direction not in (-1, 1) then
    raise exception 'invalid_direction' using errcode = '22023';
  end if;
  select session_id, phase into v_session, v_phase from public.matches where id = p_match;
  if v_session is null then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);
  if v_phase = 'scheduled' then
    raise exception 'scheduled_order_locked' using errcode = 'P0001';
  end if;

  select queue_pos into v_pos from public.matches where id = p_match and status = 'queued';
  if v_pos is null then
    raise exception 'not_queued' using errcode = 'P0001';
  end if;

  select id, queue_pos into v_other, v_opos from public.matches
   where session_id = v_session and status = 'queued' and phase = 'free'
     and case when p_direction < 0 then queue_pos < v_pos else queue_pos > v_pos end
   order by case when p_direction < 0 then -queue_pos else queue_pos end
   limit 1;
  if v_other is null then
    return;
  end if;

  update public.matches set queue_pos = v_opos where id = p_match;
  update public.matches set queue_pos = v_pos  where id = v_other;
  perform public.log_activity(v_club, v_session, 'board.move_match',
    jsonb_build_object('match_id', p_match, 'direction', p_direction));
end;
$$;

-- 체크인: 도착하면 그 사람이 기다리던 대회 경기가 바로 들어갈 수 있게 빈 코트를 다시 채운다
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

-- ---------------------------------------------------------------------
-- 뷰: 일정 목록에 대회 정보, 선수 통계의 '대기 경기 수'는 실제로 대기 중인 것만
-- ---------------------------------------------------------------------
create or replace view public.session_overview
with (security_invoker = true)
as
select
  s.id, s.club_id, s.template_id, s.type, s.host_user_id, s.title, s.place,
  s.starts_at, s.ends_at, s.capacity, s.court_count, s.opens_at, s.canceled_at,
  coalesce(c.confirmed, 0)::int  as confirmed_count,
  coalesce(c.waitlisted, 0)::int as waitlist_count,
  coalesce(c.guests, 0)::int     as guest_count,
  me.id                          as my_registration_id,
  me.status                      as my_status,
  s.kind,
  s.tournament_state,
  s.round_count,
  s.score_target,
  s.score_cap,
  s.minutes_per_game
from public.sessions s
left join lateral (
  select count(*) filter (where r.kind = 'member' and r.status = 'confirmed')  as confirmed,
         count(*) filter (where r.kind = 'member' and r.status = 'waitlisted') as waitlisted,
         count(*) filter (where r.kind = 'guest'  and r.status <> 'canceled')  as guests
    from public.registrations r
   where r.session_id = s.id
) c on true
left join lateral (
  select r.id, r.status
    from public.registrations r
   where r.session_id = s.id and r.user_id = auth.uid() and r.kind = 'member' and r.status <> 'canceled'
   limit 1
) me on true;

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
  (count(m.id) filter (where m.status = 'finished'))::int  as games,
  max(m.finished_at) filter (where m.status = 'finished')  as last_finished_at,
  coalesce(bool_or(m.status = 'playing'), false)           as is_playing,
  (count(m.id) filter (where m.status = 'queued'
     and (m.phase = 'free' or s.tournament_state in ('published', 'in_progress'))))::int as queued_count
from public.registrations r
join public.sessions s on s.id = r.session_id
left join public.match_players mp on mp.registration_id = r.id
left join public.matches m on m.id = mp.match_id
where r.status = 'confirmed'
group by r.id;

-- ---------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------
revoke execute on function public.can_view_match(uuid)                 from public, anon, authenticated;
revoke execute on function public.match_ready(uuid)                    from public, anon, authenticated;
revoke execute on function public.lock_tournament(uuid)                from public, anon, authenticated;
revoke execute on function public.fill_courts(uuid)                    from public, anon, authenticated;
revoke execute on function public.save_tournament_settings(uuid, text, int, int, int, int) from public, anon, authenticated;
revoke execute on function public.save_schedule(uuid, jsonb)           from public, anon, authenticated;
revoke execute on function public.publish_schedule(uuid)               from public, anon, authenticated;
revoke execute on function public.unpublish_schedule(uuid)             from public, anon, authenticated;
revoke execute on function public.end_tournament(uuid)                 from public, anon, authenticated;
revoke execute on function public.substitute_player(uuid, uuid, uuid)  from public, anon, authenticated;
revoke execute on function public.create_match(uuid, uuid[])           from public, anon, authenticated;
revoke execute on function public.cancel_match(uuid)                   from public, anon, authenticated;
revoke execute on function public.move_match(uuid, int)                from public, anon, authenticated;
revoke execute on function public.set_checked_in(uuid, boolean)        from public, anon, authenticated;

grant execute on function public.can_view_match(uuid)                  to authenticated;  -- RLS 정책에서 호출
grant execute on function public.save_tournament_settings(uuid, text, int, int, int, int) to authenticated;
grant execute on function public.save_schedule(uuid, jsonb)            to authenticated;
grant execute on function public.publish_schedule(uuid)                to authenticated;
grant execute on function public.unpublish_schedule(uuid)              to authenticated;
grant execute on function public.end_tournament(uuid)                  to authenticated;
grant execute on function public.substitute_player(uuid, uuid, uuid)   to authenticated;
grant execute on function public.create_match(uuid, uuid[])            to authenticated;
grant execute on function public.cancel_match(uuid)                    to authenticated;
grant execute on function public.move_match(uuid, int)                 to authenticated;
grant execute on function public.set_checked_in(uuid, boolean)         to authenticated;
