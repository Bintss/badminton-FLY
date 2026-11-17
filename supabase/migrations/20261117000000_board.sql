-- =====================================================================
-- M5: 현장 대진판
--   체크인, 게스트 추가, 경기 생성(4명) / 종료 / 취소 / 대기 순서 변경
--   빈 코트가 생기면 대기 1번 경기가 자동으로 들어간다 (fill_courts)
--   게임 수·쉰 시간은 저장하지 않고 session_player_stats 뷰로 계산한다
--
-- 권한: 해당 운동의 참석 확정자(회원) 누구나 + 동아리 운영진
-- 동시성: 모든 대진 RPC는 세션 행을 FOR UPDATE로 잠근다 (여러 폰에서 동시에 눌러도 한 줄로 처리)
-- =====================================================================

-- 내부: 대진판 조작 권한
create or replace function public.can_operate_board(p_session uuid)
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (
           select 1 from public.sessions s
            where s.id = p_session and public.is_club_admin(s.club_id)
         )
      or exists (
           select 1 from public.registrations r
            where r.session_id = p_session and r.user_id = auth.uid()
              and r.kind = 'member' and r.status = 'confirmed'
              and public.is_club_member(public.session_club_id(p_session))
         );
$$;

-- 내부: 세션 잠금 + 대진판 사용 가능 여부 확인. 세션의 club_id 반환
create or replace function public.lock_board(p_session uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  s public.sessions%rowtype;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.can_operate_board(p_session) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.canceled_at is not null then
    raise exception 'session_canceled' using errcode = 'P0001';
  end if;
  return s.club_id;
end;
$$;

-- 내부: 빈 코트에 대기 경기를 순서대로 넣는다. 세션이 잠긴 상태에서 호출. 반환 = 시작된 경기 수
create or replace function public.fill_courts(p_session uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_courts  int;
  v_court   int;
  v_match   uuid;
  v_started int := 0;
begin
  select court_count into v_courts from public.sessions where id = p_session;

  for v_court in 1..v_courts loop
    continue when exists (
      select 1 from public.matches
       where session_id = p_session and status = 'playing' and court_no = v_court
    );

    select id into v_match from public.matches
     where session_id = p_session and status = 'queued'
     order by queue_pos, created_at
     limit 1;
    exit when v_match is null;

    update public.matches
       set status = 'playing', court_no = v_court, queue_pos = null, started_at = now()
     where id = v_match;
    v_started := v_started + 1;
    v_match := null;
  end loop;

  return v_started;
end;
$$;

-- ---------------------------------------------------------------------
-- 체크인 / 체크인 취소 (참석자 누구나 대신 처리 가능)
-- ---------------------------------------------------------------------
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
end;
$$;

-- ---------------------------------------------------------------------
-- 게스트 추가: 이름만. 정원 밖, 바로 체크인 상태
-- ---------------------------------------------------------------------
create or replace function public.add_guest(p_session uuid, p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_club uuid;
  v_id   uuid;
begin
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  v_club := public.lock_board(p_session);

  insert into public.registrations (session_id, kind, guest_name, added_by, status, checked_in_at)
  values (p_session, 'guest', left(btrim(p_name), 30), auth.uid(), 'confirmed', now())
  returning id into v_id;

  perform public.log_activity(v_club, p_session, 'board.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30)));
  return v_id;
end;
$$;

-- ---------------------------------------------------------------------
-- 경기 만들기: 정확히 4명. 이미 대기/진행 중인 경기에 있는 사람은 막지 않고 warnings로 알려준다
--   반환: match_id, status(queued|playing), court_no, warnings(이미 배정된 registration id 배열)
-- ---------------------------------------------------------------------
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
begin
  select array_agg(distinct x) into v_ids from unnest(p_registrations) x;
  if coalesce(array_length(v_ids, 1), 0) <> 4 or array_length(p_registrations, 1) <> 4 then
    raise exception 'need_four_players' using errcode = '22023';
  end if;

  v_club := public.lock_board(p_session);

  if (select count(*) from public.registrations r
       where r.id = any(v_ids) and r.session_id = p_session and r.status = 'confirmed') <> 4 then
    raise exception 'invalid_players' using errcode = '22023';
  end if;

  select array_agg(distinct mp.registration_id) into v_warnings
    from public.match_players mp
    join public.matches m on m.id = mp.match_id
   where m.session_id = p_session and m.status in ('queued', 'playing')
     and mp.registration_id = any(v_ids);

  select coalesce(max(q.queue_pos), 0) + 1 into v_pos
    from public.matches q where q.session_id = p_session and q.status = 'queued';

  insert into public.matches (session_id, queue_pos, status, created_by)
  values (p_session, v_pos, 'queued', auth.uid())
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

-- ---------------------------------------------------------------------
-- 경기 종료 → 같은 코트(빈 코트)에 대기 1번 자동 진입
--   반환: 새로 시작된 경기 id (없으면 null)
-- ---------------------------------------------------------------------
create or replace function public.finish_match(p_match uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
  v_court   int;
  v_next    uuid;
begin
  select session_id into v_session from public.matches where id = p_match;
  if v_session is null then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);

  update public.matches
     set status = 'finished', finished_at = now()
   where id = p_match and status = 'playing'
  returning court_no into v_court;
  if not found then
    -- 다른 폰에서 먼저 종료한 경우 등
    raise exception 'not_playing' using errcode = 'P0001';
  end if;

  perform public.fill_courts(v_session);
  select id into v_next from public.matches
   where session_id = v_session and status = 'playing' and court_no = v_court;

  perform public.log_activity(v_club, v_session, 'board.finish_match',
    jsonb_build_object('match_id', p_match, 'court_no', v_court, 'next', v_next));
  return v_next;
end;
$$;

-- ---------------------------------------------------------------------
-- 경기 취소 (대기 또는 진행 중). 게임 수에 들어가지 않는다. 진행 중이었으면 빈 코트 채움
-- ---------------------------------------------------------------------
create or replace function public.cancel_match(p_match uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
  v_status  public.match_status;
begin
  select session_id into v_session from public.matches where id = p_match;
  if v_session is null then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);

  update public.matches m
     set status = 'canceled', queue_pos = null, finished_at = now()
   where m.id = p_match and m.status in ('queued', 'playing')
  returning m.status into v_status;
  if not found then
    raise exception 'match_closed' using errcode = 'P0001';
  end if;

  perform public.fill_courts(v_session);
  perform public.log_activity(v_club, v_session, 'board.cancel_match', jsonb_build_object('match_id', p_match));
end;
$$;

-- ---------------------------------------------------------------------
-- 대기 순서 변경: 위(-1) / 아래(+1)로 한 칸
-- ---------------------------------------------------------------------
create or replace function public.move_match(p_match uuid, p_direction int)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_session uuid;
  v_club    uuid;
  v_pos     int;
  v_other   uuid;
  v_opos    int;
begin
  if p_direction not in (-1, 1) then
    raise exception 'invalid_direction' using errcode = '22023';
  end if;
  select session_id into v_session from public.matches where id = p_match;
  if v_session is null then
    raise exception 'match_not_found' using errcode = 'P0002';
  end if;
  v_club := public.lock_board(v_session);

  select queue_pos into v_pos from public.matches where id = p_match and status = 'queued';
  if v_pos is null then
    raise exception 'not_queued' using errcode = 'P0001';
  end if;

  select id, queue_pos into v_other, v_opos from public.matches
   where session_id = v_session and status = 'queued'
     and case when p_direction < 0 then queue_pos < v_pos else queue_pos > v_pos end
   order by case when p_direction < 0 then -queue_pos else queue_pos end
   limit 1;
  if v_other is null then
    return; -- 이미 맨 위/맨 아래
  end if;

  update public.matches set queue_pos = v_opos where id = p_match;
  update public.matches set queue_pos = v_pos  where id = v_other;
  perform public.log_activity(v_club, v_session, 'board.move_match',
    jsonb_build_object('match_id', p_match, 'direction', p_direction));
end;
$$;

-- ---------------------------------------------------------------------
-- 참석자별 게임 수·마지막 경기 종료 시각·현재 상태
--   쉰 시간 = 지금 - greatest(last_finished_at, checked_in_at) (화면에서 계산)
--   늦참은 체크인 시각부터 세므로 늦게 왔다고 "덜 쳤다"로 보이지 않는다
-- ---------------------------------------------------------------------
create view public.session_player_stats
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
  (count(m.id) filter (where m.status = 'queued'))::int    as queued_count
from public.registrations r
left join public.match_players mp on mp.registration_id = r.id
left join public.matches m on m.id = mp.match_id
where r.status = 'confirmed'
group by r.id;

revoke all on public.session_player_stats from public, anon, authenticated;
grant select on public.session_player_stats to authenticated;

-- ---------------------------------------------------------------------
-- Realtime: 대진판 갱신용
-- ---------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    if not exists (select 1 from pg_publication_tables
                    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'matches') then
      alter publication supabase_realtime add table public.matches;
    end if;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------
revoke execute on function public.can_operate_board(uuid)            from public, anon, authenticated;
revoke execute on function public.lock_board(uuid)                   from public, anon, authenticated;
revoke execute on function public.fill_courts(uuid)                  from public, anon, authenticated;
revoke execute on function public.set_checked_in(uuid, boolean)      from public, anon, authenticated;
revoke execute on function public.add_guest(uuid, text)              from public, anon, authenticated;
revoke execute on function public.create_match(uuid, uuid[])         from public, anon, authenticated;
revoke execute on function public.finish_match(uuid)                 from public, anon, authenticated;
revoke execute on function public.cancel_match(uuid)                 from public, anon, authenticated;
revoke execute on function public.move_match(uuid, int)              from public, anon, authenticated;

grant execute on function public.can_operate_board(uuid)        to authenticated;  -- 화면에서 버튼 노출 판단용
grant execute on function public.set_checked_in(uuid, boolean)  to authenticated;
grant execute on function public.add_guest(uuid, text)          to authenticated;
grant execute on function public.create_match(uuid, uuid[])     to authenticated;
grant execute on function public.finish_match(uuid)             to authenticated;
grant execute on function public.cancel_match(uuid)             to authenticated;
grant execute on function public.move_match(uuid, int)          to authenticated;
