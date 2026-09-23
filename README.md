# Skate Spot (가칭)

> 스케이터가 직접 등록하고 함께 갱신하는 **스케이트 스팟 지도**

일반 지도 앱은 "이 장소가 무엇인가"를 알려주지만, 스케이터가 알아야 하는 것은
**"여기서 탈 수 있는가, 지금도 탈 수 있는가, 쫓겨나지 않는가"** 다.
이 앱은 그 정보만 다룬다.

## 현재 상태

Flutter + Kakao Maps + Supabase 앱. 기존 작업은 Phase 1~6의 주요 코드와 서버 검증까지 진행됐고,
Phase 7(공유·필터·저장)을 구현 중이다.

| 단계 | 상태 |
|---|---|
| Phase 0~2 | 기획, 지도 SDK 실기기 측정, DB 스키마 적용·검증 완료 |
| Phase 3~6 | 지도·상세·인증·등록·제보 코드 작성 및 일부 서버 경로 검증 완료. 실기기 확인 항목은 [로드맵](docs/DEVELOPMENT_ROADMAP.md)에 남아 있음 |
| Phase 7 | 필터·지명 검색·즐겨찾기·마지막 지도 위치·공유 링크 코드 작성. 공개 랜딩 배포와 기기 간 공유 검증 대기 |
| Phase 8~9 | 시드 데이터, 베타, 스토어 출시 미진행 |

남은 판단은 [결정 필요 사항](docs/OPEN_DECISIONS.md)에 있다.
## 문서

| 문서 | 역할 |
|---|---|
| [PRODUCT_REQUIREMENTS.md](docs/PRODUCT_REQUIREMENTS.md) | 서비스 정의, 문제, 페르소나, 경쟁 서비스와의 차이 |
| [MVP_SCOPE.md](docs/MVP_SCOPE.md) | MoSCoW 기반 기능 범위. 무엇을 만들고 무엇을 안 만드는가 |
| [USER_FLOWS.md](docs/USER_FLOWS.md) | 핵심 5개 사용자 흐름 (화면 → 행동 → 다음 화면) |
| [SCREEN_STRUCTURE.md](docs/SCREEN_STRUCTURE.md) | 화면 목록, 네비게이션, 지도 UX / 필터 설계 |
| [DATA_MODEL.md](docs/DATA_MODEL.md) | 스팟 데이터 구조, 상태 정의, DB 스키마 초안 |
| [TRUST_AND_MODERATION.md](docs/TRUST_AND_MODERATION.md) | 상태 갱신 규칙, 중복 방지, 신뢰도/운영 정책 |
| [ARCHITECTURE.md](docs/ARCHITECTURE.md) | 기술 스택 비교/추천, 지도 SDK, 위치 기반 처리 |
| [DEVELOPMENT_ROADMAP.md](docs/DEVELOPMENT_ROADMAP.md) | Phase별 개발 순서, 완료 조건, 콜드스타트 전략 |
| [OPEN_DECISIONS.md](docs/OPEN_DECISIONS.md) | 구현 전에 사람이 결정해야 하는 항목 |

## 코드

| 위치 | 내용 |
|---|---|
| [`app/`](app/README.md) | Flutter 앱 — 지도·상세·인증·등록·제보·Phase 7 기능 |
| [`supabase/`](supabase/README.md) | DB 스키마·RPC·상태 전이·공유 랜딩 함수·검증 SQL·개발용 시드 |

Phase 1 지도 SDK 스파이크(`spike/`)는 역할이 끝나 삭제했다.
클러스터링 구현은 `app/lib/cluster.dart`로 옮겼고, 측정 결과는
[DEVELOPMENT_ROADMAP Phase 1](docs/DEVELOPMENT_ROADMAP.md)에 기록돼 있다.

## 확인된 수치

| | |
|---|---|
| 지도 렌더 (마커 1000개, 실기기) | p95 **6.9ms** · janky 0.3% |
| bbox 조회 (서울 전역, 웜) | 중앙값 **55ms** |
| 비회원 쓰기 차단 | `spots` INSERT / `spot_reports` 읽기 / 운영 뷰 모두 **401** |

## MVP 한 줄

비회원이 앱을 열면 **3초 안에 주변 스팟이 지도에 보이고**, 로그인은 **등록·제보할 때만** 요구한다.
