-- =====================================================================
-- 급수는 정해진 목록에서 고른다 (오타 방지, 자동 대진 실력 점수와 1:1)
--   A조 · B조 · C조 · D조 · 초심, 또는 미입력(null)
--   기존 자유 입력 값은 같은 규칙으로 맞추고, 알아볼 수 없는 값은 비운다
-- =====================================================================
update public.club_members
   set level = case
     when level is null or btrim(level) = '' then null
     when upper(btrim(level)) ~ '^(자강|S|A)' then 'A조'
     when upper(btrim(level)) ~ '^B' then 'B조'
     when upper(btrim(level)) ~ '^C' then 'C조'
     when upper(btrim(level)) ~ '^D' then 'D조'
     when btrim(level) ~ '(초심|입문|왕초)' or upper(btrim(level)) ~ '^(E|F)' then '초심'
     else null
   end;

alter table public.club_members
  add constraint club_members_level_choice check (level is null or level in ('A조', 'B조', 'C조', 'D조', '초심'));

create or replace function public.set_my_level(p_club uuid, p_level text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_level text := nullif(btrim(p_level), '');
begin
  if v_level is not null and v_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;
  update public.club_members set level = v_level
   where club_id = p_club and user_id = auth.uid() and status = 'approved';
  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
end;
$$;

-- 운영진이 회원 급수 수정
create or replace function public.set_member_level(p_club uuid, p_user uuid, p_level text)
returns void
language plpgsql security definer set search_path = ''
as $$
declare
  v_level text := nullif(btrim(p_level), '');
begin
  if not public.is_club_admin(p_club) then
    raise exception 'forbidden' using errcode = '42501';
  end if;
  if v_level is not null and v_level not in ('A조', 'B조', 'C조', 'D조', '초심') then
    raise exception 'invalid_level' using errcode = '22023';
  end if;
  update public.club_members set level = v_level
   where club_id = p_club and user_id = p_user and status = 'approved';
  if not found then
    raise exception 'not_member' using errcode = 'P0002';
  end if;
  perform public.log_activity(p_club, null, 'member.set_level', jsonb_build_object('user_id', p_user, 'level', v_level));
end;
$$;

revoke execute on function public.set_member_level(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.set_member_level(uuid, uuid, text) to authenticated;
