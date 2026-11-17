-- =====================================================================
-- 알림: 앱 안 알림함 + 웹 푸시
--   종류                대상                 시점
--   join_request       동아리 운영진          가입 신청이 들어왔을 때
--   join_approved      신청한 본인            가입이 승인됐을 때
--   vote_created       동아리 회원 전체        운동(투표)이 생겼을 때 (정기운동 자동 생성·번개·자체대회)
--   vote_soon          동아리 회원 전체        투표 오픈 10분 전 (매분 도는 예약 작업)
--   court_assigned     그 경기의 회원 선수     경기가 코트에 들어갔을 때 (자율·대회 모두)
--
--   흐름: 이벤트 → notifications 행 추가(앱 안 알림함) → pg_net으로 Edge Function(send-push) 호출 → 웹 푸시
--   pg_net·Vault·pg_cron이 없는 환경(로컬 테스트)에서는 알림함만 쌓이고 푸시 호출은 건너뛴다.
--   설정(Vault 비밀값): push_function_url, push_secret, vapid_public_key  → README '알림 설정' 참고
-- =====================================================================

-- ---------------------------------------------------------------------
-- 테이블
-- ---------------------------------------------------------------------
create table public.notifications (
  id               bigint generated always as identity primary key,
  user_id          uuid not null references public.profiles(id) on delete cascade,
  club_id          uuid references public.clubs(id) on delete cascade,
  session_id       uuid references public.sessions(id) on delete cascade,
  kind             text not null check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned')),
  title            text not null,
  body             text not null,
  url              text not null,              -- 앱 안 경로 (BASE_URL 뒤에 붙는다)
  created_at       timestamptz not null default now(),
  read_at          timestamptz,
  push_claimed_at  timestamptz,                -- 보내는 중 (동시에 두 번 보내지 않게)
  pushed_at        timestamptz,                -- 보냄 (구독이 없어도 처리 완료로 표시)
  push_error       text
);
create index notifications_user_created_idx on public.notifications (user_id, created_at desc);
create index notifications_unpushed_idx on public.notifications (id) where pushed_at is null;

create table public.push_subscriptions (
  id           uuid primary key default gen_random_uuid(),
  user_id      uuid not null references public.profiles(id) on delete cascade,
  endpoint     text not null unique,
  p256dh       text not null,
  auth         text not null,
  user_agent   text,
  created_at   timestamptz not null default now(),
  last_ok_at   timestamptz
);
create index push_subscriptions_user_idx on public.push_subscriptions (user_id);

-- 끈 알림 종류 (없으면 받음)
create table public.notification_mutes (
  user_id  uuid not null references public.profiles(id) on delete cascade,
  kind     text not null check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned')),
  primary key (user_id, kind)
);

alter table public.sessions add column vote_soon_notified_at timestamptz;

alter table public.notifications enable row level security;
alter table public.push_subscriptions enable row level security;
alter table public.notification_mutes enable row level security;

create policy notifications_select_own on public.notifications for select to authenticated using (user_id = auth.uid());
create policy push_subscriptions_select_own on public.push_subscriptions for select to authenticated using (user_id = auth.uid());
create policy notification_mutes_select_own on public.notification_mutes for select to authenticated using (user_id = auth.uid());

-- ---------------------------------------------------------------------
-- 푸시 보내기 호출 (pg_net). 실패해도 원래 작업은 막지 않는다
-- ---------------------------------------------------------------------
create or replace function public.vault_secret(p_name text)
returns text
language plpgsql stable security definer set search_path = ''
as $$
declare
  v text;
begin
  if to_regclass('vault.decrypted_secrets') is null then
    return null;
  end if;
  execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1' into v using p_name;
  return v;
exception when others then
  return null;
end;
$$;

create or replace function public.kick_push()
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_url    text := public.vault_secret('push_function_url');
  v_secret text := public.vault_secret('push_secret');
begin
  if v_url is null or v_secret is null or to_regproc('net.http_post') is null then
    return;
  end if;
  execute 'select net.http_post(url := $1, body := ''{}''::jsonb, headers := $2, timeout_milliseconds := 10000)'
    using v_url, jsonb_build_object('Content-Type', 'application/json', 'x-push-secret', v_secret);
