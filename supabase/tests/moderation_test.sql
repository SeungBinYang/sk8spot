-- 상태 전이 규칙 검증. Supabase SQL Editor에 통째로 붙여넣고 실행한다.
-- 전부 롤백되므로 실제 데이터에 남지 않는다.
--
-- 검증하는 것 (docs/TRUST_AND_MODERATION.md의 핵심 3원칙):
--   1. 제보 1건으로는 상태가 바뀌지 않는다
--   2. 서로 다른 유저 3명 → caution 자동 전환
--   3. gone은 3건이어도 자동 전환하지 않고 운영 큐로만 간다
--   4. 같은 유저가 여러 번 제보해도 1명으로 센다
--   5. report_weight = 0 계정의 제보는 집계에서 빠진다
--   6. still_there로 caution에서 복구된다
--
-- ★ 4번과 6번이 특히 중요하다. 여기가 깨지면 담합으로 스팟을 죽일 수 있다.
-- ★ 그리고 이 테스트는 guard_spot_system_columns가 apply_spot_report의
--   상태 변경을 되돌려버리는 회귀를 잡는다. 그 버그가 있으면 2번부터 전부 실패한다.

begin;

-- ── 픽스처 ────────────────────────────────────────────────────
-- auth.users는 Supabase가 관리한다. 테스트용 최소 행만 만든다.
insert into auth.users (id, email)
values
  ('00000000-0000-0000-0000-0000000000a1', 't-a1@example.test'),
  ('00000000-0000-0000-0000-0000000000a2', 't-a2@example.test'),
  ('00000000-0000-0000-0000-0000000000a3', 't-a3@example.test'),
  ('00000000-0000-0000-0000-0000000000a4', 't-a4@example.test'),
  ('00000000-0000-0000-0000-0000000000b0', 't-b0@example.test')
on conflict (id) do nothing;

insert into profiles (id, nickname, report_weight) values
  ('00000000-0000-0000-0000-0000000000a1', 'tester1', 1),
  ('00000000-0000-0000-0000-0000000000a2', 'tester2', 1),
  ('00000000-0000-0000-0000-0000000000a3', 'tester3', 1),
  ('00000000-0000-0000-0000-0000000000a4', 'tester4', 1),
  ('00000000-0000-0000-0000-0000000000b0', 'banned',  0);  -- 가중치 0

insert into spots (name, geom, spot_type, created_by)
values (
  '테스트 계단',
  st_setsrid(st_makepoint(126.979, 37.5666), 4326)::geography,
  'street',
  '00000000-0000-0000-0000-0000000000a1'
);

do $test$
declare
  v_spot bigint;
  v_status spot_status;
  v_flag text;
  v_verified timestamptz;
  v_open int;
begin
  select id into v_spot from spots where name = '테스트 계단';

  -- ── 1. 제보 1건으로는 아무것도 바뀌지 않는다 ────────────────
  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000a1', 'cant_skate');

  select status, open_report_count into v_status, v_open from spots where id = v_spot;
  assert v_status = 'active',
    format('[1] 제보 1건에 상태가 바뀌면 안 된다. got=%s', v_status);
  assert v_open = 1,
    format('[1] open_report_count가 1이어야 한다. got=%s', v_open);

  -- ── 4. 같은 유저가 또 넣어도 1명으로 센다 ───────────────────
  -- (unique index가 월 1건으로 막는다)
  begin
    insert into spot_reports (spot_id, reporter_id, kind)
    values (v_spot, '00000000-0000-0000-0000-0000000000a1', 'cant_skate');
    assert false, '[4] 같은 유저의 같은 유형 중복 제보가 막히지 않았다';
  exception when unique_violation then
    null;  -- 기대한 동작
  end;

  -- ── 5. 가중치 0 계정의 제보는 집계에서 빠진다 ───────────────
  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000b0', 'cant_skate');

  select status into v_status from spots where id = v_spot;
  assert v_status = 'active',
    format('[5] 가중치 0 계정 제보는 집계에서 빠져야 한다. got=%s', v_status);

  -- ── 2. 서로 다른 유저 3명 → caution ─────────────────────────
  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000a2', 'cant_skate');

  select status into v_status from spots where id = v_spot;
  assert v_status = 'active',
    format('[2] 2명까지는 active여야 한다. got=%s', v_status);

  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000a3', 'cant_skate');

  select status into v_status from spots where id = v_spot;
  assert v_status = 'caution',
    format('[2] 서로 다른 3명이면 caution이어야 한다. got=%s '
           '(guard_spot_system_columns가 되돌렸을 가능성)', v_status);

  -- ── 6. still_there 2건으로 active 복구 ──────────────────────
  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000a4', 'still_there');

  select status into v_status from spots where id = v_spot;
  assert v_status = 'caution',
    format('[6] still_there 1건으로는 복구되면 안 된다. got=%s', v_status);

  insert into spot_reports (spot_id, reporter_id, kind)
  values (v_spot, '00000000-0000-0000-0000-0000000000a1', 'still_there');

  select status, last_verified_at into v_status, v_verified from spots where id = v_spot;
  assert v_status = 'active',
    format('[6] still_there 2건이면 active로 복구되어야 한다. got=%s', v_status);
  assert v_verified > now() - interval '1 minute',
    '[6] last_verified_at이 갱신되어야 한다';

  raise notice '✓ cant_skate / still_there 경로 통과';
