-- 개발용 시드 — 실제 스팟 데이터가 아니다.
--
-- ⚠️ 여기 좌표는 서울·수도권의 실재하는 공원·광장 위치지만,
--    스케이트 가능 여부·바닥 상태·제지 위험도는 **전부 임의값**이다.
--    지도/클러스터/조회 흐름을 테스트하기 위한 더미다.
--    실제 출시 시드는 운영자가 직접 확인·촬영해야 한다.
--    → docs/DEVELOPMENT_ROADMAP.md 의 콜드 스타트 전략 참조
--
-- 재실행 가능하다. 기존 시드를 지우고 다시 넣는다.

-- 시드 소유자 (개발용 시스템 계정)
insert into auth.users (id, email)
values ('00000000-0000-0000-0000-00000000dead', 'seed@dev.local')
on conflict (id) do nothing;

insert into profiles (id, nickname, is_admin)
values ('00000000-0000-0000-0000-00000000dead', 'seed-bot', true)
on conflict (id) do update set nickname = excluded.nickname;

-- 기존 시드 제거 (사용자가 등록한 스팟은 건드리지 않는다)
delete from spots where created_by = '00000000-0000-0000-0000-00000000dead';

insert into spots (
  name, geom, spot_type, obstacles, difficulty, surface, surface_quality,
  is_indoor, is_free, has_lighting, night_ok, kickout_risk,
  best_time, description, status, created_by
)
select
  d.name,
  st_setsrid(st_makepoint(d.lng, d.lat), 4326)::geography,
  d.spot_type::spot_type,
  d.obstacles::obstacle[],
  d.difficulty::difficulty,
  d.surface::surface,
  d.quality::surface_quality,
  false, true, d.lighting, d.lighting,
  d.kickout::kickout_risk,
  d.best_time,
  '[개발용 시드] 실제 확인되지 않은 더미 데이터입니다.',
  d.status::spot_status,
  '00000000-0000-0000-0000-00000000dead'
