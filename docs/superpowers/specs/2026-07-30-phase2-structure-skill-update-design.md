# Phase 2 구조(client–backend–engine) 스킬 반영 설계

- 날짜: 2026-07-30
- 대상 스킬: `story-to-spec`, `add-task`, `update-ticket`, `implement`
- 관련 스토리: NPP02-6891 (NP SDK CLIENT), NPP02-6892 (NP SDK ENGINE)

## 배경

`~/claude-skills`의 티켓 스킬 4종은 np-enterprise를 **`sdk/` + `backend/` 2축**으로 하드코딩하고 있다.
실제 `dev` 브랜치는 phase 2에서 sdk를 3패키지(`np-client` / `np-engine` / `np-common`)로 분리했고,
런타임 구조는 `client → backend → engine`이다.

이관은 strangler 방식이라 `sdk/`가 아직 살아 있다. 따라서 구구조를 **제거하지 않고**
"레거시 참조" 지위로 남긴 채 신구조를 기본값으로 올린다.

### 실제 구조 (`dev` 기준, gh로 확인)

| 패키지 | 경로 | 성격 | 아키텍처 근거 |
|---|---|---|---|
| `np-client` | `client/src/np_client/` | thin CLI. **core-free** (torch·`np_*` core wheel import 금지). backend HTTP만 호출 | `client/README.md`, `client/docs/migration-charter.md`, `client/tests/architecture/test_core_free.py` |
| `backend` | `backend/src/pynp/` | HTTP API·DB·인증·잡 오케스트레이션. MQTT/CloudEvent 구독 | `backend/CLAUDE.md` |
| `np-engine` | `engine/src/np_engine/` | compute 실행체. core 의존 **허용**. `ENGINE_ROLE`(worker/api/oneshot)로 진입점 선택, 이벤트 소비 | `engine/README.md`, `engine/tests/architecture/test_no_legacy_import.py` |
| `np-common` | `common/src/np_common/` | 이벤트·DTO 계약 공유 wheel | — |
| `sdk` (레거시) | `sdk/src/` | 이관 원본. 아직 존재 | `sdk/CLAUDE.md`, `sdk/src/CLAUDE.md`, `sdk/src/adapter/inbound/cli/CLAUDE.md` |

## 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| 1 | 수정 범위는 **4종** (`story-to-spec`·`add-task`·`update-ticket`·`implement`) | 티켓의 `Module:` 값이 늘어나면 `/implement`의 가이드 라우팅이 못 따라감 → 파이프라인 단절 |
| 2 | **신구조 기본 + `sdk`는 레거시 참조** | 신규 작업은 client/backend/engine/common 기준. sdk는 읽기 전용 parity 근거 |
| 3 | 구조 지식은 **공유 참조 파일 1개 + 스킬마다 짧은 요약** | 다음 변경(sdk 삭제 등) 시 1곳만 수정 |
| 4 | 패키지 귀속·책임 경계는 **질문 유형 F로 승급** (사용자에게 escalate) | repo `client/docs/migration-charter.md` 원칙 #5·#6 — 경계 결정은 위임 금지 |

결정 4의 예외: core-free 위반이 명백한 경우(torch 필요 → engine)는 묻지 않고 근거만 기록한다.

## 설계 A — 공유 참조 파일

신규 파일: `story-to-spec/references/np-enterprise-structure.md`

`story-to-spec` 아래에 두는 이유: `setup.sh`가 최상위 디렉토리를 전부 스킬로 symlink하므로
최상위 `shared/`는 빈 스킬로 잡힌다. 또한 `add-task`·`update-ticket`은 이미
"티켓 템플릿·링크 규칙을 story-to-spec에서 재사용"하는 컨벤션이라 참조 방향이 일관된다.

참조 경로는 `~/.claude/skills/story-to-spec/references/np-enterprise-structure.md`,
폴백 `~/claude-skills/story-to-spec/references/np-enterprise-structure.md`.

### 담을 내용

**1) 패키지 지도** — 위 "실제 구조" 표 (경로·성격·수정 가능 여부·아키텍처 근거 문서)

**2) 데이터 흐름**

```
np-client ──HTTP──▶ backend ──event(CloudEvent/broker)──▶ np-engine
(thin CLI,          (API·DB·오케스트레이션)  ◀──event(상태 회신)──
 core-free)                    │
                               └── np-common: 이벤트·DTO 계약 공유 (양쪽이 의존)

[legacy] sdk/ — 이관 원본. strangler 방식으로 아직 살아있음 (읽기 전용 parity 근거)
```

**3) 키워드 → 탐색 경로 라우팅** — 신구조 기본 / 레거시 대조 2열