end;
$test$;

-- ── 3. gone은 자동 전환하지 않는다 ────────────────────────────
-- 되돌리기 가장 비싼 변화라 계정 3개 담합으로 지도에서 사라지면 안 된다.
insert into spots (name, geom, spot_type, created_by)
values (
  '철거 테스트',
  st_setsrid(st_makepoint(127.05, 37.50), 4326)::geography,
  'street',
  '00000000-0000-0000-0000-0000000000a1'
);

do $test$
declare
  v_spot bigint;
  v_status spot_status;
  v_flag text;
begin
  select id into v_spot from spots where name = '철거 테스트';

  insert into spot_reports (spot_id, reporter_id, kind) values
    (v_spot, '00000000-0000-0000-0000-0000000000a1', 'gone'),
    (v_spot, '00000000-0000-0000-0000-0000000000a2', 'gone'),
    (v_spot, '00000000-0000-0000-0000-0000000000a3', 'gone');

  select status, moderation_flag into v_status, v_flag from spots where id = v_spot;

  assert v_status <> 'removed',
    '[3] gone 제보만으로 removed가 되면 안 된다 (운영자 승인 필요)';
  assert v_status = 'active',
    format('[3] gone은 상태를 바꾸지 않는다. got=%s', v_status);
  assert v_flag = 'pending_removal',
    format('[3] 운영 큐 플래그가 걸려야 한다. got=%s', v_flag);

  raise notice '✓ gone 경로 통과 — 자동 삭제 없음, 운영 큐로만';
end;
$test$;

-- ── bbox 조회가 실제로 동작하는지 ─────────────────────────────
do $test$
declare
  v_count int;
begin
  select count(*) into v_count
    from spots_in_bbox(126.90, 37.45, 127.10, 37.62);
  assert v_count >= 2,
    format('[bbox] 서울 영역에서 테스트 스팟 2개가 나와야 한다. got=%s', v_count);

  -- 타입 필터
  select count(*) into v_count
    from spots_in_bbox(126.90, 37.45, 127.10, 37.62, 'skatepark');
  assert v_count = 0,
    format('[bbox] skatepark 필터에는 0개여야 한다. got=%s', v_count);

  raise notice '✓ spots_in_bbox 통과';
end;
$test$;

-- ── 중복 탐지 반경 ────────────────────────────────────────────
do $test$
declare
  v_count int;
  v_dist float8;
begin
  -- 테스트 계단 바로 옆(약 20m)
  select count(*) into v_count
    from spots_near(126.97923, 37.5666, 'street');
  assert v_count >= 1,
    format('[near] 50m 안의 스트리트 스팟을 찾아야 한다. got=%s', v_count);

  -- 500m 밖
  select count(*) into v_count
    from spots_near(126.9850, 37.5666, 'street');
  assert v_count = 0,
    format('[near] 50m 밖은 잡히면 안 된다. got=%s', v_count);

  -- 파크는 반경이 150m로 넓다
  assert duplicate_radius_m('skatepark') = 150, '[near] 파크 반경은 150m';
  assert duplicate_radius_m('street') = 50, '[near] 스트리트 반경은 50m';

  raise notice '✓ spots_near / 중복 반경 통과';
end;
$test$;

rollback;
