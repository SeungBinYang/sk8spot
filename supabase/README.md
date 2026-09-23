# Supabase — Phase 2 ✅ 적용 완료

설계 근거: [DATA_MODEL](../docs/DATA_MODEL.md) · [TRUST_AND_MODERATION](../docs/TRUST_AND_MODERATION.md)

| | |
|---|---|
| 프로젝트 | **sk8spot** (`udirqulcxuixelzagvpg`) |
| 조직 | SeungBinYang's Org (Free) |
| 리전 | **Northeast Asia (Seoul)** `ap-northeast-2` |
| 적용 상태 | 0001~0004 ✅ · 검증 테스트 ✅ 전체 통과 (2026-09-18) · `submit_report` 5종 제보 앱 경로 실증 (2026-09-23) |

생성된 것: 테이블 5, 정책 다수(`spots` 5개), 함수 8, 운영 뷰 3, PostGIS 확장.

> **슬롯 메모**: 무료 플랜은 계정당 활성 프로젝트 2개다.
> 자리를 만들려고 `gym-ai-routine`을 일시정지했다 (1년 내 restore 가능).

| 파일 | 내용 |
|---|---|
| `migrations/0001_schema.sql` | 확장·enum·테이블·인덱스·RLS·시스템 컬럼 가드 |
| `migrations/0002_functions.sql` | 지도 조회 RPC, 등록/제보 RPC, 상태 전이 트리거, 운영 뷰 |
| `migrations/0003_auth.sql` | 가입 시 프로필 자동 생성 트리거, 탈퇴/닉네임 변경 RPC |
| `migrations/0004_storage.sql` | `spot-photos` 버킷(public) + 읽기/업로드 정책 |
| `migrations/0005_share.sql` | 공유 스팟 1건·즐겨찾기 목록 조회 RPC. `spot_pin` 비회원 호출 HTTP 200 확인, 즐겨찾기 로그인 경로는 미검증 |
| `functions/spot-link/` | 공개 HTTPS 공유 링크 랜딩. 아직 원격 배포 전 |
| `config.toml` | 공개 랜딩 함수의 JWT 검증 해제. 랜딩은 읽기 전용 |
| `functions/kakao-oidc/` | 카카오 OIDC 코드→토큰 교환 Edge Function (client_secret 서버 보관) — [ARCHITECTURE.md](../docs/ARCHITECTURE.md#️-supabase-내장-kakao-프로바이더의-함정--account_email-강제) |
| `tests/moderation_test.sql` | 상태 전이 규칙 검증 (전부 롤백됨) |

## 적용 방법

Supabase 프로젝트를 만든 뒤 **SQL Editor**에 순서대로 붙여넣고 실행한다.

```
0001_schema.sql  →  0002_functions.sql  →  tests/moderation_test.sql
```

로컬 개발(`supabase start`)은 Docker가 필요한데 이 머신에는 없다.
현재로서는 **Supabase 프로젝트의 SQL Editor가 유일한 실행 경로**다.

> Supabase 가입은 GitHub 또는 이메일로 되고 **휴대폰 본인확인이 없다.**
> (NCP에서 막혔던 것과 다르다)

## Phase 7 공유 링크 적용 순서

1. `spot_pin`은 원격에서 비회원 호출 HTTP 200으로 확인됐다(2026-09-23). `my_favorite_spots`은 로그인 계정으로 별도 확인한다.
2. `spot-link` 함수를 `sk8spot` 프로젝트에 배포한다. 이 함수는 공개 웹 링크이므로
   `config.toml`의 `verify_jwt = false` 설정이 적용돼야 한다.
3. 브라우저에서 `https://udirqulcxuixelzagvpg.supabase.co/functions/v1/spot-link?id=1`을 열어
   HTTP 200과 "앱에서 스팟 열기" 버튼을 확인한다.
4. 확인 후 앱 빌드에
   `--dart-define=SPOT_SHARE_BASE_URL=https://udirqulcxuixelzagvpg.supabase.co/functions/v1/spot-link`
   를 추가한다. 그 전의 빌드는 설치 앱용 커스텀 스킴을 공유한다.

이 환경에는 Supabase CLI와 배포 자격 증명이 없어 `spot-link` 배포는 진행하지 않았다. 현재 해당 URL은 HTTP 404다.
공개 랜딩은 앱 출시 전이므로 설치되지 않은 기기에는 출시 안내를 보여준다.
## 실제 적용에서 테스트가 잡은 버그 2개

둘 다 **에러 없이 조용히 틀리는** 종류였다. 테스트가 없었으면 Phase 6까지 못 잡았을 것이다.

**(1) `still_there` 복구가 영원히 안 걸림**

`apply_spot_report`는 BEFORE INSERT 트리거라 **지금 넣는 행이 아직 테이블에 없다.**
`cant_skate` 쪽은 `+1`로 보정했는데 `still_there` 쪽에 빠뜨려서, 2번째 제보 시점에도
count가 1이라 `caution → active` 복구가 절대 발동하지 않았다.

같은 자리에서 하나 더 — 제보자를 셀 때 본인을 제외하지 않아 **월이 바뀌면 한 사람이
2명으로 세어졌다.** 혼자서 스팟 상태를 되돌릴 수 있는 구멍이다.
양쪽 모두 `and r.reporter_id <> new.reporter_id` + `+1` 로 고쳤다.

**(2) 마이그레이션 재실행 불가**

함수는 `create or replace`인데 트리거는 아니라 두 번째 실행에서
`trigger "spot_reports_apply" already exists`로 죽었다.
`drop trigger if exists`를 붙여 재실행 가능하게 만들었다.

## 검증 — 반드시 테스트까지 돌릴 것

`tests/moderation_test.sql`이 통과해야 모더레이션이 실제로 동작하는 것이다.
`✓` 3줄이 notice로 찍히고 에러가 없으면 통과.

특히 이 테스트는 **다음 회귀를 잡는다**:

`guard_spot_system_columns`(사용자가 `status`를 직접 못 바꾸게 막는 트리거)가
`apply_spot_report`(제보 누적으로 `status`를 바꾸는 트리거)의 변경까지 되돌려버리는 문제.
둘 다 `spots`에 걸려 있어서, 가드가 무조건 `old.status`를 복원하면
**제보가 아무리 쌓여도 상태가 절대 안 바뀐다 — 그런데 에러는 하나도 안 난다.**

해결책은 트랜잭션 로컬 GUC 플래그다.

```sql
-- apply_spot_report 안에서
perform set_config('app.system_update', '1', true);   -- is_local = true
```

```sql
-- guard_spot_system_columns 안에서
if coalesce(current_setting('app.system_update', true), '') = '1' then
  return new;   -- 시스템 업데이트는 통과
end if;
```

`is_local = true`라 트랜잭션이 끝나면 사라지고, 클라이언트가 세션에 미리 심어둘 수 없다.

## 설계상 확인 포인트

| 항목 | 왜 중요한가 |
|---|---|
| `spots` / `spot_photos` select에 **`anon` 포함** | 빠지면 [비회원 열람 흐름(F1)](../docs/USER_FLOWS.md)이 통째로 깨진다 |
| `status`·`*_count`를 클라이언트가 못 씀 | 가드 트리거가 막는다. RLS만으로는 컬럼 단위 제약이 어렵다 |
| `gone` 제보는 자동 전환 **안 함** | 계정 3개 담합으로 멀쩡한 스팟이 지도에서 사라지는 걸 막는다 |
| 제보 dedup 유니크 인덱스 | `date_trunc(text, timestamptz)`는 STABLE이라 인덱스에 못 쓴다. `at time zone 'UTC'`로 IMMUTABLE로 만들어야 한다 |
| `spot_reports`를 지우지 않음 | 자동 전이의 근거이자 감사 로그 |

## 아직 안 한 것

- **시드 데이터** — 수도권 스팟 150~300개. [콜드스타트 전략](../docs/DEVELOPMENT_ROADMAP.md#콜드-스타트-전략) 참조.
  개발용 30개도 아직 없다 (좌표를 실제로 확인해서 넣어야 해서 임의 생성이 무의미)
- **Storage 버킷 + 정책** — 사진 업로드는 Phase 5
- **카카오 OAuth 프로바이더 설정** — Phase 4
- 성능 측정 (`spots_in_bbox` 200ms 이내) — 데이터가 들어간 뒤
