-- =====================================================================
-- 1) 고정 참석자 (정기운동)
--   - 정기운동 설정에 고정 참석자 명단(fixed_user_ids). 그 정기운동으로 일정이 만들어질 때
--     투표를 기다리지 않고 바로 참석 신청된다 (정원에 포함, 넘치면 대기)
--   - 명단을 바꾸면 이미 만들어진 시작 전 일정에도 반영: 빠진 사람의 '고정' 신청은 취소(대기자 승격),
--     새로 들어온 사람은 신청. 스스로 취소한 적이 있는 일정에는 다시 넣지 않는다
--   - 고정 참석자도 본인이 직접 취소할 수 있다. 신청 표시는 registrations.is_fixed
--   - 이미 신청된 사람에게는 '투표 곧 오픈' 알림을 보내지 않는다
-- 2) 초대 링크
--   - 동아리마다 링크 하나(club_invites, 운영진만 볼 수 있다). 링크로 들어오면 승인 없이 바로 가입
--   - 재발급하면 예전 링크는 바로 무효, 끄면 링크 가입 불가. 강퇴된 사람은 링크로도 못 들어온다
--   - 링크로 가입하면 운영진에게 알림 (가입 신청 알림과 같은 종류: 끄면 같이 꺼진다)
-- 되돌리기: supabase/rollback/20261121000000_fixed_and_invite_down.sql
-- =====================================================================

-- ── 1) 고정 참석자 ─────────────────────────────────────────────────
alter table public.session_templates add column fixed_user_ids uuid[] not null default '{}';
alter table public.registrations add column is_fixed boolean not null default false;