exception when others then
  raise warning 'kick_push failed: %', sqlerrm;
end;
$$;

-- 알림이 쌓이면 문장 단위로 한 번만 호출 (회원 30명에게 보내도 호출은 1번)
create or replace function public.notifications_after_insert()
returns trigger
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.kick_push();
  return null;
end;
$$;
create trigger notifications_kick_push
  after insert on public.notifications
  for each statement execute function public.notifications_after_insert();

-- ---------------------------------------------------------------------
-- 알림 만들기
-- ---------------------------------------------------------------------
-- 한 사람에게 (끈 종류면 만들지 않음)
create or replace function public.notify(p_user uuid, p_club uuid, p_session uuid, p_kind text, p_title text, p_body text, p_url text)
returns void
language sql security definer set search_path = ''
as $$
  insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
  select p_user, p_club, p_session, p_kind, p_title, p_body, p_url
   where not exists (select 1 from public.notification_mutes where user_id = p_user and kind = p_kind);
$$;

-- '11/20(수) 19:00' 형식 (동아리 시간대)
create or replace function public.fmt_when(p_at timestamptz, p_tz text)
returns text
language sql stable set search_path = ''
as $$
  select to_char(p_at at time zone p_tz, 'FMMM/FMDD') || '(' ||
         (array['일','월','화','수','목','금','토'])[extract(dow from p_at at time zone p_tz)::int + 1] || ') ' ||
         to_char(p_at at time zone p_tz, 'HH24:MI');
$$;

-- 가입 신청 → 운영진 / 가입 승인 → 본인
create or replace function public.club_members_notify()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  v_club text;
  v_name text;
begin
  begin
    select name into v_club from public.clubs where id = new.club_id;
    select display_name into v_name from public.profiles where id = new.user_id;

    if new.status = 'pending' and (tg_op = 'INSERT' or old.status is distinct from 'pending') then
      insert into public.notifications (user_id, club_id, kind, title, body, url)
      select m.user_id, new.club_id, 'join_request', '가입 신청',
             coalesce(v_name, '누군가') || '님이 ' || v_club || '에 가입을 신청했어요',
             '/c/' || new.club_id || '/admin/members'
        from public.club_members m
       where m.club_id = new.club_id and m.role = 'admin' and m.status = 'approved'
         and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'join_request');
    end if;

    if tg_op = 'UPDATE' and new.status = 'approved' and old.status = 'pending' then
      perform public.notify(new.user_id, new.club_id, null, 'join_approved', '가입 승인',
        v_club || ' 가입이 승인됐어요. 이제 운동 투표에 참여할 수 있어요', '/c/' || new.club_id);
    end if;
  exception when others then
    -- 알림 때문에 원래 작업(가입·운동 생성·코트 배정)이 실패하면 안 된다
    raise warning 'club_members_notify failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger club_members_notify
  after insert or update of status on public.club_members
  for each row execute function public.club_members_notify();

-- 운동(투표) 생김 → 동아리 회원 전체 (번개·자체대회를 연 사람 제외)
create or replace function public.sessions_notify_created()
returns trigger
language plpgsql security definer set search_path = ''
as $$
declare
  c       public.clubs%rowtype;
  v_tz    text;
  v_label text;
  v_body  text;
begin
  begin
    if new.canceled_at is not null or new.ends_at <= now() then
      return null;
    end if;
    select * into c from public.clubs where id = new.club_id;
    v_tz := coalesce(c.timezone, 'Asia/Seoul');
    v_label := case when new.kind = 'tournament' then '자체대회' when new.type = 'flash' then '번개' else '운동' end;
    v_body := new.title || ', ' || public.fmt_when(new.starts_at, v_tz) ||
              case when new.opens_at <= now() then '. 지금 투표 중이에요'
                   else '. 투표는 ' || public.fmt_when(new.opens_at, v_tz) || '에 열려요' end;

    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, new.club_id, new.id, 'vote_created', c.name || ' 새 ' || v_label, v_body,
           '/c/' || new.club_id || '/s/' || new.id
      from public.club_members m
     where m.club_id = new.club_id and m.status = 'approved'
       -- 번개·자체대회를 연 사람은 빼고, 정기운동(자동 생성, host 없음)은 모두에게
       and m.user_id is distinct from new.host_user_id
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_created');
  exception when others then
    -- 알림 때문에 원래 작업(가입·운동 생성·코트 배정)이 실패하면 안 된다
    raise warning 'sessions_notify_created failed: %', sqlerrm;
  end;
  return null;
