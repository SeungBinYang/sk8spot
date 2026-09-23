-- Phase 4 — 인증
--
-- 로그인 시점에 닉네임을 묻지 않는다. 자동 생성하고 나중에 바꾸게 한다.
-- (docs/USER_FLOWS.md — 로그인 시트)

-- ─────────────────────────────────────────────────────────────
-- 1. 가입 시 프로필 자동 생성
--
-- 앱이 프로필을 만들게 하면 "로그인은 됐는데 프로필이 없는" 상태가 생긴다.
-- (앱이 죽거나, 네트워크가 끊기거나, 두 번째 기기에서 로그인하거나)
-- DB 트리거로 붙여 그 상태 자체를 없앤다.
-- ─────────────────────────────────────────────────────────────

create or replace function handle_new_user() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_nickname text;
begin
  -- 카카오는 동의항목 설정에 따라 닉네임을 줄 수도, 안 줄 수도 있다.
  -- 없으면 만들어 준다. 어차피 사용자가 바꿀 수 있다.
  v_nickname := coalesce(
    nullif(btrim(new.raw_user_meta_data ->> 'name'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'nickname'), ''),
    nullif(btrim(new.raw_user_meta_data ->> 'preferred_username'), ''),
    '스케이터' || lpad((floor(random() * 10000))::int::text, 4, '0')
  );

  insert into profiles (id, nickname, avatar_url)
  values (
    new.id,
    left(v_nickname, 20),
    nullif(btrim(new.raw_user_meta_data ->> 'avatar_url'), '')
  )
  on conflict (id) do nothing;   -- 재로그인/중복 이벤트에도 안전

  return new;
end;
$fn$;

drop trigger if exists on_auth_user_created on auth.users;
create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function handle_new_user();

-- ─────────────────────────────────────────────────────────────
-- 2. 탈퇴
--
-- 스팟은 지우지 않는다. 한 명이 나갔다고 지도에 구멍이 나면 안 된다.
-- 작성자만 익명화한다. (docs/OPEN_DECISIONS.md 7번)
--
-- ⚠️ auth.users 행 자체의 삭제는 클라이언트 권한으로 불가능하다.
--    스토어 심사용 완전 삭제는 service_role을 쓰는 Edge Function이 필요하다 → Phase 9.
--    지금은 프로필 익명화 + 세션 종료까지만 한다.
-- ─────────────────────────────────────────────────────────────

alter table profiles add column if not exists deleted_at timestamptz;

create or replace function delete_my_account() returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  update profiles
     set nickname   = '탈퇴한 스케이터',
         avatar_url = null,
         deleted_at = now(),
         report_weight = 0        -- 남은 제보가 집계에 영향을 주지 않게
   where id = v_uid;

  -- 즐겨찾기는 개인 데이터라 지운다. 스팟·사진·제보는 공용 기록이라 남긴다.
  delete from favorites where user_id = v_uid;
end;
$fn$;

grant execute on function delete_my_account() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 3. 닉네임 변경
-- ─────────────────────────────────────────────────────────────

create or replace function set_my_nickname(p_nickname text) returns void
language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_name text := btrim(p_nickname);
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;
  if char_length(v_name) < 2 or char_length(v_name) > 20 then
    raise exception '닉네임은 2~20자여야 합니다' using errcode = 'P0001';
  end if;

  update profiles set nickname = v_name where id = v_uid and deleted_at is null;
end;
$fn$;

grant execute on function set_my_nickname(text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 4. 내 프로필 조회
--    profiles select 정책은 닉네임/아바타만 공개라, 본인 전체 정보는 따로 준다.
-- ─────────────────────────────────────────────────────────────

create or replace function my_profile()
returns table (id uuid, nickname text, avatar_url text, is_admin boolean,
               spot_count bigint, created_at timestamptz)
language sql stable security definer set search_path = public as $fn$
  select p.id, p.nickname, p.avatar_url, p.is_admin,
         (select count(*) from spots s
           where s.created_by = p.id and s.status <> 'hidden'),
         p.created_at
    from profiles p
   where p.id = auth.uid() and p.deleted_at is null;
$fn$;

grant execute on function my_profile() to authenticated;
