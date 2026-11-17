-- =====================================================================
-- 자체대회: 경기마다 코트 고정 + "코트 대기" 알림
--
--   1) 대회 경기는 순서 번호가 곧 코트 번호 (매치 r의 n번째 경기 → 코트 n)
--      경기 수가 코트보다 많으면 돌아가며 (코트 4면, 5번째 경기 → 코트 1)
--      빈 코트에는 그 코트에 배정된 경기만 들어간다 (다른 코트 경기를 끌어오지 않음)
--   2) court_next 알림: 내 경기가 그 코트의 바로 다음 차례가 되면 (앞 경기가 시작된 순간)
--      받는 사람 = 그 경기의 회원 선수, 경기마다 한 번만
-- =====================================================================

-- ---------------------------------------------------------------------
-- 코트 번호 계산 (앱의 courtOf와 같은 규칙)
-- ---------------------------------------------------------------------
create or replace function public.scheduled_court(p_order int, p_courts int)
returns int
language sql immutable set search_path = ''
as $$
  select ((greatest(coalesce(p_order, 1), 1) - 1) % greatest(coalesce(p_courts, 1), 1)) + 1;
$$;

alter table public.matches add column next_notified_at timestamptz;

-- ---------------------------------------------------------------------
-- 알림 종류에 court_next 추가
-- ---------------------------------------------------------------------
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next'));
alter table public.notification_mutes drop constraint notification_mutes_kind_check;
alter table public.notification_mutes add constraint notification_mutes_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next'));

create or replace function public.set_notification_pref(p_kind text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_kind not in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next') then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;
  if p_enabled then
    delete from public.notification_mutes where user_id = auth.uid() and kind = p_kind;
  else
    insert into public.notification_mutes (user_id, kind) values (auth.uid(), p_kind) on conflict do nothing;
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 내부: 코트마다 "다음 경기" 선수에게 알림 (아직 안 알린 경기만)
--   지금 경기 중인 코트만 본다. 빈 코트에서 선수를 기다리는 경기는 들어갈 때 court_assigned로 알린다
--   (대진표를 미리 공개했을 때 몇 시간 전에 알림이 가지 않게)
-- ---------------------------------------------------------------------
create or replace function public.notify_court_next(p_session uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  v_courts int;
  v_club   uuid;
  v_court  int;
  v_match  public.matches%rowtype;
  p        record;
  v_count  int := 0;
begin
  begin
    select court_count, club_id into v_courts, v_club from public.sessions
     where id = p_session and tournament_state in ('published', 'in_progress') and canceled_at is null;
    if v_courts is null then
      return 0;
    end if;

    for v_court in 1..v_courts loop
      continue when not exists (
        select 1 from public.matches
         where session_id = p_session and status = 'playing' and court_no = v_court
      );

      select m.* into v_match from public.matches m
       where m.session_id = p_session and m.status = 'queued' and m.phase = 'scheduled'
         and public.scheduled_court(m.order_no, v_courts) = v_court
       order by m.round_no, m.order_no, m.created_at
       limit 1;
      continue when v_match.id is null or v_match.next_notified_at is not null;

      update public.matches set next_notified_at = now() where id = v_match.id;

      for p in
        select mp.registration_id, mp.team, r.user_id
          from public.match_players mp join public.registrations r on r.id = mp.registration_id
         where mp.match_id = v_match.id and r.kind = 'member'
      loop
        perform public.notify(p.user_id, v_club, p_session, 'court_next',
          '코트 ' || v_court || ' 다음 경기 (매치 ' || v_match.round_no || ')',
          '지금 경기가 끝나면 바로 들어가요. 파트너 ' ||
            coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ' order by r2.seq)
                        from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                        left join public.profiles pr on pr.id = r2.user_id
                       where mp2.match_id = v_match.id and mp2.team = p.team and mp2.registration_id <> p.registration_id), '-') ||
            ', 상대 ' ||
            coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ' order by r2.seq)
                        from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                        left join public.profiles pr on pr.id = r2.user_id
                       where mp2.match_id = v_match.id and mp2.team is distinct from p.team), '-'),
          '/c/' || v_club || '/s/' || p_session || '/board');
        v_count := v_count + 1;
      end loop;
      v_match := null;
    end loop;
  exception when others then
    -- 알림 때문에 코트 채우기가 실패하면 안 된다
    raise warning 'notify_court_next failed: %', sqlerrm;
  end;
  return v_count;
end;
$$;

-- ---------------------------------------------------------------------
-- 빈 코트 채우기: 대회 경기는 자기 코트에만
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

-- ---------------------------------------------------------------------
-- 코트 시작 알림 제목: 코트 번호가 이미 있으니 "매치 r"만
-- ---------------------------------------------------------------------
create or replace function public.matches_notify_court()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  p       record;
  v_club  uuid;
  v_title text;
  v_teams boolean;
begin
  begin
    if new.status <> 'playing' or (tg_op = 'UPDATE' and old.status = 'playing') then
      return null;
    end if;
    select club_id into v_club from public.sessions where id = new.session_id;
    v_title := '코트 ' || new.court_no || '에서 경기 시작' ||
               case when new.phase = 'scheduled' then ' (매치 ' || new.round_no || ')' else '' end;
    select bool_and(team is not null) into v_teams from public.match_players where match_id = new.id;

    for p in
      select mp.registration_id, mp.team, r.user_id
        from public.match_players mp join public.registrations r on r.id = mp.registration_id
       where mp.match_id = new.id and r.kind = 'member'
    loop
      perform public.notify(p.user_id, v_club, new.session_id, 'court_assigned', v_title,
        case when coalesce(v_teams, false) then
          '파트너 ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                                  from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                                  left join public.profiles pr on pr.id = r2.user_id
                                 where mp2.match_id = new.id and mp2.team = p.team and mp2.registration_id <> p.registration_id), '-') ||
          ', 상대 ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                                from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                                left join public.profiles pr on pr.id = r2.user_id
                               where mp2.match_id = new.id and mp2.team <> p.team), '-')
        else
          '함께: ' || coalesce((select string_agg(coalesce(r2.guest_name, pr.display_name), ', ')
                               from public.match_players mp2 join public.registrations r2 on r2.id = mp2.registration_id
                               left join public.profiles pr on pr.id = r2.user_id
                              where mp2.match_id = new.id and mp2.registration_id <> p.registration_id), '-')
        end,
        '/c/' || v_club || '/s/' || new.session_id || '/board');
    end loop;
  exception when others then
    raise warning 'matches_notify_court failed: %', sqlerrm;
  end;
  return null;
end;
$$;

revoke execute on function public.scheduled_court(int, int)  from public, anon;
grant  execute on function public.scheduled_court(int, int)  to authenticated;
revoke execute on function public.notify_court_next(uuid)    from public, anon, authenticated;
revoke execute on function public.fill_courts(uuid)          from public, anon, authenticated;
revoke execute on function public.set_notification_pref(text, boolean) from public, anon;
grant  execute on function public.set_notification_pref(text, boolean) to authenticated;