end;
$$;
create trigger sessions_notify_created
  after insert on public.sessions
  for each row execute function public.sessions_notify_created();

-- 투표 오픈 10분 전 → 동아리 회원 전체. 매분 실행, 세션마다 한 번만 (vote_soon_notified_at)
create or replace function public.enqueue_vote_soon()
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s       record;
  v_count int := 0;
begin
  for s in
    update public.sessions x
       set vote_soon_notified_at = now()
     where x.vote_soon_notified_at is null and x.canceled_at is null
       and x.opens_at > now() and x.opens_at <= now() + interval '10 minutes'
    returning x.id, x.club_id, x.title, x.opens_at, x.starts_at
  loop
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, s.club_id, s.id, 'vote_soon',
           ceil(extract(epoch from (s.opens_at - now())) / 60)::int || '분 뒤 투표 오픈',
           s.title || ' (' || public.fmt_when(s.starts_at, coalesce(c.timezone, 'Asia/Seoul')) || ') 투표가 ' ||
             to_char(s.opens_at at time zone coalesce(c.timezone, 'Asia/Seoul'), 'HH24:MI') || '에 열려요. 선착순이에요',
           '/c/' || s.club_id || '/s/' || s.id
      from public.club_members m
      join public.clubs c on c.id = m.club_id
     where m.club_id = s.club_id and m.status = 'approved'
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_soon');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$$;

-- 경기가 코트에 들어감 → 그 경기의 회원 선수
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
               case when new.phase = 'scheduled' then ' (매치 ' || new.round_no || ' · ' || new.order_no || '경기)' else '' end;
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
    -- 알림 때문에 원래 작업(가입·운동 생성·코트 배정)이 실패하면 안 된다
    raise warning 'matches_notify_court failed: %', sqlerrm;
  end;
  return null;
end;
$$;
-- 자율 경기는 match_players를 넣은 뒤 fill_courts가 playing으로 바꾸므로 UPDATE에서 잡힌다
create trigger matches_notify_court
  after insert or update of status on public.matches
  for each row execute function public.matches_notify_court();

-- ---------------------------------------------------------------------
-- 화면용 RPC
-- ---------------------------------------------------------------------
-- 웹 푸시 공개 키 (Vault에 저장한 vapid_public_key). 없으면 null → 화면에서 '알림 서버 준비 전'
create or replace function public.push_public_key()
returns text
language sql stable security definer set search_path = ''
as $$ select public.vault_secret('vapid_public_key'); $$;

create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text, p_user_agent text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_endpoint !~ '^https://' or char_length(p_endpoint) > 1000 or coalesce(p_p256dh, '') = '' or coalesce(p_auth, '') = '' then
    raise exception 'invalid_subscription' using errcode = '22023';
  end if;
  -- 같은 기기(엔드포인트)를 다른 계정으로 쓰면 마지막 로그인 계정으로 옮긴다
  insert into public.push_subscriptions (user_id, endpoint, p256dh, auth, user_agent)
  values (auth.uid(), p_endpoint, p_p256dh, p_auth, left(p_user_agent, 300))
  on conflict (endpoint) do update
    set user_id = excluded.user_id, p256dh = excluded.p256dh, auth = excluded.auth,
        user_agent = excluded.user_agent, created_at = now();
end;
$$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language sql security definer set search_path = ''
as $$ delete from public.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid(); $$;

