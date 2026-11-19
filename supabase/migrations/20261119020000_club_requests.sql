-- =====================================================================
-- 동아리 만들기는 승인제: 서비스 관리자(platform_admins)만 승인한다
--
--   * 누구나 '동아리 개설 신청'(이름 + 한 줄 소개). 한 사람당 대기 중인 신청은 하나
--   * 서비스 관리자가 승인하면 동아리가 만들어지고 신청자가 첫 운영진이 된다
--   * 서비스 관리자는 신청 없이 바로 만들 수도 있다 (create_club)
--   * 알림: 신청 → 서비스 관리자(club_request), 승인·거절 → 신청자(club_decided)
--
--   서비스 관리자 지정은 앱에서 하지 않는다. SQL Editor에서 직접:
--     select id, email from auth.users order by created_at;      -- 내 id 확인
--     insert into public.platform_admins (user_id) values ('<내 id>');
-- =====================================================================

create table public.platform_admins (
  user_id    uuid primary key references auth.users(id) on delete cascade,
  created_at timestamptz not null default now()
);
alter table public.platform_admins enable row level security;
create policy platform_admins_select_own on public.platform_admins
  for select to authenticated using (user_id = auth.uid());

create or replace function public.is_platform_admin()
returns boolean
language sql stable security definer set search_path = ''
as $$
  select exists (select 1 from public.platform_admins where user_id = auth.uid());
$$;

create table public.club_requests (
  id             uuid primary key default gen_random_uuid(),
  requested_by   uuid not null references public.profiles(id) on delete cascade,
  requester_name text not null,                          -- 신청 당시 이름 (관리자는 신청자 프로필을 못 볼 수 있어서)
  name           text not null check (char_length(name) between 1 and 50),
  note           text not null default '' check (char_length(note) <= 300),
  status         text not null default 'pending' check (status in ('pending', 'approved', 'rejected', 'canceled')),
  reason         text check (char_length(reason) <= 200),  -- 거절 이유 (선택)
  club_id        uuid references public.clubs(id) on delete set null,
  created_at     timestamptz not null default now(),
  decided_at     timestamptz,
  decided_by     uuid references auth.users(id) on delete set null
);
create unique index club_requests_one_pending on public.club_requests (requested_by) where status = 'pending';
create index club_requests_status_idx on public.club_requests (status, created_at desc);

alter table public.club_requests enable row level security;
create policy club_requests_select on public.club_requests
  for select to authenticated using (requested_by = auth.uid() or public.is_platform_admin());

revoke all on public.platform_admins from anon, authenticated;
revoke all on public.club_requests   from anon, authenticated;
grant select on public.platform_admins to authenticated;
grant select on public.club_requests   to authenticated;

-- 알림 종류 추가
alter table public.notifications drop constraint notifications_kind_check;
alter table public.notifications add constraint notifications_kind_check
  check (kind in ('join_request', 'join_approved', 'vote_created', 'vote_soon', 'court_assigned', 'court_next',
                  'club_request', 'club_decided'));

-- ---------------------------------------------------------------------
-- 내부: 동아리 만들고 만든 사람을 운영진으로
-- ---------------------------------------------------------------------
create or replace function public.make_club(p_name text, p_owner uuid)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_club uuid;
begin
  insert into public.clubs (name, created_by) values (btrim(p_name), p_owner) returning id into v_club;
  insert into public.club_members (club_id, user_id, role, status, decided_at, decided_by)
  values (v_club, p_owner, 'admin', 'approved', now(), coalesce(auth.uid(), p_owner))
  on conflict (club_id, user_id) do nothing;
  perform public.log_activity(v_club, null, 'club.create', jsonb_build_object('name', btrim(p_name), 'owner', p_owner));
  return v_club;
end;
$$;

-- 바로 만들기: 서비스 관리자만
create or replace function public.create_club(p_name text)
returns uuid
language plpgsql security definer set search_path = ''
as $$
begin
  if auth.uid() is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if not public.is_platform_admin() then
    raise exception 'club_needs_approval' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  return public.make_club(p_name, auth.uid());
end;
$$;