from (values
  -- 한강공원 계열 — 넓은 플랫, 야간 조명
  ('여의도 한강공원',   126.9340, 37.5285, 'plaza_park', '{flat,manual_pad,curb}',      'beginner',     'smooth_concrete', 'good', true,  'low',    '평일 저녁',      'active'),
  ('반포 한강공원',     126.9958, 37.5100, 'plaza_park', '{flat,ledge,bank}',           'beginner',     'smooth_concrete', 'good', true,  'low',    '해질녘',         'active'),
  ('뚝섬 한강공원',     127.0668, 37.5297, 'plaza_park', '{flat,curb,manual_pad}',      'beginner',     'smooth_concrete', 'fair', true,  'low',    '평일 오후',      'active'),
  ('난지 한강공원',     126.8778, 37.5658, 'plaza_park', '{flat,bank}',                 'beginner',     'rough_concrete',  'fair', true,  'low',    '주말 아침',      'active'),
  ('광나루 한강공원',   127.1220, 37.5450, 'skatepark',  '{quarter,bank,flat}',         'intermediate', 'urethane',        'good', true,  'low',    '언제나',         'active'),
  ('잠실 한강공원',     127.0820, 37.5180, 'plaza_park', '{flat,ledge}',                'beginner',     'smooth_concrete', 'good', true,  'low',    '평일 저녁',      'active'),
  ('노들섬',            126.9585, 37.5175, 'plaza_park', '{flat,curb}',                 'beginner',     'smooth_concrete', 'fair', true,  'medium', '평일 낮',        'active'),

  -- 공원 계열
  ('서울숲',            127.0374, 37.5444, 'plaza_park', '{flat,manual_pad,stair}',     'intermediate', 'brick_tile',      'fair', true,  'medium', '평일 오전',      'active'),
  ('올림픽공원',        127.1214, 37.5202, 'plaza_park', '{stair,ledge,bank,flat}',     'intermediate', 'marble_tile',     'good', true,  'high',   '이른 아침',      'caution'),
  ('월드컵공원 평화의공원', 126.8890, 37.5710, 'plaza_park', '{flat,bank}',             'beginner',     'smooth_concrete', 'good', true,  'low',    '평일 저녁',      'active'),
  ('보라매공원',        126.9200, 37.4930, 'plaza_park', '{flat,curb,manual_pad}',      'beginner',     'rough_concrete',  'fair', true,  'low',    '평일 오후',      'active'),
  ('어린이대공원',      127.0817, 37.5497, 'plaza_park', '{flat,stair}',                'beginner',     'brick_tile',      'poor', true,  'high',   '평일 이른 아침', 'caution'),
  ('북서울꿈의숲',      127.0430, 37.6205, 'plaza_park', '{stair,ledge,flat}',          'intermediate', 'marble_tile',     'good', true,  'medium', '평일 저녁',      'active'),
  ('용산가족공원',      126.9800, 37.5240, 'plaza_park', '{flat,manual_pad}',           'beginner',     'smooth_concrete', 'fair', false, 'low',    '주말 오후',      'active'),
  ('문화비축기지',      126.8920, 37.5700, 'street',     '{bank,ledge,flat}',           'intermediate', 'rough_concrete',  'fair', false, 'medium', '평일 낮',        'active'),

  -- 광장 / 스트리트 계열 — 제지 위험 높음
  ('서울시청 광장',     126.9779, 37.5663, 'street',     '{flat,ledge,stair}',          'intermediate', 'marble_tile',     'good', true,  'high',   '주말 새벽',      'caution'),
  ('광화문광장',        126.9769, 37.5720, 'street',     '{flat,stair,ledge}',          'advanced',     'marble_tile',     'good', true,  'banned', '없음',           'no_skating'),
  ('청계광장',          126.9784, 37.5690, 'street',     '{stair,ledge}',               'advanced',     'marble_tile',     'good', true,  'high',   '새벽',           'caution'),
  ('DDP 동대문',        127.0092, 37.5665, 'street',     '{bank,ledge,hubba,stair}',    'advanced',     'marble_tile',     'good', true,  'high',   '평일 새벽',      'active'),
  ('홍대 걷고싶은거리', 126.9236, 37.5551, 'street',     '{curb,flat,stair}',           'intermediate', 'brick_tile',      'poor', true,  'high',   '평일 이른 아침', 'active'),
  ('연세대 백양로',     126.9388, 37.5665, 'street',     '{stair,handrail,ledge}',      'advanced',     'marble_tile',     'good', true,  'medium', '방학 중',        'active'),
  ('이화여대 ECC',      126.9469, 37.5620, 'street',     '{stair,ledge,bank}',          'advanced',     'marble_tile',     'good', true,  'high',   '방학 주말',      'caution'),

  -- 하천변
  ('양재천',            127.0430, 37.4870, 'street',     '{flat,bank,curb}',            'beginner',     'asphalt',         'fair', true,  'low',    '평일 저녁',      'active'),
  ('안양천',            126.8900, 37.5200, 'street',     '{flat,bank}',                 'beginner',     'asphalt',         'poor', false, 'low',    '주말 오전',      'active'),
  ('여의나루역 앞',     126.9325, 37.5270, 'street',     '{ledge,stair,flat}',          'intermediate', 'smooth_concrete', 'good', true,  'medium', '평일 밤',        'active'),

  -- 철거된 스팟 (지도에서 기본 숨김 — 상태 필터 테스트용)
  ('구 시민회관 계단',  126.9800, 37.5600, 'street',     '{stair,handrail}',            'advanced',     'marble_tile',     'fair', false, 'high',   '없음',           'removed'),

  -- 수도권 — 지도 이동/bbox 테스트용
  ('일산 호수공원',     126.7700, 37.6580, 'plaza_park', '{flat,curb,manual_pad}',      'beginner',     'smooth_concrete', 'good', true,  'low',    '평일 저녁',      'active'),
  ('분당 중앙공원',     127.1200, 37.3800, 'plaza_park', '{flat,stair,ledge}',          'intermediate', 'brick_tile',      'fair', true,  'medium', '평일 오후',      'active'),
  ('송도 센트럴파크',   126.6390, 37.3920, 'plaza_park', '{flat,ledge,bank}',           'beginner',     'smooth_concrete', 'good', true,  'low',    '주말 저녁',      'active'),
  ('수원 광교호수공원', 127.0600, 37.2850, 'plaza_park', '{flat,manual_pad}',           'beginner',     'smooth_concrete', 'good', true,  'low',    '평일 저녁',      'active')
) as d(name, lng, lat, spot_type, obstacles, difficulty, surface, quality, lighting, kickout, best_time, status);

select count(*) || '개 시드 입력됨' as result
  from spots where created_by = '00000000-0000-0000-0000-00000000dead';