create or replace function public.set_notification_pref(p_kind text, p_enabled boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if p_kind not in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned') then
    raise exception 'invalid_kind' using errcode = '22023';
  end if;
  if p_enabled then
    delete from public.notification_mutes where user_id = auth.uid() and kind = p_kind;
  else
    insert into public.notification_mutes (user_id, kind) values (auth.uid(), p_kind) on conflict do nothing;
  end if;
end;
$$;

-- 읽음 표시 (null이면 전부)
create or replace function public.mark_notifications_read(p_ids bigint[])
returns void
language sql security definer set search_path = ''
as $$
  update public.notifications set read_at = now()
   where user_id = auth.uid() and read_at is null and (p_ids is null or id = any(p_ids));
$$;

-- ---------------------------------------------------------------------
-- Edge Function(send-push)용: 서비스 키로만 호출
-- ---------------------------------------------------------------------
-- 보낼 알림을 가져가며 '보내는 중' 표시. 2분 넘게 끝나지 않은 건 다시 가져간다
create or replace function public.claim_push_batch(p_limit int)
returns table (id bigint, user_id uuid, title text, body text, url text, kind text, session_id uuid)
language sql security definer set search_path = ''
as $$
  update public.notifications n
     set push_claimed_at = now()
   where n.id in (
     select x.id from public.notifications x
      where x.pushed_at is null
        and (x.push_claimed_at is null or x.push_claimed_at < now() - interval '2 minutes')
        and x.created_at > now() - interval '1 day'          -- 하루 넘게 못 보낸 건 포기 (알림함에는 남음)
      order by x.id
      limit p_limit
      for update skip locked)
  returning n.id, n.user_id, n.title, n.body, n.url, n.kind, n.session_id;
$$;

create or replace function public.finish_push(p_ids bigint[], p_error text)
returns void
language sql security definer set search_path = ''
as $$ update public.notifications set pushed_at = now(), push_error = p_error where id = any(p_ids); $$;

-- ---------------------------------------------------------------------
-- 예약 작업: 매분 투표 10분 전 알림 + 못 보낸 푸시 다시 보내기
-- ---------------------------------------------------------------------
create or replace function public.notifications_tick()
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  perform public.enqueue_vote_soon();
  if exists (select 1 from public.notifications where pushed_at is null and created_at > now() - interval '1 day') then
    perform public.kick_push();
  end if;
end;
$$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('notifications-tick', '* * * * *', 'select public.notifications_tick()');
  else
    raise notice 'pg_cron not installed: notifications-tick not scheduled';
  end if;
end $$;

-- 알림함 실시간 (내 알림만: RLS)
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 권한
-- ---------------------------------------------------------------------
revoke execute on function public.vault_secret(text)                                   from public, anon, authenticated;
revoke execute on function public.kick_push()                                          from public, anon, authenticated;
revoke execute on function public.notifications_after_insert()                         from public, anon, authenticated;
revoke execute on function public.notify(uuid, uuid, uuid, text, text, text, text)     from public, anon, authenticated;
revoke execute on function public.fmt_when(timestamptz, text)                          from public, anon, authenticated;
revoke execute on function public.club_members_notify()                                from public, anon, authenticated;
revoke execute on function public.sessions_notify_created()                            from public, anon, authenticated;
revoke execute on function public.enqueue_vote_soon()                                  from public, anon, authenticated;
revoke execute on function public.matches_notify_court()                               from public, anon, authenticated;
revoke execute on function public.notifications_tick()                                 from public, anon, authenticated;
revoke execute on function public.claim_push_batch(int)                                from public, anon, authenticated;
revoke execute on function public.finish_push(bigint[], text)                          from public, anon, authenticated;
revoke execute on function public.push_public_key()                                    from public, anon, authenticated;
revoke execute on function public.save_push_subscription(text, text, text, text)       from public, anon, authenticated;
revoke execute on function public.delete_push_subscription(text)                       from public, anon, authenticated;
revoke execute on function public.set_notification_pref(text, boolean)                 from public, anon, authenticated;
revoke execute on function public.mark_notifications_read(bigint[])                    from public, anon, authenticated;

grant execute on function public.push_public_key()                                     to authenticated;
grant execute on function public.save_push_subscription(text, text, text, text)        to authenticated;
grant execute on function public.delete_push_subscription(text)                        to authenticated;
grant execute on function public.set_notification_pref(text, boolean)                  to authenticated;
grant execute on function public.mark_notifications_read(bigint[])                     to authenticated;
do $$
begin
  if exists (select 1 from pg_roles where rolname = 'service_role') then
    grant execute on function public.claim_push_batch(int) to service_role;
    grant execute on function public.finish_push(bigint[], text) to service_role;
    grant select, delete, update on public.push_subscriptions to service_role;
  end if;
end $$;
