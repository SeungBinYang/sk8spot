-- Phase 7 — 공유 딥링크로 스팟 1개 조회 + 즐겨찾기 목록 조회
--
-- favorites 테이블·RLS는 0001에 이미 있다(개인 소유 행만 접근 가능).
-- 여기서 필요한 건 좌표 추출뿐이다 — PostGIS geography가 PostgREST에서
-- EWKB hex로 나와 REST select로는 못 읽는다(spots_in_bbox와 같은 이유).
-- 그래서 두 함수 다 spots_in_bbox와 같은 행 모양으로 만든다.
-- SpotPin.fromRow가 그 모양을 그대로 파싱하기 때문이다(app/lib/spot.dart).

create or replace function spot_pin(p_id bigint)
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
         s.last_verified_at < now() - interval '180 days',
         s.open_report_count
    from spots s
   where s.id = p_id
     and s.status not in ('hidden', 'removed');
$fn$;

-- 공유된 링크는 비회원도 열 수 있어야 한다(F1, 비로그인 열람 원칙).
grant execute on function spot_pin(bigint) to anon, authenticated;

create or replace function my_favorite_spots()
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
         s.last_verified_at < now() - interval '180 days',
         s.open_report_count
    from favorites f
    join spots s on s.id = f.spot_id
   where f.user_id = auth.uid()
     and s.status not in ('hidden', 'removed')
   order by f.created_at desc;
$fn$;

grant execute on function my_favorite_spots() to authenticated;
