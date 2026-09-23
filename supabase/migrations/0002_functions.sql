-- Phase 2 — 조회 RPC + 상태 전이 트리거 + 운영 뷰
-- 규칙 근거: docs/TRUST_AND_MODERATION.md

-- ─────────────────────────────────────────────────────────────
-- 1. 지도 조회 — 앱이 부르는 유일한 핵심 쿼리
--
-- bbox를 쓴다. 반경 검색은 원형이라 화면(사각형) 모서리의 스팟이 누락된다.
-- ─────────────────────────────────────────────────────────────

create or replace function spots_in_bbox(
  min_lng float8, min_lat float8, max_lng float8, max_lat float8,
  filter_type spot_type default null,
  max_rows int default 200
)
returns table (
  id bigint,
  name text,
  lng float8,
  lat float8,
  spot_type spot_type,
  status spot_status,
  cover_path text,
  needs_verify boolean,
  open_reports int
)
language sql stable security definer set search_path = public as $fn$
  select s.id,
         s.name,
         st_x(s.geom::geometry),
         st_y(s.geom::geometry),
         s.spot_type,
         s.status,
         (select p.storage_path
            from spot_photos p
           where p.spot_id = s.id and not p.is_hidden
           order by p.is_cover desc, p.created_at
           limit 1),
         -- "정보 확인 필요" 배지는 상태가 아니라 파생값이다. 배치 잡 없이 조회 시 계산.
         s.last_verified_at < now() - interval '180 days',
         s.open_report_count
    from spots s
   where s.status not in ('hidden', 'removed')
     and (filter_type is null or s.spot_type = filter_type)
     and s.geom && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
   order by s.last_verified_at desc
   limit least(max_rows, 500);
$fn$;

grant execute on function spots_in_bbox(float8, float8, float8, float8, spot_type, int)
  to anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- 2. 중복 탐지 — 등록 흐름(F4)에서 핀을 움직이는 동안 호출
--
-- 반경은 타입별로 다르다. 스케이트파크·광장은 부지가 넓어 50m로는 못 잡는다.
-- ─────────────────────────────────────────────────────────────

create or replace function duplicate_radius_m(t spot_type)
returns int language sql immutable as $fn$
  select case t when 'skatepark' then 150 when 'plaza_park' then 150 else 50 end;
$fn$;

create or replace function spots_near(
  lng float8, lat float8, new_type spot_type default null
)
returns table (
  id bigint,
  name text,
  lng_out float8,
  lat_out float8,
  spot_type spot_type,
  cover_path text,
  distance_m float8
)
language sql stable security definer set search_path = public as $fn$
  with origin as (
    select st_setsrid(st_makepoint(lng, lat), 4326)::geography as g,
           coalesce(duplicate_radius_m(new_type), 50) as r
  )
  select s.id,
         s.name,
         st_x(s.geom::geometry),
         st_y(s.geom::geometry),
         s.spot_type,
         (select p.storage_path from spot_photos p
           where p.spot_id = s.id and not p.is_hidden
           order by p.is_cover desc, p.created_at limit 1),
         st_distance(s.geom, o.g)
    from spots s, origin o
   where s.status not in ('hidden', 'removed')
     and st_dwithin(s.geom, o.g, o.r)
   order by s.geom <-> o.g
   limit 10;
$fn$;

grant execute on function spots_near(float8, float8, spot_type) to anon, authenticated;

-- ─────────────────────────────────────────────────────────────
-- 3. 스팟 등록 — rate limit + 중복 플래그를 서버에서 건다
-- ─────────────────────────────────────────────────────────────

create or replace function create_spot(
  p_name text,
  p_lng float8,
  p_lat float8,
  p_spot_type spot_type,
  p_obstacles obstacle[] default '{}',
  p_difficulty difficulty default null,
  p_surface surface default null,
  p_surface_quality surface_quality default null,
  p_is_indoor boolean default null,
  p_is_free boolean default null,
  p_has_lighting boolean default null,
  p_night_ok boolean default null,
  p_kickout_risk kickout_risk default 'unknown',
  p_best_time text default null,
  p_description text default null,
  p_is_private_property boolean default false
)
returns bigint
language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_today int;
  v_new_account boolean;
  v_dup int;
  v_flag text;
  v_id bigint;
  v_geog geography;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  -- rate limit: 하루 5개. 악의적 대량 등록 방어의 가장 싼 장치.
  select count(*) into v_today
    from spots where created_by = v_uid and created_at > now() - interval '24 hours';
  if v_today >= 5 then
    raise exception '하루 등록 한도(5개)를 넘었습니다' using errcode = 'P0001';
  end if;

  v_geog := st_setsrid(st_makepoint(p_lng, p_lat), 4326)::geography;

  -- 등록을 막지 않는다. 실제로 계단과 렛지가 5m 거리에 따로 있을 수 있다.
  -- 사람이 보고 판단하도록 플래그만 단다.
  -- 반경 30m + 같은 타입, 또는 타입 무관 반경 10m
  select count(*) into v_dup
    from spots s
   where s.status not in ('hidden', 'removed')
     and (
           (st_dwithin(s.geom, v_geog, 30) and s.spot_type = p_spot_type)
        or  st_dwithin(s.geom, v_geog, 10)
         );

  select (p.created_at > now() - interval '24 hours') into v_new_account
    from profiles p where p.id = v_uid;

  v_flag := case
    when v_dup > 0 then 'pending_duplicate'
    when coalesce(v_new_account, false) then 'new_account'
    else null
  end;

  insert into spots (
    name, geom, spot_type, obstacles, difficulty, surface, surface_quality,
    is_indoor, is_free, has_lighting, night_ok, kickout_risk,
    best_time, description, is_private_property, moderation_flag, created_by
  ) values (
    btrim(p_name), v_geog, p_spot_type, p_obstacles, p_difficulty, p_surface, p_surface_quality,
    p_is_indoor, p_is_free, p_has_lighting, p_night_ok, p_kickout_risk,
    p_best_time, p_description, p_is_private_property, v_flag, v_uid
  )
  returning id into v_id;

  return v_id;
