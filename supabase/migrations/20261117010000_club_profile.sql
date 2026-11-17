-- =====================================================================
-- 동아리 정보: 소개글, 연락 링크, 로고, 운동 장소 목록
--   * 소개·로고·장소는 가입 전에도 볼 수 있다 (어느 동아리인지 알고 가입 신청하도록)
--   * 수정은 운영진만 (RPC)
--   * 로고 파일은 Supabase Storage 'club-logos' 버킷(공개 읽기)에 <club_id>/<파일명>으로 저장.
--     DB에는 경로만 저장하고 URL은 화면에서 만든다
-- =====================================================================

alter table public.clubs
  add column description text not null default '' check (char_length(description) <= 1000),
  add column link_url    text check (link_url is null or (char_length(link_url) <= 300 and link_url ~ '^https://')),
  add column logo_path   text check (logo_path is null or char_length(logo_path) <= 200);

create table public.club_places (
  id          uuid primary key default gen_random_uuid(),
  club_id     uuid not null references public.clubs(id) on delete cascade,
  name        text not null check (char_length(name) between 1 and 50),
  address     text not null default '' check (char_length(address) <= 200),
  note        text not null default '' check (char_length(note) <= 200),
  sort        int  not null default 0,
  created_at  timestamptz not null default now()
);
create index club_places_club_idx on public.club_places (club_id, sort, created_at);

alter table public.club_places enable row level security;
revoke insert, update, delete, truncate on public.club_places from anon, authenticated;
revoke all on public.club_places from anon;
create policy club_places_select on public.club_places
  for select to authenticated using (true);

-- ---------------------------------------------------------------------
-- 동아리 기본 정보 수정 (운영진)
-- ---------------------------------------------------------------------
create or replace function public.update_club_profile(
  p_club        uuid,
  p_name        text,
  p_description text,
  p_link_url    text
)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_link text := nullif(btrim(coalesce(p_link_url, '')), '');
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if char_length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;
  if v_link is not null and v_link !~ '^https://' then
    raise exception 'invalid_link' using errcode = '22023';
  end if;

  update public.clubs
     set name = left(btrim(p_name), 50),
         description = left(coalesce(p_description, ''), 1000),
         link_url = v_link
   where id = p_club;

  perform public.log_activity(p_club, null, 'club.update_profile', '{}'::jsonb);
end;
$$;

-- 로고 경로 지정/해제 (운영진). 반드시 그 동아리 폴더 안의 파일이어야 한다
create or replace function public.set_club_logo(p_club uuid, p_logo_path text)
returns void
language plpgsql security definer set search_path = ''
as $$
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if p_logo_path is not null
     and p_logo_path !~ ('^' || p_club::text || '/[A-Za-z0-9._-]{1,100}$') then
    raise exception 'invalid_logo_path' using errcode = '22023';
  end if;

  update public.clubs set logo_path = p_logo_path where id = p_club;
  perform public.log_activity(p_club, null, 'club.set_logo', jsonb_build_object('path', p_logo_path));
end;
$$;

-- ---------------------------------------------------------------------
-- 운동 장소 (운영진)
-- ---------------------------------------------------------------------
create or replace function public.save_place(
  p_club    uuid,
  p_id      uuid,
  p_name    text,
  p_address text,
  p_note    text
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
  if char_length(btrim(coalesce(p_name, ''))) = 0 then
    raise exception 'invalid_name' using errcode = '22023';
  end if;

  if p_id is null then
    insert into public.club_places (club_id, name, address, note, sort)
    values (p_club, left(btrim(p_name), 50), left(btrim(coalesce(p_address, '')), 200), left(btrim(coalesce(p_note, '')), 200),
            coalesce((select max(sort) + 1 from public.club_places where club_id = p_club), 0))
    returning id into v_id;
  else
    update public.club_places
       set name = left(btrim(p_name), 50),
           address = left(btrim(coalesce(p_address, '')), 200),
           note = left(btrim(coalesce(p_note, '')), 200)
     where id = p_id and club_id = p_club
    returning id into v_id;
    if v_id is null then
      raise exception 'place_not_found' using errcode = 'P0002';
    end if;
  end if;

  perform public.log_activity(p_club, null, 'club.save_place', jsonb_build_object('place_id', v_id));
  return v_id;
end;
$$;

create or replace function public.delete_place(p_place uuid)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_club uuid;
begin
  select club_id into v_club from public.club_places where id = p_place;
  if v_club is null then
    raise exception 'place_not_found' using errcode = 'P0002';
  end if;
  if not public.is_club_admin(v_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  delete from public.club_places where id = p_place;
  perform public.log_activity(v_club, null, 'club.delete_place', jsonb_build_object('place_id', p_place));
end;
$$;

-- Storage 정책용: '<club_id>/파일' 경로의 동아리 운영진인지. 형식이 틀리면 false
create or replace function public.is_admin_of_logo_path(p_path text)
returns boolean
language plpgsql stable security definer set search_path = ''
as $$
begin
  return public.is_club_admin(split_part(p_path, '/', 1)::uuid);
exception when others then
  return false;
end;
$$;

revoke execute on function public.update_club_profile(uuid, text, text, text)  from public, anon, authenticated;
revoke execute on function public.set_club_logo(uuid, text)                    from public, anon, authenticated;
revoke execute on function public.save_place(uuid, uuid, text, text, text)     from public, anon, authenticated;
revoke execute on function public.delete_place(uuid)                           from public, anon, authenticated;
revoke execute on function public.is_admin_of_logo_path(text)                  from public, anon, authenticated;
grant execute on function public.update_club_profile(uuid, text, text, text)   to authenticated;
grant execute on function public.set_club_logo(uuid, text)                     to authenticated;
grant execute on function public.save_place(uuid, uuid, text, text, text)      to authenticated;
grant execute on function public.delete_place(uuid)                            to authenticated;
grant execute on function public.is_admin_of_logo_path(text)                   to authenticated;  -- Storage 정책에서 호출

-- ---------------------------------------------------------------------
-- Storage: 로고 버킷 (공개 읽기, 2MB, 이미지만) + 운영진만 업로드/삭제
-- 로컬 테스트처럼 storage 스키마가 없으면 건너뛴다
-- ---------------------------------------------------------------------
do $$
begin
  if not exists (select 1 from pg_namespace where nspname = 'storage') then
    raise notice 'storage schema not found: skipping bucket setup';
    return;
  end if;

  insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
  values ('club-logos', 'club-logos', true, 2097152, array['image/png', 'image/jpeg', 'image/webp'])
  on conflict (id) do update
    set public = true, file_size_limit = 2097152, allowed_mime_types = array['image/png', 'image/jpeg', 'image/webp'];

  execute $p$drop policy if exists club_logos_insert on storage.objects$p$;
  execute $p$drop policy if exists club_logos_update on storage.objects$p$;
  execute $p$drop policy if exists club_logos_delete on storage.objects$p$;
  execute $p$drop policy if exists club_logos_select on storage.objects$p$;

  execute $p$create policy club_logos_select on storage.objects
    for select to authenticated using (bucket_id = 'club-logos')$p$;
  execute $p$create policy club_logos_insert on storage.objects
    for insert to authenticated with check (bucket_id = 'club-logos' and public.is_admin_of_logo_path(name))$p$;
  execute $p$create policy club_logos_update on storage.objects
    for update to authenticated using (bucket_id = 'club-logos' and public.is_admin_of_logo_path(name))$p$;
  execute $p$create policy club_logos_delete on storage.objects
    for delete to authenticated using (bucket_id = 'club-logos' and public.is_admin_of_logo_path(name))$p$;
end $$;
