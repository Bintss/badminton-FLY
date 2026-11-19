-- 20261119060000_cleanup.sql 되돌리기
-- 순서: 앱 커밋을 먼저 revert하고 배포한 뒤 이 SQL을 실행 (앱이 add_guest에 p_level을 보내기 때문)
drop function public.add_guest(uuid, text, text, text);
create or replace function public.add_guest(p_session uuid, p_name text, p_gender text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_club uuid;
  v_kind text;
  v_side uuid;
  v_id   uuid;
begin
  if p_name is null or char_length(btrim(p_name)) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if p_gender is not null and p_gender not in ('M', 'F') then
    raise exception 'invalid_gender' using errcode = '22023';
  end if;
  v_club := public.lock_board(p_session);
  select kind into v_kind from public.sessions where id = p_session;
  v_side := coalesce(public.side_of_user(p_session, auth.uid()), v_club);

  insert into public.registrations (session_id, kind, guest_name, guest_gender, added_by, status, checked_in_at, side_club_id)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, auth.uid(), 'confirmed', now(),
          case when v_kind = 'exchange' then v_side end)
  returning id into v_id;

  perform public.log_activity(v_club, p_session, 'board.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'gender', p_gender));
  return v_id;
end;
$$;
revoke execute on function public.add_guest(uuid, text, text) from public, anon;
grant execute on function public.add_guest(uuid, text, text) to authenticated;

create or replace function public.respond_exchange(p_session uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  s        public.sessions%rowtype;
  v_host   text;
  v_guest  text;
  v_tz     text;
begin
  select * into s from public.sessions where id = p_session for update;
  if not found or s.kind <> 'exchange' or s.partner_club_id is null then
    raise exception 'session_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(s.partner_club_id) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if s.partner_status <> 'invited' or s.canceled_at is not null then
    raise exception 'not_invited' using errcode = 'P0001';
  end if;

  update public.sessions set partner_status = case when p_accept then 'accepted' else 'declined' end where id = p_session;
  select name into v_host from public.clubs where id = s.club_id;
  select name, coalesce(timezone, 'Asia/Seoul') into v_guest, v_tz from public.clubs where id = s.partner_club_id;

  begin
    if p_accept then
      insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
      select m.user_id, s.partner_club_id, s.id, 'vote_created', v_guest || ' 새 교류전',
             v_host || '와(과) 교류전, ' || public.fmt_when(s.starts_at, v_tz) ||
               case when s.opens_at <= now() then '. 지금 투표 중이에요'
                    else '. 투표는 ' || public.fmt_when(s.opens_at, v_tz) || '에 열려요' end,
             '/c/' || s.partner_club_id || '/s/' || s.id
        from public.club_members m
       where m.club_id = s.partner_club_id and m.status = 'approved' and m.user_id <> auth.uid()
         and not exists (select 1 from public.notification_mutes x where x.user_id = m.user_id and x.kind = 'vote_created');
    end if;
    insert into public.notifications (user_id, club_id, session_id, kind, title, body, url)
    select m.user_id, s.club_id, s.id, 'exchange_reply',
           case when p_accept then '교류전 수락' else '교류전 거절' end,
           v_guest || '이(가) ''' || s.title || ''' 교류전 초대를 ' || case when p_accept then '수락했어요' else '거절했어요' end,
           '/c/' || s.club_id || '/s/' || s.id
      from public.club_members m
     where m.club_id = s.club_id and m.role = 'admin' and m.status = 'approved';
  exception when others then
    raise warning 'exchange reply notify failed: %', sqlerrm;
  end;

  perform public.log_activity(s.club_id, s.id, case when p_accept then 'exchange.accept' else 'exchange.decline' end, '{}'::jsonb);
end;
$$;

drop function public.josa(text, text, text);