end;
$fn$;

grant execute on function create_spot(
  text, float8, float8, spot_type, obstacle[], difficulty, surface, surface_quality,
  boolean, boolean, boolean, boolean, kickout_risk, text, text, boolean
) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 4. 상태 전이 — 제보 insert 트리거
--
-- 핵심 원칙 3가지 (docs/TRUST_AND_MODERATION.md):
--   1. 제보 1건으로는 아무것도 바뀌지 않는다
--   2. 되돌리기 어려운 변화(removed / no_skating)는 운영자 승인
--   3. 삭제하지 않는다. 상태만 바꾼다
-- ─────────────────────────────────────────────────────────────

create or replace function apply_spot_report() returns trigger
language plpgsql security definer set search_path = public as $fn$
declare
  v_weight smallint;
  v_distinct int;
  v_closed int;
  v_still int;
begin
  select report_weight into v_weight from profiles where id = new.reporter_id;

  -- 가중치 0인 계정(허위 신고 상습)의 제보는 접수되지만 집계에서 빠진다.
  if coalesce(v_weight, 0) = 0 then
    return new;
  end if;

  -- guard_spot_system_columns를 통과시키는 플래그. 트랜잭션 로컬이라
  -- 이 트리거가 끝나고 커밋되면 사라진다.
  perform set_config('app.system_update', '1', true);

  -- ── still_there: 예외적으로 즉시 반영 (되돌리기 쉽고 부작용이 없다)
  if new.kind = 'still_there' then
    -- 열린 cant_skate 제보 1건을 닫아 감쇠시킨다
    with victim as (
      select id from spot_reports
       where spot_id = new.spot_id and kind = 'cant_skate' and resolved_at is null
       order by created_at limit 1
    )
    update spot_reports r
       set resolved_at = now(), resolution = 'rejected'
      from victim v where r.id = v.id;
    get diagnostics v_closed = row_count;

    update spots
       set last_verified_at = now(),
           verify_count = verify_count + 1,
           open_report_count = greatest(0, open_report_count - v_closed)
     where id = new.spot_id;

    -- caution 상태에서 서로 다른 2명이 still_there를 넣으면 active로 자연 복구.
    -- BEFORE INSERT라 지금 넣는 행은 아직 테이블에 없다 → 본인을 빼고 세고 +1.
    -- (본인을 빼지 않으면 월이 바뀔 때 한 사람이 두 번 세어져 혼자 복구할 수 있다)
    select count(distinct r.reporter_id) into v_still
      from spot_reports r
      join profiles p on p.id = r.reporter_id and p.report_weight > 0
     where r.spot_id = new.spot_id
       and r.kind = 'still_there'
       and r.created_at > now() - interval '30 days'
       and r.reporter_id <> new.reporter_id;
    v_still := v_still + 1;

    if v_still >= 2 then
      update spots set status = 'active'
       where id = new.spot_id and status in ('caution', 'temporarily_closed');
    end if;

    perform set_config('app.system_update', '0', true);
    new.resolved_at := now();
    new.resolution := 'auto_applied';
    return new;
  end if;

  update spots set open_report_count = open_report_count + 1 where id = new.spot_id;

  -- 서로 다른 유저 기준으로 센다. 1인 다중 제보로 상태를 조작할 수 없다.
  -- 본인 행을 제외하고 센 뒤 +1 한다. BEFORE INSERT라 지금 넣는 행은 아직 없고,
  -- 본인을 빼지 않으면 월이 바뀔 때 한 사람이 2명으로 세어진다.
  select count(distinct r.reporter_id) into v_distinct
    from spot_reports r
    join profiles p on p.id = r.reporter_id and p.report_weight > 0
   where r.spot_id = new.spot_id
     and r.kind = new.kind
     and r.resolved_at is null
     and r.created_at > now() - interval '30 days'
     and r.reporter_id <> new.reporter_id;
  v_distinct := v_distinct + 1;

  if new.kind = 'cant_skate' and v_distinct >= 3 then
    -- 오탐 피해가 작고 still_there로 자연 복구된다. 자동 전환해도 안전.
    update spots set status = 'caution'
     where id = new.spot_id and status = 'active';

  elsif new.kind = 'gone' and v_distinct >= 3 then
    -- removed는 사실상 지도에서 지우는 것이다. 계정 3개면 담합이 가능하므로
    -- 자동 전환하지 않고 운영자 큐로만 보낸다.
    update spots set moderation_flag = 'pending_removal' where id = new.spot_id;

  elsif new.kind in ('wrong_info', 'wrong_location') and v_distinct >= 2 then
    update spots set moderation_flag = 'needs_review'
     where id = new.spot_id and moderation_flag is null;

  elsif new.kind in ('duplicate', 'inappropriate') then
    -- 1건부터 사람이 본다
    update spots set moderation_flag = coalesce(moderation_flag, 'needs_review')
     where id = new.spot_id;
  end if;

  perform set_config('app.system_update', '0', true);
  return new;