-- 내부: 그 일정의 정기운동 고정 참석자를 신청시킨다. 신청 건수
create or replace function public.apply_fixed_members(p_session uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  s       public.sessions%rowtype;
  v_fixed uuid[];
  v_uid   uuid;
  v_n     int := 0;
  v_st    public.registration_status;
begin
  select * into s from public.sessions where id = p_session;
  if not found or s.template_id is null or s.canceled_at is not null or s.starts_at <= now() then
    return 0;
  end if;
  select fixed_user_ids into v_fixed from public.session_templates where id = s.template_id;
  foreach v_uid in array coalesce(v_fixed, '{}') loop
    continue when not exists (select 1 from public.club_members m
                               where m.club_id = s.club_id and m.user_id = v_uid and m.status = 'approved');
    -- 이미 신청했거나, 이 일정에서 취소한 적이 있으면 건드리지 않는다
    continue when exists (select 1 from public.registrations r
                           where r.session_id = p_session and r.user_id = v_uid and r.kind = 'member');
    v_st := case when public.capacity_used(p_session) < s.capacity
                 then 'confirmed'::public.registration_status else 'waitlisted'::public.registration_status end;
    insert into public.registrations (session_id, kind, user_id, added_by, status, is_fixed)
    values (p_session, 'member', v_uid, null, v_st, true);
    v_n := v_n + 1;
  end loop;
  if v_n > 0 then
    perform public.log_activity(s.club_id, p_session, 'registration.fixed', jsonb_build_object('count', v_n));
  end if;
  return v_n;
end;
$$;
revoke execute on function public.apply_fixed_members(uuid) from public, anon, authenticated;

create or replace function public.generate_template_sessions(p_template uuid)
returns int
language plpgsql security definer set search_path = ''
as $$
declare
  t        public.session_templates%rowtype;
  v_tz     text;
  v_today  date;
  d        date;
  v_start  timestamptz;
  v_end    timestamptz;
  v_open   timestamptz;
  v_made   int := 0;
  v_sid    uuid;
begin
  select * into t from public.session_templates where id = p_template and active;
  if not found then
    return 0;
  end if;
  select timezone into v_tz from public.clubs where id = t.club_id;

  v_today := (now() at time zone v_tz)::date;

  for d in
    select g::date from generate_series(v_today, v_today + t.open_days_before + 7, interval '1 day') g
  loop
    continue when extract(dow from d)::int <> t.weekday;

    v_start := (d + t.start_time) at time zone v_tz;
    v_end   := (d + t.end_time)   at time zone v_tz;
    v_open  := ((d - t.open_days_before) + t.open_time) at time zone v_tz;
    if v_open > v_start then
      v_open := v_start;
    end if;

    continue when v_start <= now();                       -- 지난 운동
    continue when v_open > now() + interval '7 days';     -- 아직 너무 먼 운동

    insert into public.sessions
      (club_id, template_id, template_slot, type, title, place,
       starts_at, ends_at, capacity, court_count, opens_at, guests_in_capacity)
    values
      (t.club_id, t.id, v_start, 'regular', t.title, t.place,
       v_start, v_end, t.capacity, t.court_count, v_open, t.guests_in_capacity)
    on conflict (template_id, template_slot) do nothing
    returning id into v_sid;

    if v_sid is not null then
      v_made := v_made + 1;
      perform public.apply_fixed_members(v_sid);   -- 고정 참석자 자동 신청
      v_sid := null;
    end if;
  end loop;

  return v_made;
end;
$$;

drop function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean);
create function public.save_template(
  p_club             uuid,
  p_id               uuid,
  p_title            text,
  p_weekday          smallint,
  p_start_time       time,
  p_end_time         time,
  p_place            text,
  p_capacity         int,
  p_court_count      int,
  p_open_days_before int,
  p_open_time        time,
  p_active           boolean default true,
  p_guests_in_capacity boolean default false,
  p_fixed            uuid[] default null      -- null = 고정 참석자 그대로
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id     uuid;
  v_old    uuid[] := '{}';
  v_fixed  uuid[];
  v_sess   record;
  v_reg    record;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_end_time <= p_start_time then
    raise exception 'invalid_time' using errcode = '22023';
  end if;
  if p_fixed is not null then
    -- 중복 제거(처음 순서 유지), 이 동아리 승인 회원만
    select coalesce(array_agg(u order by ord), '{}') into v_fixed
      from (select u, min(ord) ord from unnest(p_fixed) with ordinality as x(u, ord) group by u) d;
    if exists (select 1 from unnest(v_fixed) u
                where not exists (select 1 from public.club_members m
                                   where m.club_id = p_club and m.user_id = u and m.status = 'approved')) then
      raise exception 'not_member' using errcode = '22023';
    end if;
    if cardinality(v_fixed) > p_capacity then
      raise exception 'fixed_over_capacity' using errcode = '22023';
    end if;
  end if;
  if p_id is not null then
    select fixed_user_ids into v_old from public.session_templates where id = p_id and club_id = p_club;
  end if;

  if p_id is null then
    insert into public.session_templates
      (club_id, title, weekday, start_time, end_time, place, capacity, court_count,
       open_days_before, open_time, active, guests_in_capacity, fixed_user_ids)
    values
      (p_club, btrim(p_title), p_weekday, p_start_time, p_end_time, coalesce(btrim(p_place), ''),
       p_capacity, p_court_count, p_open_days_before, p_open_time, coalesce(p_active, true),
       coalesce(p_guests_in_capacity, false), coalesce(v_fixed, '{}'))
    returning id into v_id;
  else
    update public.session_templates
       set title = btrim(p_title), weekday = p_weekday, start_time = p_start_time, end_time = p_end_time,
           place = coalesce(btrim(p_place), ''), capacity = p_capacity, court_count = p_court_count,
           open_days_before = p_open_days_before, open_time = p_open_time,
           active = coalesce(p_active, true), guests_in_capacity = coalesce(p_guests_in_capacity, false),
           fixed_user_ids = coalesce(v_fixed, fixed_user_ids)
     where id = p_id and club_id = p_club
    returning id into v_id;
    if v_id is null then
      raise exception 'template_not_found' using errcode = 'P0002';
    end if;
  end if;

  perform public.log_activity(p_club, null, case when p_id is null then 'template.create' else 'template.update' end,
    jsonb_build_object('template_id', v_id, 'fixed', v_fixed));

  -- 고정 참석자 명단이 바뀌면 이미 만들어진(시작 전) 일정에도 반영
  if v_fixed is not null and p_id is not null and v_fixed is distinct from v_old then
    for v_sess in
      select id from public.sessions
       where template_id = v_id and canceled_at is null and starts_at > now()
       order by id
    loop
      perform 1 from public.sessions where id = v_sess.id for update;
      -- 빠진 사람: 고정으로 들어간 신청만 취소 (스스로 신청한 건 그대로)
      for v_reg in
        select r.id, r.status from public.registrations r
         where r.session_id = v_sess.id and r.is_fixed and r.status in ('confirmed', 'waitlisted')
           and not (r.user_id = any (v_fixed))
      loop
        update public.registrations set status = 'canceled', canceled_at = now() where id = v_reg.id;
      end loop;
      perform public.promote_waitlist(v_sess.id, 0);
      -- 새로 들어온 사람: 신청
      perform public.apply_fixed_members(v_sess.id);
    end loop;
  end if;

  perform public.generate_template_sessions(v_id);
  return v_id;
end;
$$;
revoke execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean, uuid[]) from public, anon;
grant execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean, uuid[]) to authenticated;