| 키워드 | 신구조 (기본) | 레거시 대조 |
|---|---|---|
| CLI 명령어, `np run`, `np workspace` | `client/src/np_client/adapter/inbound/cli/` | `sdk/src/adapter/inbound/cli/` |
| API, 엔드포인트, 인증, 잡 생명주기 | `backend/src/pynp/` | (동일) |
| quantize, optimize, profile, evaluate | `engine/src/np_engine/` + 외부 core 모듈 | `sdk/src/` |
| worker, 이벤트 소비, oneshot, KEDA | `engine/src/np_engine/adapter/inbound/{worker,message}/` | — |
| 이벤트 스키마, 공유 DTO 계약 | `common/src/np_common/` | — |
| 모델·데이터셋·실험 도메인 | `client/src/np_client/domain/`, `backend/src/pynp/domain/`, `engine/src/np_engine/domain/` | `sdk/src/domain/` |

**4) 패키지 귀속 판정 트리**

```
torch·np_quantizer_v2·np_hw_common 등 core 연산 필요?  → engine
사용자 CLI 진입점·출력 렌더링?                        → client
HTTP API·DB·인증·잡 오케스트레이션?                   → backend
이벤트 스키마·DTO 계약을 양쪽이 공유?                 → common (계약 먼저)
─────────────────────────────────────────────────────
thin/thick 경계, 소유권, engine 호출 여부가 걸리면    → ❌ 결정 금지 → 질문 유형 F로 escalate
                        (migration-charter 원칙 #5·#6)
```

**5) 패키지별 규율 요약**

- 공통 (sdk 규율 승계): 파일 최상단 `from __future__ import annotations` / 파일당 클래스 1개 /
  `__init__.py` 완전 빈 파일 / dict 반환·파라미터 금지 / Union 금지(`Optional`·`| None`) /
  다중상속 금지 / Port는 ABC + `@abstractmethod` / DTO는 pydantic `BaseModel` /
  application은 `{domain}/{action}/` 그룹
- `client`: core-free. `torch`, `np_quantizer_v2`, `np_hw_common`, `np_ir_manager`,
  `np_graph_*`, `np_compiler`, `np_profiler`, `np_core_kit` import 금지.
  강제: `client/tests/architecture/test_core_free.py`
- `engine`: core import 허용. 구 sdk-flat 레이아웃 bare import(`adapter`/`application`/`domain`/
  `common`/`config`) 금지. 강제: `engine/tests/architecture/test_no_legacy_import.py`

**6) 티켓 분할 규칙** — 패키지 경계마다 별도 티켓.
크로스 패키지 기능은 계약 우선 순서: `common(계약) → backend(API) → client(CLI) ∥ engine(worker)`

**7) `Module:` 필드 허용값** (4개 스킬이 공유하는 계약)

```
Client | Backend | Engine | Common | SDK(legacy) | DB Migration | CI
```

기존 티켓에는 `Module: SDK`가 그대로 쓰여 있다. 읽는 쪽(`implement`·`update-ticket`)은
`SDK`와 `SDK(legacy)`를 **동일하게 취급**한다. 새로 쓰는 쪽(`story-to-spec`·`add-task`)만
`SDK(legacy)` 표기를 사용한다.

**8) 레거시 sdk 취급** — 기본 읽기 전용(parity·기존 동작 근거).
스토리가 명시적으로 sdk 대상일 때만 수정 대상으로 승격.

## 설계 B — 스킬별 변경

공통: 각 SKILL.md 상단에 4줄 구조 요약 + 참조 파일을 **Phase 시작 전 필수 Read**로 지시.

### 1. `story-to-spec/SKILL.md`