-- ---------------------------------------------------------------------
-- 개설 신청 / 신청 취소
-- ---------------------------------------------------------------------
create or replace function public.request_club(p_name text, p_note text default '')
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  v_uid  uuid := auth.uid();
  v_name text := left(btrim(coalesce(p_name, '')), 50);
  v_who  text;
  v_id   uuid;
begin
  if v_uid is null then
    raise exception 'not_authenticated' using errcode = '28000';
  end if;
  if char_length(v_name) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if exists (select 1 from public.club_requests where requested_by = v_uid and status = 'pending') then
    raise exception 'request_pending' using errcode = 'P0001';
  end if;
  select display_name into v_who from public.profiles where id = v_uid;

  insert into public.club_requests (requested_by, requester_name, name, note)
  values (v_uid, coalesce(v_who, '회원'), v_name, left(btrim(coalesce(p_note, '')), 300))
  returning id into v_id;

  -- 서비스 관리자에게 알림 (실패해도 신청은 진행)
  begin
    insert into public.notifications (user_id, kind, title, body, url)
    select a.user_id, 'club_request', '동아리 개설 신청',
           coalesce(v_who, '회원') || '님이 ''' || v_name || ''' 개설을 신청했어요', '/admin/clubs'
      from public.platform_admins a
     where a.user_id <> v_uid;
  exception when others then
    raise warning 'club_request notify failed: %', sqlerrm;
  end;
  return v_id;
end;
$$;

create or replace function public.cancel_club_request(p_id uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  update public.club_requests set status = 'canceled', decided_at = now()
   where id = p_id and requested_by = auth.uid() and status = 'pending';
  if not found then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;
end;
$$;

-- ---------------------------------------------------------------------
-- 승인 / 거절 (서비스 관리자). 승인하면 만든 동아리 id를 돌려준다
-- ---------------------------------------------------------------------
create or replace function public.decide_club_request(p_id uuid, p_approve boolean, p_reason text default null)
returns uuid
language plpgsql security definer set search_path = ''
as $$
declare
  r      public.club_requests%rowtype;
  v_club uuid;
begin
  if not public.is_platform_admin() then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  select * into r from public.club_requests where id = p_id for update;
  if not found or r.status <> 'pending' then
    raise exception 'request_not_found' using errcode = 'P0002';
  end if;

  if p_approve then
    v_club := public.make_club(r.name, r.requested_by);
    update public.club_requests
       set status = 'approved', club_id = v_club, decided_at = now(), decided_by = auth.uid()
     where id = p_id;
  else
    update public.club_requests
       set status = 'rejected', reason = nullif(left(btrim(coalesce(p_reason, '')), 200), ''),
           decided_at = now(), decided_by = auth.uid()
     where id = p_id;
  end if;

  begin
    insert into public.notifications (user_id, club_id, kind, title, body, url)
    values (r.requested_by, v_club, 'club_decided',
            case when p_approve then '동아리 개설 승인' else '동아리 개설 거절' end,
            case when p_approve then '''' || r.name || ''' 동아리가 만들어졌어요. 운영진으로 시작해 보세요'
                 else '''' || r.name || ''' 개설 신청이 거절됐어요' ||
                      coalesce('. ' || nullif(left(btrim(coalesce(p_reason, '')), 200), ''), '') end,
            case when p_approve then '/c/' || v_club else '/clubs' end);
  exception when others then
    raise warning 'club_decided notify failed: %', sqlerrm;
  end;
  return v_club;
end;
$$;

revoke execute on function public.make_club(text, uuid)                       from public, anon, authenticated;
revoke execute on function public.is_platform_admin()                         from public, anon;
revoke execute on function public.create_club(text)                           from public, anon;
revoke execute on function public.request_club(text, text)                    from public, anon;
revoke execute on function public.cancel_club_request(uuid)                   from public, anon;
revoke execute on function public.decide_club_request(uuid, boolean, text)    from public, anon;
grant execute on function public.is_platform_admin()                          to authenticated;
grant execute on function public.create_club(text)                            to authenticated;
grant execute on function public.request_club(text, text)                     to authenticated;
grant execute on function public.cancel_club_request(uuid)                    to authenticated;
grant execute on function public.decide_club_request(uuid, boolean, text)     to authenticated;