CREATE OR REPLACE FUNCTION public.enqueue_vote_soon()
 RETURNS integer
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  s       record;
  v_count int := 0;
begin
  for s in
    update public.sessions x
       set vote_soon_notified_at = now()
     where x.vote_soon_notified_at is null and x.canceled_at is null
       and x.opens_at > now() and x.opens_at <= now() + interval '10 minutes'
    returning x.id, x.club_id, x.title, x.opens_at, x.starts_at,
              case when x.kind = 'exchange' and x.partner_status = 'accepted' then x.partner_club_id end as partner_club_id
  loop
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, m.club_id, s.id, 'vote_soon',
           ceil(extract(epoch from (s.opens_at - now())) / 60)::int || '분 뒤 투표 오픈',
           s.title || ' (' || public.fmt_when(s.starts_at, coalesce(c.timezone, 'Asia/Seoul')) || ') 투표가 ' ||
             to_char(s.opens_at at time zone coalesce(c.timezone, 'Asia/Seoul'), 'HH24:MI') || '에 열려요. 선착순이에요',
           '/c/' || m.club_id || '/s/' || s.id
      from public.club_members m
      join public.clubs c on c.id = m.club_id
     where m.club_id in (s.club_id, s.partner_club_id) and m.status = 'approved'
       -- 두 동아리 모두 회원이면 주최 쪽으로 한 번만
       and not coalesce(m.club_id = s.partner_club_id
                and exists (select 1 from public.club_members h where h.club_id = s.club_id and h.user_id = m.user_id and h.status = 'approved'), false)
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_soon')
       -- 이미 신청돼 있는 사람(고정 참석자 등)은 알릴 필요 없다
       and not exists (select 1 from public.registrations r
                        where r.session_id = s.id and r.user_id = m.user_id and r.kind = 'member' and r.status <> 'canceled');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

-- ── 2) 초대 링크 ───────────────────────────────────────────────────
create table public.club_invites (
  club_id    uuid primary key references public.clubs(id) on delete cascade,
  token      text not null unique check (char_length(token) between 16 and 64),
  created_at timestamptz not null default now(),
  created_by uuid references public.profiles(id) on delete set null
);
alter table public.club_invites enable row level security;   -- 정책 없음: 함수로만
revoke all on public.club_invites from anon, authenticated;

-- 운영진: 지금 링크 토큰 (없으면 null)
create or replace function public.get_invite(p_club uuid)
returns text
language plpgsql stable security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  return (select token from public.club_invites where club_id = p_club);
end;
$$;