| 위치 | 변경 |
|---|---|
| L16 목적 | `SDK/Backend/외부 모듈` → `Client/Backend/Engine/Common(+레거시 sdk)/외부 모듈` |
| 상호작용 원칙 ✅ 목록 | 6번 "패키지 귀속·책임 경계" 신설 (질문 유형 F와 짝) |
| Red Flags | 1행 추가 — "client냐 engine냐 내가 정하지" → 경계는 escalate (charter #6) |
| L146 `modules_mentioned` | 새 허용값으로 |
| L162 EXPLORE 루프 영역 | `Client / Backend / Engine / Common / 외부 모듈 / 레거시 sdk 대조 / 소스 충돌` |
| L176-182 키워드 라우팅 | 신구조 기본 + 레거시 대조 2열 (상세는 참조 파일) |
| L186-202 영역별 분석 | `Client 분석`(core-free 검증 포함)·`Engine 분석`(ENGINE_ROLE·이벤트 소비) 신설. Backend 유지. sdk는 `레거시 sdk 대조 분석`으로 리네임 유지 |
| L204-229 `impact_analysis` | 키를 `client / backend / engine / common / legacy_sdk / external_modules`로 |
| L254-276 질문 유형 | **F. 패키지 귀속 / 책임 경계** 추가 |
| L282-309 다이어그램 | 3-tier + common 계약으로 교체 |
| L338-350 영향 범위·분할 방향 예시 | 신구조 예시로 |
| L379-385 분할 원칙 #1 | "SDK와 Backend 분리" → "패키지 경계마다 분리 + 크로스 패키지는 계약 우선 순서" |
| L413-426 템플릿 (변경 대상·구현 가이드) | 경로·참조 문서를 패키지별 분기 |
| L443 `Module:` | 새 허용값 |
| L455-459, L557-559 예시 표 | 신구조 예시로 |
| L598 주의사항 | "Client/Backend/Engine/Common 영향을 코드로 확인" + 경계 escalate 명시 |

**질문 유형 F 문안(안)**

- "이 작업은 CLI 진입점이라 client인데, 실제 연산이 core를 타면 engine으로 넘겨야 합니다.
  `{작업}`은 client에서 끝내나요, engine 호출로 가나요?"
- "`{기능}`이 client·engine 양쪽에 걸칩니다. 계약(`np-common`)부터 정의할까요?"

### 2. `add-task/SKILL.md`

- 상단 4줄 요약 + 참조 파일 링크
- Step 3 `--deep` 국소 스캔: 참조 파일의 라우팅 표·귀속 판정 트리를 쓰도록 지시
- Step 4 최소 질문: "요구사항만 묻는다" 원칙에 **패키지 귀속 애매 시 질문 예외** 추가
- L136 변경 대상 예시 경로 → `client/src/np_client/.../xxx.py:45`
- L146 `Module:` 허용값 갱신

### 3. `update-ticket/SKILL.md`

- 상단 4줄 요약 + 참조 파일 링크
- Step 4 ground-truth 검증에 **"구조 드리프트 대조"** 신설:
  기존 티켓이 `sdk/` 경로를 참조하면 `gh`로 신구조 대응 경로 존재 여부를 확인
- Step 5 충돌·공백 전형 예에 "구조 드리프트" 행 추가
- Step 6 재구성 규칙:
  - 낡은 `Module:` 값을 새 허용값으로 갱신
  - 신구조 경로를 추가하되 **기존 `sdk/` 행은 삭제하지 않고 `(legacy 원본)` 표기로 남긴다**
- 핵심 원칙 표에 1행 추가 — "구조는 덧붙인다, 지우지 않는다"

### 4. `implement/SKILL.md`

- L60 `Module:` 파싱 허용값 확장
- Step 4 가이드 라우팅 교체:

```
"Client"        → client/README.md (전문)
                  + sdk/src/CLAUDE.md (Python 코딩 규칙 — client가 sdk 규율 승계)
                  + client/docs/migration-charter.md (이관 성격 티켓일 때)
"Engine"        → engine/README.md (전문)
                  + sdk/src/CLAUDE.md (동일 이유)
                  + one_shot_message_runner.py docstring (oneshot 관련 티켓만)
"Common"        → 계약 변경 주의 + 소비처(client·engine·backend) 동시 영향 경고
"Backend"       → backend/CLAUDE.md 섹션 1~3          (기존 유지)
"SDK(legacy)"   → sdk/CLAUDE.md + sdk/src/CLAUDE.md   (기존 유지)
"DB Migration"  → backend/CLAUDE.md + 마이그레이션 절차 (기존 유지)
없음            → 참조 파일의 귀속 판정 트리로 추론
```

- Step 5 Agent 디스패치 검증 항목에 arch-test 추가:
  - Client 티켓 → `pytest client/tests/architecture` (core-free 강제)
  - Engine 티켓 → `pytest engine/tests/architecture` (레거시 import 차단)

## 검증

이 repo엔 자동 테스트가 없으므로 수동 점검 2개로 확인한다.

1. `grep -rn "sdk/src" --include=*.md .` — 남은 모든 하드코딩이 **의도적 legacy 표기**인지 전수 확인
2. `Module:` 허용값이 4개 SKILL.md + 참조 파일에서 **문자열 단위로 일치**하는지 대조

## 범위 밖

- `sdk/` 관련 서술 제거 — 명시적으로 유지 요청. strangler 이관이 끝난 뒤 별도 작업으로 정리
- np-enterprise repo 자체 수정 (루트 `README.md`의 Repository Structure가 아직 구구조지만 이 작업 범위 아님)
- `review` 스킬 — 이 repo에 없음 (CLAUDE.md 파이프라인 문서에만 언급)
