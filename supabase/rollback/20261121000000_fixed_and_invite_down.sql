-- 20261121000000_fixed_and_invite.sql 되돌리기
-- 순서: 앱 커밋을 먼저 revert하고 배포한 뒤 이 SQL을 실행
--   (앱이 save_template에 p_fixed를 보내고 registrations.is_fixed를 읽기 때문)
-- 고정으로 들어간 신청은 일반 신청으로 남는다

drop function public.join_by_invite(text);
drop function public.invite_info(text);
drop function public.disable_invite(uuid);
drop function public.reset_invite(uuid);
drop function public.get_invite(uuid);
drop table public.club_invites;

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
       and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_soon');
    v_count := v_count + 1;
  end loop;
  return v_count;
end;
$function$;

drop function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean, uuid[]);
create or replace function public.save_template(
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
  p_guests_in_capacity boolean default false
)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_id uuid;
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_end_time <= p_start_time then
    raise exception 'invalid_time' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.session_templates
      (club_id, title, weekday, start_time, end_time, place, capacity, court_count,
       open_days_before, open_time, active, guests_in_capacity)
    values
      (p_club, btrim(p_title), p_weekday, p_start_time, p_end_time, coalesce(btrim(p_place), ''),
       p_capacity, p_court_count, p_open_days_before, p_open_time, coalesce(p_active, true),
       coalesce(p_guests_in_capacity, false))
    returning id into v_id;
  else
    update public.session_templates
       set title = btrim(p_title), weekday = p_weekday, start_time = p_start_time, end_time = p_end_time,
           place = coalesce(btrim(p_place), ''), capacity = p_capacity, court_count = p_court_count,
           open_days_before = p_open_days_before, open_time = p_open_time,
           active = coalesce(p_active, true), guests_in_capacity = coalesce(p_guests_in_capacity, false)
     where id = p_id and club_id = p_club
    returning id into v_id;
    if v_id is null then
      raise exception 'template_not_found' using errcode = 'P0002';
    end if;
  end if;

  perform public.log_activity(p_club, null, case when p_id is null then 'template.create' else 'template.update' end,
    jsonb_build_object('template_id', v_id));
  perform public.generate_template_sessions(v_id);
  return v_id;
end;
$$;
revoke execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean) from public, anon, authenticated;
grant execute on function public.save_template(uuid, uuid, text, smallint, time, time, text, int, int, int, time, boolean, boolean) to authenticated;

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
    on conflict (template_id, template_slot) do nothing;

    if found then
      v_made := v_made + 1;
    end if;
  end loop;

  return v_made;
end;
$$;

drop function public.apply_fixed_members(uuid);
alter table public.registrations drop column is_fixed;
alter table public.session_templates drop column fixed_user_ids;