end;
$fn$;

-- 재실행 가능하게 둔다. 함수는 create or replace라 괜찮지만 트리거는 아니다.
drop trigger if exists spot_reports_apply on spot_reports;
create trigger spot_reports_apply
  before insert on spot_reports
  for each row execute function apply_spot_report();

-- ─────────────────────────────────────────────────────────────
-- 5. 제보 제출 RPC — rate limit 포함
-- ─────────────────────────────────────────────────────────────

create or replace function submit_report(
  p_spot_id bigint,
  p_kind report_kind,
  p_memo text default null,
  p_photo_path text default null
)
returns bigint
language plpgsql security definer set search_path = public as $fn$
declare
  v_uid uuid := auth.uid();
  v_today int;
  v_id bigint;
begin
  if v_uid is null then
    raise exception '로그인이 필요합니다' using errcode = '42501';
  end if;

  select count(*) into v_today
    from spot_reports
   where reporter_id = v_uid and created_at > now() - interval '24 hours';
  if v_today >= 10 then
    raise exception '하루 제보 한도(10건)를 넘었습니다' using errcode = 'P0001';
  end if;

  insert into spot_reports (spot_id, reporter_id, kind, memo, photo_path)
  values (p_spot_id, v_uid, p_kind, p_memo, p_photo_path)
  -- 같은 유저의 같은 스팟·같은 유형 제보는 월 1건. 조용히 무시한다.
  on conflict do nothing
  returning id into v_id;

  return v_id;
end;
$fn$;

grant execute on function submit_report(bigint, report_kind, text, text) to authenticated;

-- ─────────────────────────────────────────────────────────────
-- 6. 운영 뷰 — 어드민 앱을 만들지 않는다. Supabase SQL 콘솔로 운영한다.
--    일 10~30건 규모에 어드민 UI는 순수 낭비.
-- ─────────────────────────────────────────────────────────────

create or replace view admin_review_queue as
select s.id,
       s.name,
       s.spot_type,
       s.status,
       s.moderation_flag,
       s.open_report_count,
       s.created_at,
       p.nickname as created_by,
       st_y(s.geom::geometry) as lat,
       st_x(s.geom::geometry) as lng
  from spots s
  join profiles p on p.id = s.created_by
 where s.moderation_flag is not null
    or s.open_report_count > 0
 order by s.moderation_flag is null, s.created_at;

create or replace view admin_gone_reports as
select s.id,
       s.name,
       count(*) filter (where r.kind = 'gone' and r.resolved_at is null) as gone_reports,
       array_agg(r.photo_path) filter (where r.photo_path is not null) as evidence,
       st_y(s.geom::geometry) as lat,
       st_x(s.geom::geometry) as lng
  from spots s
  join spot_reports r on r.spot_id = s.id
 where s.moderation_flag = 'pending_removal'
 group by s.id, s.name, s.geom
 order by gone_reports desc;

create or replace view admin_abuse_watch as
select p.id,
       p.nickname,
       p.report_weight,
       p.created_at,
       count(*) filter (where r.resolution = 'rejected') as rejected_reports,
       count(*) filter (where r.created_at > now() - interval '24 hours') as reports_24h,
       (select count(*) from spots s
         where s.created_by = p.id and s.created_at > now() - interval '24 hours') as spots_24h
  from profiles p
  left join spot_reports r on r.reporter_id = p.id
 group by p.id
having count(*) filter (where r.resolution = 'rejected') >= 2
    or count(*) filter (where r.created_at > now() - interval '24 hours') >= 8;

-- 뷰는 운영자만 본다. 일반 사용자에게 노출하지 않는다.
revoke all on admin_review_queue, admin_gone_reports, admin_abuse_watch from anon, authenticated;
