-- Phase 2 — 스키마 + RLS
-- 설계 근거: docs/DATA_MODEL.md
-- 상태 전이·모더레이션 규칙은 0002_functions.sql 에 있다.

create extension if not exists postgis;

-- ─────────────────────────────────────────────────────────────
-- enums
-- ─────────────────────────────────────────────────────────────

create type spot_type as enum (
  'skatepark',   -- 공식 스케이트파크
  'street',      -- 스트리트 스팟
  'plaza_park',  -- 광장·공원 등 넓은 플랫
  'diy'          -- DIY 스팟
);

-- 지도 아이콘은 spot_type으로만 나눈다. obstacle로 나누면 지도가 읽히지 않는다.
create type obstacle as enum (
  'stair', 'handrail', 'flat_rail', 'ledge', 'curb', 'bank',
  'manual_pad', 'gap', 'quarter', 'hubba', 'flat'
);

create type surface as enum (
  'smooth_concrete', 'rough_concrete', 'marble_tile', 'asphalt',
  'brick_tile', 'urethane', 'wood', 'metal', 'other'
);

create type surface_quality as enum ('good', 'fair', 'poor');

create type difficulty as enum ('beginner', 'intermediate', 'advanced');

-- 이 앱의 핵심 차별 필드. 일반 장소 앱에는 없다.
create type kickout_risk as enum ('low', 'medium', 'high', 'banned', 'unknown');

create type spot_status as enum (
  'active',
  'caution',              -- 이용 어려움 / 제지 위험 (제보 누적 자동)
  'temporarily_closed',   -- 공사 등 일시 불가 (제보 누적 자동)
  'no_skating',           -- 스케이트 금지 (운영자 승인 필요)
  'removed',              -- 철거·소멸 (운영자 승인 필요)
  'hidden'                -- 운영자 비공개 (허위·권리침해)
);

create type report_kind as enum (
  'still_there', 'gone', 'cant_skate',
  'wrong_info', 'wrong_location', 'duplicate', 'inappropriate'
);

-- ─────────────────────────────────────────────────────────────
-- profiles
-- ─────────────────────────────────────────────────────────────

create table profiles (
  id            uuid primary key references auth.users on delete cascade,
  nickname      text not null,
  avatar_url    text,
  -- 운영자가 반려한 제보가 누적되면 0으로 내린다. 사용자에게 알리지 않는다
  -- (알리면 새 계정을 만든다). 제보는 접수되지만 집계에서 빠진다.
  report_weight smallint not null default 1 check (report_weight between 0 and 3),
  is_admin      boolean not null default false,
  created_at    timestamptz not null default now()
);

-- ─────────────────────────────────────────────────────────────
-- spots
-- ─────────────────────────────────────────────────────────────

