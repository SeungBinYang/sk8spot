# 데이터 모델

> 이 문서는 **무엇을 저장하는가**를 다룬다. 상태를 **어떤 규칙으로 바꾸는가**는
> [TRUST_AND_MODERATION](TRUST_AND_MODERATION.md)에 있다.
>
> ⚠️ DDL은 [추천 스택](ARCHITECTURE.md#추천-조합)(Supabase / Postgres + PostGIS) 기준 **잠정 초안**이다.
> 스택이 확정되기 전까지 필드 설계만 유효하고 문법은 바뀔 수 있다.

## 1. 정보의 3계층

스팟 정보를 한 덩어리로 다루면 "누가 이 값을 바꿀 수 있는가"가 흐려진다. 세 층으로 나눈다.

### A. 사용자 직접 입력 — 등록자가 쓰고, 다른 사용자가 제보로 고친다

`name`, `geom`, `spot_type`, `obstacles[]`, `surface`, `surface_quality`,
`is_indoor`, `is_free`, `has_lighting`, `night_ok`, `best_time`, `description`, 사진

### B. 여러 사용자의 평가로 수렴하는 값 — 한 사람의 의견이 진실이 아니다

`difficulty`, `kickout_risk`

**MVP에서는 투표 UI를 만들지 않는다.** 등록자 입력값을 초기값으로 쓰고,
"정보가 틀려요" 제보가 쌓이면 운영자가 조정한다. 필드는 스팟 테이블에 두되,
나중에 `spot_attribute_votes` 테이블로 분리할 수 있게 의미만 구분해둔다.

> 지금 투표 시스템을 만들면 유저 10명일 때 표본 1~2개로 값이 튄다. 무의미하다.

### C. 시스템이 관리 — 사용자가 직접 쓰지 못한다

`id`, `status`, `last_verified_at`, `verify_count`, `open_report_count`,
`moderation_flag`, `created_by`, `created_at`, `updated_at`

## 2. Enum 정의

### `spot_type` (단일 선택) — 지도 아이콘·필터의 축

| 값 | 의미 | 중복 탐지 반경 |
|---|---|---|
| `skatepark` | 공식 스케이트파크 | 150m |
| `street` | 스트리트 스팟 (계단, 레일, 렛지 등) | 50m |
| `plaza_park` | 광장·공원 등 넓은 플랫 공간 | 150m |
| `diy` | DIY 스팟, 자체 제작 세팅 | 50m |

### `obstacle` (다중 선택) — 스케이터가 실제로 검색하는 단위

`stair`(계단) · `handrail`(핸드레일) · `flat_rail`(플랫레일) · `ledge`(렛지) ·
`curb`(커브) · `bank`(뱅크) · `manual_pad`(매뉴얼 패드) · `gap`(갭) ·
`quarter`(쿼터파이프) · `hubba`(허바) · `flat`(플랫그라운드)

> `spot_type`과 `obstacles`를 분리한 것이 핵심이다.
> 하나의 플랫 리스트로 만들면 "스케이트파크"와 "계단"이 같은 층위에 놓여 필터가 망가진다.
> 계단 수·레일 높이 같은 수치는 MVP에서 받지 않는다 — 사진과 `description`으로 충분하다.

### `surface` (바닥 재질) — 스케이트에서 결정적인 정보

`smooth_concrete`(매끈한 콘크리트) · `rough_concrete`(거친 콘크리트) ·
`marble_tile`(대리석·타일) · `asphalt`(아스팔트) · `brick_tile`(보도블럭) ·
`urethane`(우레탄, 파크) · `wood`(목재) · `metal`(철판) · `other`

### `surface_quality`

`good` / `fair` / `poor` — 갈라짐, 턱, 이물질, 모래를 포괄한 체감 등급

### `difficulty`

`beginner` / `intermediate` / `advanced`

### `kickout_risk` — 이 앱의 핵심 차별 필드

| 값 | 의미 |
|---|---|
| `low` | 거의 제지 없음 |
| `medium` | 가끔 제지, 시간대에 따라 다름 |
| `high` | 대부분 제지당함 |
| `banned` | 명시적 스케이트 금지 |
| `unknown` | 정보 없음 (기본값) |

일반 장소 앱에는 없는 필드다. **여기가 이 서비스의 존재 이유다.**

### `spot_status`

| 값 | 의미 | 지도 표시 | 전환 방법 |
|---|---|---|---|
| `active` | 정상 이용 가능 | 정상 마커 | 기본값 |
| `caution` | 이용 어려움 / 제지 위험 높음 | 반투명 + 경고 점 | 제보 누적 자동 |
| `temporarily_closed` | 공사 등 일시 불가 | 반투명 + 경고 점 | 제보 누적 자동 |
| `no_skating` | 스케이트 금지 구역 | 빗금 | **운영자 승인 필수** |
| `removed` | 철거·소멸 | 기본 숨김 | **운영자 승인 필수** |
| `hidden` | 운영자 비공개 (허위·권리침해) | 숨김 | 운영자만 |

"정보 확인 필요"는 상태가 아니라 `last_verified_at`에서 파생되는 **UI 배지**다.
상태 enum에 넣으면 전이 규칙이 불필요하게 복잡해진다.

### `report_kind`

`still_there`(아직 있어요) · `gone`(없어졌어요) · `cant_skate`(지금은 못 타요) ·
`wrong_info`(정보 틀림) · `wrong_location`(위치 틀림) · `duplicate`(중복) ·
`inappropriate`(부적절·허위 — 신고 경로)

## 3. ER 관계

```
auth.users (Supabase 관리)
    | 1:1
    v
 profiles ──1:N──> spots        (created_by)
    |               |
    |               ├──1:N──> spot_photos
    |               ├──1:N──> spot_reports
    |               └──1:N──> favorites  [Should]
    |                            ^
    └──1:N───────────────────────┘

spot_reports ──N:1──> profiles  (reporter_id)
spot_photos  ──N:1──> profiles  (uploaded_by)
```

- 한 유저는 여러 스팟을 등록한다
- 한 스팟은 여러 사진을 가진다 — **등록자 외 다른 유저도 추가할 수 있다** (중복 등록을 기여로 전환하는 경로)
- 한 스팟은 여러 제보를 받는다. **제보는 지워지지 않는다** — 자동 전환 규칙의 근거이자 감사 로그
- `favorites`는 유저 × 스팟 복합 PK

### MVP에서 만들지 않는 테이블

| 테이블 | 이유 |
|---|---|
| `spot_reviews` | 후기는 Could. 별점 리뷰는 Won't |
| `spot_attribute_votes` | 난이도·킥아웃 위험 투표. 유저 표본이 확보된 뒤 |
| `spot_edit_requests` | 필드 단위 수정 제안. `wrong_info` 제보로 대체 |
| `spot_visits` | 방문 인증. 위치 스푸핑 대응 비용이 크다 |
| `follows`, `comments`, `badges` | [MVP 범위 밖](MVP_SCOPE.md#wont--mvp에서-만들지-않는다) |

## 4. DDL 초안 (Postgres + PostGIS)

enum 타입 선언은 생략했다. 위 2절의 값이 그대로 `create type ... as enum`이 된다.

```sql
create extension if not exists postgis;

-- profiles ------------------------------------------------
create table profiles (
  id            uuid primary key references auth.users on delete cascade,
  nickname      text not null,                 -- 가입 시 자동 생성, 이후 변경 가능
  avatar_url    text,
  report_weight smallint not null default 1,   -- 허위 제보 누적 시 0으로 (조용히)
  is_admin      boolean not null default false,
  created_at    timestamptz not null default now()
);

-- spots ---------------------------------------------------
create table spots (
  id        bigint generated always as identity primary key,

  -- [A] 사용자 직접 입력
  name            text not null check (char_length(name) between 1 and 60),
  geom            geography(Point, 4326) not null,
  spot_type       spot_type not null,
  obstacles       obstacle[] not null default '{}',
  surface         surface,
  surface_quality surface_quality,
  is_indoor       boolean,
  is_free         boolean,
  has_lighting    boolean,
  night_ok        boolean,
  best_time       text,      -- 자유 입력. 시간대 구조화는 과하다
  description     text check (char_length(description) <= 1000),

  -- [B] 집계 대상 (MVP는 등록자 입력값 + 운영자 조정)
  difficulty   difficulty,
  kickout_risk kickout_risk not null default 'unknown',

  -- [C] 시스템
  status              spot_status not null default 'active',
  is_private_property boolean not null default false,
  last_verified_at    timestamptz not null default now(),
  verify_count        integer not null default 0,
  open_report_count   integer not null default 0,
  moderation_flag     text,   -- 'pending_duplicate' | 'new_account' | null
  created_by          uuid not null references profiles(id),
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

-- 지도 bbox 조회의 생명줄
create index spots_geom_idx on spots using gist (geom);
create index spots_visible_idx on spots (status)
  where status not in ('hidden', 'removed');

-- spot_photos ---------------------------------------------
create table spot_photos (
  id           bigint generated always as identity primary key,
  spot_id      bigint not null references spots(id) on delete cascade,
  uploaded_by  uuid   not null references profiles(id),
  storage_path text   not null,                  -- Storage 경로
  is_cover     boolean not null default false,
  is_hidden    boolean not null default false,   -- 신고 처리 시. 물리 삭제 안 함
  created_at   timestamptz not null default now()
);
create index spot_photos_spot_idx on spot_photos (spot_id) where not is_hidden;

-- spot_reports --------------------------------------------
-- 제보는 지우지 않는다. 자동 전환의 근거이자 감사 로그다.
create table spot_reports (
  id          bigint generated always as identity primary key,
  spot_id     bigint not null references spots(id) on delete cascade,
  reporter_id uuid   not null references profiles(id),
  kind        report_kind not null,
  memo        text check (char_length(memo) <= 300),
  photo_path  text,                              -- 철거 제보 시 증빙
  created_at  timestamptz not null default now(),

  resolved_at timestamptz,
  resolution  text,        -- 'accepted' | 'rejected' | 'auto_applied'
  resolved_by uuid references profiles(id)
);

-- 같은 유저가 같은 스팟에 같은 유형 제보를 반복해도 월 1건으로 센다.
-- date_trunc(text, timestamptz)는 STABLE이라 인덱스에 못 쓴다.
-- `AT TIME ZONE 'UTC'`로 timestamp로 바꾸면 IMMUTABLE이 되어 인덱스에 쓸 수 있다.
create unique index spot_reports_dedup_idx
  on spot_reports (spot_id, reporter_id, kind,
                   (date_trunc('month', created_at at time zone 'UTC')));

create index spot_reports_open_idx
  on spot_reports (spot_id, kind) where resolved_at is null;

-- favorites [Should] --------------------------------------
create table favorites (
  user_id    uuid   not null references profiles(id) on delete cascade,
  spot_id    bigint not null references spots(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_id, spot_id)
);
```

## 5. 조회 함수 초안

지도가 호출하는 유일한 핵심 쿼리. 클라이언트에 테이블을 직접 노출하지 않는다.

```sql
create or replace function spots_in_bbox(
  min_lng float8, min_lat float8, max_lng float8, max_lat float8,
  max_rows int default 200
)
returns table (
  id bigint, name text, lng float8, lat float8,
  spot_type spot_type, status spot_status,
  cover_path text, needs_verify boolean
)
language sql stable as $fn$
  select s.id, s.name,
         st_x(s.geom::geometry), st_y(s.geom::geometry),
         s.spot_type, s.status,
         (select p.storage_path from spot_photos p
           where p.spot_id = s.id and not p.is_hidden
           order by p.is_cover desc, p.created_at
           limit 1),
         s.last_verified_at < now() - interval '180 days'
    from spots s
   where s.status not in ('hidden', 'removed')
     and s.geom && st_makeenvelope(min_lng, min_lat, max_lng, max_lat, 4326)::geography
   order by s.last_verified_at desc
   limit max_rows;
$fn$;
```

중복 탐지용 근접 조회 ([등록 흐름](USER_FLOWS.md#f4-새로운-스팟을-등록하는-사람)에서 호출):

```sql
create or replace function spots_near(lng float8, lat float8, radius_m int)
returns setof spots
language sql stable as $fn$
  select * from spots
   where status not in ('hidden', 'removed')
     and st_dwithin(geom, st_point(lng, lat)::geography, radius_m)
   order by geom <-> st_point(lng, lat)::geography
   limit 10;
$fn$;
```

## 6. 접근 제어 (RLS 방향)

| 테이블 | 읽기 | 쓰기 |
|---|---|---|
| `spots` | 전체 공개 (`hidden` 제외). **비로그인 포함** | 로그인 사용자만 insert. update는 등록자 본인 + 운영자 |
| `spot_photos` | 전체 공개 (`is_hidden` 제외) | 로그인 사용자 insert. 삭제는 업로더 본인 + 운영자 |
| `spot_reports` | **본인 것 + 운영자만.** 일반 사용자는 집계 수치만 본다 | 로그인 사용자 insert. update는 운영자만 |
| `profiles` | `nickname`, `avatar_url`만 공개 | 본인만 |
| `favorites` | 본인만 | 본인만 |

두 가지가 중요하다.

1. **비로그인 열람이 RLS의 전제다.** `spots` / `spot_photos` select 정책에 `anon` 역할이 포함되어야 한다.
   이걸 빠뜨리면 [F1 흐름](USER_FLOWS.md#f1-처음-앱을-설치한-사람)이 통째로 깨진다
2. `status`, `last_verified_at`, `verify_count`, `open_report_count`는
   **클라이언트가 직접 쓰지 못한다.** 전부 서버 함수/트리거를 거친다
   → [TRUST_AND_MODERATION](TRUST_AND_MODERATION.md)

## 7. 저장하지 않는 것

| 항목 | 이유 |
|---|---|
| **사용자의 현재 위치** | 서버로 보내지 않는다. 지도 bbox만 보낸다. 개인정보 노출면을 원천 제거 |
| 위치 이력 / 이동 경로 | 수집하지 않는다 |
| **사진 EXIF GPS** | 업로드 전 클라이언트에서 제거. 촬영자의 집 위치가 새어나갈 수 있다 |
| 이메일 / 전화번호 | 소셜 로그인 식별자만 보관. 마케팅 수집 없음 |
| 실명 | 닉네임만 |
