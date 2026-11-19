-- =====================================================================
-- 점검 정리
--   1) 대진판(현장) 게스트도 급수를 넣을 수 있다 — 투표·명단 관리 게스트와 같게
--   2) josa(): 이름 받침에 맞춰 조사를 붙인다 ("죽전 셔틀콕이", "FLY가")
--      교류전 알림의 "이(가)", "와(과)"와 "'교류전' 교류전" 중복을 정리
-- 되돌리기: supabase/rollback/20261119060000_cleanup_down.sql
-- =====================================================================

-- 받침이 있으면 a, 없으면 b를 붙여 돌려준다. 한글이 아니면 숫자는 읽는 소리로, 나머지는 b
create or replace function public.josa(p_word text, p_a text, p_b text)
returns text
language sql immutable set search_path = ''
as $$
  select p_word || case
    when p_word is null or p_word = '' then p_b
    when ascii(right(p_word, 1)) between 44032 and 55203
      then case when (ascii(right(p_word, 1)) - 44032) % 28 <> 0 then p_a else p_b end
    when right(p_word, 1) in ('0', '1', '3', '6', '7', '8') then p_a
    else p_b
  end
$$;
revoke execute on function public.josa(text, text, text) from public, anon;
grant execute on function public.josa(text, text, text) to authenticated;

-- 대진판(현장) 게스트: 급수 추가 (바로 확정·도착 처리는 그대로, 정원과 상관없음)
drop function public.add_guest(uuid, text, text);
create function public.add_guest(p_session uuid, p_name text, p_gender text default null, p_level text default null)
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
  if p_level is not null and p_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;
  v_club := public.lock_board(p_session);
  select kind into v_kind from public.sessions where id = p_session;
  v_side := coalesce(public.side_of_user(p_session, auth.uid()), v_club);

  insert into public.registrations (session_id, kind, guest_name, guest_gender, guest_level, added_by, status, checked_in_at, side_club_id)
  values (p_session, 'guest', left(btrim(p_name), 30), p_gender, p_level, auth.uid(), 'confirmed', now(),
          case when v_kind = 'exchange' then v_side end)
  returning id into v_id;

  perform public.log_activity(v_club, p_session, 'board.add_guest',
    jsonb_build_object('registration_id', v_id, 'name', left(btrim(p_name), 30), 'gender', p_gender, 'level', p_level));
  return v_id;
end;
$$;
revoke execute on function public.add_guest(uuid, text, text, text) from public, anon;
grant execute on function public.add_guest(uuid, text, text, text) to authenticated;

-- 교류전 수락·거절 알림 문장
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
             public.josa(v_host, '과', '와') || ' 교류전, ' || public.fmt_when(s.starts_at, v_tz) ||
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
           public.josa(v_guest, '이', '가') || ' ''' || s.title || ''' 초대를 ' || case when p_accept then '수락했어요' else '거절했어요' end,
           '/c/' || s.club_id || '/s/' || s.id
      from public.club_members m
     where m.club_id = s.club_id and m.role = 'admin' and m.status = 'approved';
  exception when others then
    raise warning 'exchange reply notify failed: %', sqlerrm;
  end;

  perform public.log_activity(s.club_id, s.id, case when p_accept then 'exchange.accept' else 'exchange.decline' end, '{}'::jsonb);
end;
$$;