create table spots (
  id bigint generated always as identity primary key,

  -- [A] 사용자 직접 입력
  name            text not null check (char_length(btrim(name)) between 1 and 60),
  geom            geography(Point, 4326) not null,
  spot_type       spot_type not null,
  obstacles       obstacle[] not null default '{}',
  surface         surface,
  surface_quality surface_quality,
  is_indoor       boolean,
  is_free         boolean,
  has_lighting    boolean,
  night_ok        boolean,
  best_time       text check (char_length(best_time) <= 100),
  description     text check (char_length(description) <= 1000),

  -- [B] 여러 사용자 평가로 수렴할 값. MVP는 등록자 입력 + 운영자 조정.
  difficulty   difficulty,
  kickout_risk kickout_risk not null default 'unknown',

  -- [C] 시스템 관리 — 클라이언트가 직접 쓰지 못한다 (RLS + 트리거)
  status              spot_status not null default 'active',
  is_private_property boolean not null default false,
  last_verified_at    timestamptz not null default now(),
  verify_count        integer not null default 0,
  open_report_count   integer not null default 0,
  moderation_flag     text,  -- 'pending_duplicate' | 'new_account' | 'pending_removal' | 'needs_review'
  created_by          uuid not null references profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- 지도 bbox 조회의 생명줄
create index spots_geom_idx on spots using gist (geom);

-- 지도에 보이는 스팟만 훑는 부분 인덱스
create index spots_visible_idx on spots (status)
  where status not in ('hidden', 'removed');

create index spots_moderation_idx on spots (moderation_flag)
  where moderation_flag is not null;

create index spots_created_by_idx on spots (created_by);

-- ─────────────────────────────────────────────────────────────
-- spot_photos
-- ─────────────────────────────────────────────────────────────

create table spot_photos (
  id           bigint generated always as identity primary key,
  spot_id      bigint not null references spots(id) on delete cascade,
  uploaded_by  uuid   not null references profiles(id),
  storage_path text   not null,
  is_cover     boolean not null default false,
  -- 신고 처리 시 숨긴다. 물리 삭제하지 않는다.
  is_hidden    boolean not null default false,
  created_at   timestamptz not null default now()
);

create index spot_photos_spot_idx on spot_photos (spot_id) where not is_hidden;

-- ─────────────────────────────────────────────────────────────
-- spot_reports
-- 제보는 지우지 않는다. 자동 전이의 근거이자 감사 로그다.
-- ─────────────────────────────────────────────────────────────

create table spot_reports (
  id          bigint generated always as identity primary key,
  spot_id     bigint not null references spots(id) on delete cascade,
  reporter_id uuid   not null references profiles(id),
  kind        report_kind not null,
  memo        text check (char_length(memo) <= 300),
  photo_path  text,                      -- 철거 제보 시 증빙
  created_at  timestamptz not null default now(),

  resolved_at timestamptz,
  resolution  text check (resolution in ('accepted', 'rejected', 'auto_applied')),
  resolved_by uuid references profiles(id)
);

-- 같은 유저가 같은 스팟에 같은 유형 제보를 반복해도 월 1건으로 센다.
-- date_trunc(text, timestamptz)는 STABLE이라 인덱스에 직접 못 쓴다.
-- `at time zone 'UTC'`로 timestamp로 바꾸면 IMMUTABLE이 되어 사용 가능.
create unique index spot_reports_dedup_idx
  on spot_reports (spot_id, reporter_id, kind,
                   (date_trunc('month', created_at at time zone 'UTC')));

create index spot_reports_open_idx
  on spot_reports (spot_id, kind) where resolved_at is null;

-- ─────────────────────────────────────────────────────────────
-- favorites  [Should — MVP 포함 여부는 OPEN_DECISIONS 4번]
-- ─────────────────────────────────────────────────────────────

create table favorites (
  user_id    uuid   not null references profiles(id) on delete cascade,
  spot_id    bigint not null references spots(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, spot_id)
);

-- ─────────────────────────────────────────────────────────────
-- updated_at 자동 갱신
-- ─────────────────────────────────────────────────────────────

create or replace function touch_updated_at() returns trigger
language plpgsql as $fn$
begin
  new.updated_at := now();
  return new;
end;
$fn$;

drop trigger if exists spots_touch_updated_at on spots;
create trigger spots_touch_updated_at
  before update on spots
  for each row execute function touch_updated_at();

-- ─────────────────────────────────────────────────────────────
-- RLS
--
-- 두 가지가 핵심이다.
--  1) 비로그인(anon) 열람 허용 — 이게 빠지면 USER_FLOWS F1이 통째로 깨진다.
--  2) status / last_verified_at / *_count 는 클라이언트가 못 쓴다.
--     전부 SECURITY DEFINER 함수와 트리거를 거친다.
-- ─────────────────────────────────────────────────────────────

alter table profiles     enable row level security;
alter table spots        enable row level security;
alter table spot_photos  enable row level security;
alter table spot_reports enable row level security;
alter table favorites    enable row level security;

create or replace function is_admin() returns boolean
language sql stable security definer set search_path = public as $fn$
  select coalesce((select p.is_admin from profiles p where p.id = auth.uid()), false);
$fn$;

-- profiles: 닉네임/아바타는 공개, 수정은 본인만
create policy profiles_read_all on profiles
  for select to anon, authenticated using (true);
create policy profiles_insert_self on profiles
  for insert to authenticated with check (id = auth.uid());
create policy profiles_update_self on profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- spots: 비로그인 포함 전체 공개 (hidden 제외)
create policy spots_read_public on spots
  for select to anon, authenticated using (status <> 'hidden');
create policy spots_read_admin on spots
  for select to authenticated using (is_admin());

create policy spots_insert_authenticated on spots
  for insert to authenticated with check (created_by = auth.uid());