-- 운영진: 링크 만들기 / 재발급 (예전 링크는 바로 무효)
create or replace function public.reset_invite(p_club uuid)
returns text
language plpgsql security definer set search_path = ''
as $$
declare
  v_token text := replace(gen_random_uuid()::text, '-', '') || substr(replace(gen_random_uuid()::text, '-', ''), 1, 8);
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  insert into public.club_invites (club_id, token, created_by) values (p_club, v_token, auth.uid())
  on conflict (club_id) do update set token = excluded.token, created_at = now(), created_by = excluded.created_by;
  perform public.log_activity(p_club, null, 'invite.reset', '{}'::jsonb);
  return v_token;
end;
$$;

-- 운영진: 링크 끄기
create or replace function public.disable_invite(p_club uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.club_invites where club_id = p_club;
  perform public.log_activity(p_club, null, 'invite.disable', '{}'::jsonb);
end;
$$;

-- 링크를 연 사람: 어떤 동아리인지, 내 상태 (가입 전 확인 화면)
create or replace function public.invite_info(p_token text)
returns table (club_id uuid, name text, logo_path text, my_status text, banned boolean)
language sql stable security definer set search_path = ''
as $$
  select c.id, c.name, c.logo_path, m.status::text, m.banned_at is not null
    from public.club_invites i
    join public.clubs c on c.id = i.club_id
    left join public.club_members m on m.club_id = c.id and m.user_id = auth.uid()
   where i.token = p_token and auth.uid() is not null
$$;

-- 링크로 가입: 승인 없이 바로 회원. 동아리 id
create or replace function public.join_by_invite(p_token text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_club uuid;
  v_name text;
  v_cn   text;
  m      public.club_members%rowtype;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  select i.club_id into v_club from public.club_invites i where i.token = p_token;
  if v_club is null then
    raise exception 'invite_invalid' using errcode = 'P0002';
  end if;

  select * into m from public.club_members where club_id = v_club and user_id = v_uid for update;
  if found and m.banned_at is not null then
    raise exception 'banned' using errcode = '42501';
  end if;
  if found and m.status = 'approved' then
    return v_club;                                   -- 이미 회원
  end if;

  insert into public.club_members (club_id, user_id, role, status, requested_at, decided_at, decided_by)
  values (v_club, v_uid, 'member', 'approved', now(), now(), null)
  on conflict (club_id, user_id) do update
    set status = 'approved', role = 'member', requested_at = now(), decided_at = now(), decided_by = null;

  perform public.log_activity(v_club, null, 'member.join_invite', '{}'::jsonb);

  -- 운영진에게 알림 (가입 신청 알림을 끈 운영진은 제외)
  begin
    select display_name into v_name from public.profiles where id = v_uid;
    select name into v_cn from public.clubs where id = v_club;
    insert into public.notifications (user_id, club_id, kind, title, body, url)
    select a.user_id, v_club, 'join_request', '새 회원',
           coalesce(v_name, '누군가') || '님이 초대 링크로 ' || v_cn || '에 가입했어요',
           '/c/' || v_club || '/admin/members'
      from public.club_members a
     where a.club_id = v_club and a.role = 'admin' and a.status = 'approved'
       and not exists (select 1 from public.notification_mutes x where x.user_id = a.user_id and x.kind = 'join_request');
  exception when others then
    raise warning 'join_by_invite notify failed: %', sqlerrm;
  end;
  return v_club;
end;
$$;

revoke execute on function public.get_invite(uuid)        from public, anon;
revoke execute on function public.reset_invite(uuid)      from public, anon;
revoke execute on function public.disable_invite(uuid)    from public, anon;
revoke execute on function public.invite_info(text)       from public, anon;
revoke execute on function public.join_by_invite(text)    from public, anon;
grant execute on function public.get_invite(uuid)         to authenticated;
grant execute on function public.reset_invite(uuid)       to authenticated;
grant execute on function public.disable_invite(uuid)     to authenticated;
grant execute on function public.invite_info(text)        to authenticated;
grant execute on function public.join_by_invite(text)     to authenticated;