-- 등록자는 자기 스팟의 '입력 필드'만 고친다.
-- 시스템 필드 보호는 아래 트리거가 담당한다 (RLS로는 컬럼 단위 제약이 어렵다).
create policy spots_update_owner on spots
  for update to authenticated
  using (created_by = auth.uid() and status <> 'hidden')
  with check (created_by = auth.uid());
create policy spots_update_admin on spots
  for update to authenticated using (is_admin()) with check (is_admin());

-- spot_photos: 공개 읽기, 로그인 쓰기
create policy spot_photos_read_public on spot_photos
  for select to anon, authenticated using (not is_hidden);
create policy spot_photos_insert on spot_photos
  for insert to authenticated with check (uploaded_by = auth.uid());
create policy spot_photos_delete_own on spot_photos
  for delete to authenticated using (uploaded_by = auth.uid() or is_admin());

-- spot_reports: 본인 것 + 운영자만 읽는다. 일반 사용자는 집계 수치만 본다.
create policy spot_reports_read_own on spot_reports
  for select to authenticated using (reporter_id = auth.uid() or is_admin());
create policy spot_reports_insert on spot_reports
  for insert to authenticated with check (reporter_id = auth.uid());
create policy spot_reports_update_admin on spot_reports
  for update to authenticated using (is_admin()) with check (is_admin());

-- favorites: 본인만
create policy favorites_all_own on favorites
  for all to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- ─────────────────────────────────────────────────────────────
-- 시스템 컬럼 보호
-- 등록자가 자기 스팟을 수정할 때 status 등을 건드리지 못하게 막는다.
-- ─────────────────────────────────────────────────────────────

create or replace function guard_spot_system_columns() returns trigger
language plpgsql security definer set search_path = public as $fn$
begin
  -- 시스템 함수(apply_spot_report 등)가 거는 업데이트는 통과시킨다.
  -- 이 플래그가 없으면 제보 트리거가 바꾼 status를 이 가드가 즉시 되돌려
  -- 모더레이션이 통째로 무력화된다. 플래그는 트랜잭션 로컬(is_local=true)이라
  -- 커밋/롤백과 함께 사라지고 클라이언트가 세션에 남길 수 없다.
  if coalesce(current_setting('app.system_update', true), '') = '1' then
    return new;
  end if;

  if is_admin() then
    return new;
  end if;

  -- 시스템이 관리하는 값은 이전 값을 강제로 되돌린다.
  new.status            := old.status;
  new.last_verified_at  := old.last_verified_at;
  new.verify_count      := old.verify_count;
  new.open_report_count := old.open_report_count;
  new.moderation_flag   := old.moderation_flag;
  new.created_by        := old.created_by;
  new.created_at        := old.created_at;
  return new;
end;
$fn$;

drop trigger if exists spots_guard_system_columns on spots;
create trigger spots_guard_system_columns
  before update on spots
  for each row execute function guard_spot_system_columns();

-- ─────────────────────────────────────────────────────────────
-- 권한 명시
--
-- Supabase 프로젝트 생성 시 "Automatically expose new tables" 체크박스에 따라
-- 기본 GRANT가 달라진다. 마이그레이션이 그 체크박스에 의존하면 안 되므로
-- 필요한 권한만 직접 준다. 실제 접근 제어는 위의 RLS 정책이 한다.
-- ─────────────────────────────────────────────────────────────

-- 우선 전부 회수하고 필요한 것만 다시 준다 (auto-expose가 켜져 있어도 동일한 결과)
revoke all on spots, spot_photos, spot_reports, favorites, profiles from anon, authenticated;

-- 비회원: 읽기만. 이게 빠지면 USER_FLOWS F1(비회원 지도 열람)이 깨진다.
grant select on spots, spot_photos, profiles to anon;

grant select on spots, spot_photos, profiles to authenticated;
grant insert, update on spots to authenticated;
grant insert, delete on spot_photos to authenticated;
grant select, insert on spot_reports to authenticated;  -- update는 운영자만 (RLS)
grant select, insert, delete on favorites to authenticated;
grant insert, update on profiles to authenticated;

-- 뷰는 운영자 전용. 0002에서도 revoke하지만 여기서 한 번 더 못 박는다.
