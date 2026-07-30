# np-enterprise 구조 참조 (단일 진실 원천)

> 티켓 스킬 4종(`story-to-spec` / `add-task` / `update-ticket` / `implement`)이 공유하는 구조 지식.
> 구조가 또 바뀌면(예: 레거시 `sdk/` 삭제) **이 파일만** 수정한다.
>
> 기준: `nota-github/np-enterprise` `dev` 브랜치 (2026-07-30 확인)

## 1. 패키지 지도

phase 2에서 `sdk`가 3패키지(`np-client` / `np-engine` / `np-common`)로 분리되었다.
이관은 strangler 방식이라 **`sdk/`는 아직 살아 있다.**

| 패키지 | 경로 | 성격 | 수정 대상? | 아키텍처 근거 문서 |
|---|---|---|---|---|
| `np-client` | `client/src/np_client/` | thin CLI. **core-free** — backend HTTP만 호출, 무거운 연산 없음 | ✅ | `client/README.md`, `client/docs/migration-charter.md` |
| `backend` | `backend/src/pynp/` | HTTP API·DB·인증·잡 오케스트레이션. MQTT/CloudEvent 구독 | ✅ | `backend/CLAUDE.md` |
| `np-engine` | `engine/src/np_engine/` | compute 실행체. core 의존 **허용**. 이벤트 소비 | ✅ | `engine/README.md` |
| `np-common` | `common/src/np_common/` | 이벤트·인증·fingerprint 계약 공유 wheel | ✅ | — |
| `sdk` (레거시) | `sdk/src/` | 이관 원본 | ⚠️ 읽기 전용 (§8) | `sdk/CLAUDE.md`, `sdk/src/CLAUDE.md`, `sdk/src/adapter/inbound/cli/CLAUDE.md` |

### 레이어 구조 (신 3패키지 공통 — 헥사고날, per-file class)

```
client/src/np_client/
  domain/{d}/{dto,entity,exception,port}       # 순수 도메인 (외부 의존 없음)
  application/{domain}/{action}/               # use-case (usecase 포트 + service)
  adapter/inbound/cli/                         # Typer CLI (main, terminal, wiring, {domain}/commands)
  adapter/outbound/{backend_http,auth_local,auth_store,local_file,...}
  common/exception/                            # ClientError 계열
  config/

engine/src/np_engine/
  domain/{d}/{dto,entity,exception,port}
  application/{domain}/{action}/
  adapter/inbound/api/                         # FastAPI 진입점
  adapter/inbound/worker/                      # 이벤트 consumer
  adapter/inbound/message/                     # consumer runner·event handler·CloudEvent 역직렬화
  adapter/outbound/                            # core/backend/broker 어댑터
  common/exception/                            # EngineError 계열

common/src/np_common/{auth,fingerprint,messaging}
```

### engine 진입점 (`ENGINE_ROLE`)

같은 이미지에서 env로 진입점을 고른다 (`np-engine-${ENGINE_ROLE}`).

| `ENGINE_ROLE` | console script | 형태 | 소비 방식 |
|---|---|---|---|
| `worker` | `np-engine-worker` | 장기 실행 데몬 (기본/롤백 경로) | `basic_consume` 구독 (`np.worker`) |
| `api` | `np-engine-api` | FastAPI 서버 | - |
| `oneshot` | `np-engine-oneshot` | one-shot (KEDA `ScaledJob`) | `basic_get` 1건 → 처리 → ack → 종료 |

`oneshot`은 `worker`와 consumer/handler/application service/outbound를 **공유**하고,
"메시지를 어떻게 가져오고 언제 종료하는가"만 다르다. 소비 큐는 `ENGINE_WORKER_QUEUE`(필수).
상세 계약은 `engine/src/np_engine/adapter/inbound/message/one_shot_message_runner.py` 모듈 docstring.

## 2. 데이터 흐름

```
np-client ──HTTP──▶ backend ──event(CloudEvent/broker)──▶ np-engine
(thin CLI,          (API·DB·오케스트레이션)  ◀──event(상태 회신)──
 core-free)                    │
                               └── np-common: 이벤트·DTO 계약 공유 (양쪽이 의존)

[legacy] sdk/ — 이관 원본. strangler 방식으로 아직 살아있음 (읽기 전용 parity 근거)
```

client는 backend를 **HTTP 단방향**으로 부른다 (`adapter/outbound/backend_http`).
backend ↔ engine은 **이벤트 양방향** (backend가 잡을 흘리고, engine이 상태를 회신).

## 3. 키워드 → 탐색 경로 라우팅

**신구조 열이 기본이다.** 레거시 열은 "기존에 어떻게 동작했나"를 대조할 때만 읽는다.

| 키워드 | 신구조 (기본) | 레거시 대조 |
|---|---|---|
| CLI 명령어, `np run`, `np workspace` | `client/src/np_client/adapter/inbound/cli/` | `sdk/src/adapter/inbound/cli/` |
| 출력 포맷·렌더링·터미널 UX | `client/src/np_client/adapter/inbound/cli/terminal*` | `sdk/src/adapter/inbound/cli/` |
| backend 호출·API 클라이언트 | `client/src/np_client/adapter/outbound/backend_http/` | `sdk/src/adapter/outbound/` |
| API, 엔드포인트, 인증, 잡 생명주기 | `backend/src/pynp/` | (동일) |
| DB 스키마·마이그레이션 | `backend/src/pynp/domain/`, migration | (동일) |
| quantize, optimize, profile, evaluate | `engine/src/np_engine/` + 외부 core 모듈 | `sdk/src/` |
| worker, 이벤트 소비, oneshot, KEDA | `engine/src/np_engine/adapter/inbound/{worker,message}/` | — |
| 이벤트 스키마, 공유 DTO 계약, fingerprint | `common/src/np_common/{messaging,auth,fingerprint}/` | `sdk/src/common/` |
| 모델·데이터셋·실험 도메인 | `client/src/np_client/domain/`, `backend/src/pynp/domain/`, `engine/src/np_engine/domain/` | `sdk/src/domain/` |

## 4. 패키지 귀속 판정 트리

```
torch·np_quantizer_v2·np_hw_common 등 core 연산 필요?  → engine
사용자 CLI 진입점·출력 렌더링?                        → client
HTTP API·DB·인증·잡 오케스트레이션?                   → backend
이벤트 스키마·DTO 계약을 양쪽이 공유?                 → common (계약 먼저)
─────────────────────────────────────────────────────
thin/thick 경계, 소유권, engine 호출 여부가 걸리면    → ❌ 결정 금지 → 사용자에게 escalate
```

**escalate가 원칙이다.** repo의 `client/docs/migration-charter.md`가 명시한다:

- 원칙 #5 — "패키지 귀속 우선 분류. 애매하면 **결정 금지 → flag 목록화 후 확인**"
- 원칙 #6 — "책임 경계 판단은 위임 대상 아님. 소유권·thin/thick·engine 호출 여부 등 경계 결정은 **escalate**"

즉 패키지 귀속은 "코드 구현 세부"가 아니라 **요구사항 층위의 의사결정 지점**으로 취급한다.

**예외** — 아래는 묻지 않고 판정 후 근거만 기록한다:
- core 의존이 명백히 필요 (torch 등) → engine
- 순수 CLI 옵션 추가·출력 문구 변경 → client
- 순수 엔드포인트/스키마 변경 → backend

## 5. 패키지별 규율 요약

### 공통 (신 3패키지 — sdk 규율 승계)

- 모든 파일 최상단 `from __future__ import annotations`
- **파일당 클래스 1개**, 클래스명 ↔ 파일명 snake_case 매핑
- `__init__.py`는 **완전히 빈 파일**
- 같은 하위패키지 내부는 relative import (`.`, `..`), 레이어 교차는 `np_client.`/`np_engine.` absolute
- dict 반환/파라미터 금지, Union 금지(`Optional` / `| None`), 다중상속 금지
- Port는 ABC + `@abstractmethod`, 본문 `raise NotImplementedError()`
- DTO는 pydantic `BaseModel`, Result DTO는 factory classmethod
- application은 `{domain}/{action}/` 그룹 (예: `health/ready/`)
- 싱글톤 라인 `foo = FooService()` / wiring은 인바운드 포트 타입 힌트
- 사용자 노출 텍스트=영어, 주석·docstring=한글 허용

### `client` — core-free (엄격)

`torch`, `np_quantizer_v2`, `np_hw_common`, `np_ir_manager`, `np_graph_*`, `np_compiler`,
`np_profiler`, `np_core_kit` 등 **core 의존 import 금지**.

강제 테스트: `client/tests/architecture/test_core_free.py`, `test_layer_dependencies.py`

### `engine` — core 허용, 레거시 차단

core import는 **허용**. 대신 구 sdk-flat 레이아웃(`adapter`/`application`/`domain`/`common`/`config`
최상위 bare import) 유입 **금지**.

강제 테스트: `engine/tests/architecture/test_no_legacy_import.py`, `test_layer_dependencies.py`

### 레퍼런스 수직 슬라이스 (새 유스케이스는 이 흐름을 복제)

- client: `cli(commands/ready) → wiring(health_wiring) → HealthReadyService(usecase) → BackendHealthCheckPort ← BackendHealthClient → HealthCheckResult`
- engine: `HealthReadyService(usecase) → HealthCheckPort ← LocalHealthCheck → HealthCheckResult`

## 6. 티켓 분할 규칙

1. **패키지 경계마다 별도 티켓** — 같은 AC라도 client / backend / engine / common 각각 분리
2. **크로스 패키지 기능은 계약 우선 순서**:
   `common(계약) → backend(API) → client(CLI) ∥ engine(worker)`
   (client와 engine은 계약이 정해지면 병렬 가능)
3. **DB 스키마 변경은 별도 티켓** — 마이그레이션 절차가 다름
4. 아키텍처 레이어 단위로 묶기 (한 티켓이 Domain+Application+Adapter 포함 가능, 너무 크면 분할)
5. 하나의 티켓은 1-3일 내 완료 가능한 크기
6. `common` 계약을 바꾸는 티켓은 **소비처(client·engine·backend) 동시 영향**을 특이사항에 명시

## 7. `Module:` 필드 허용값 (스킬 간 공유 계약)

```
Client | Backend | Engine | Common | SDK(legacy) | DB Migration | CI
```

- **쓰는 쪽** (`story-to-spec`, `add-task`) — 위 표기를 사용한다.
- **읽는 쪽** (`implement`, `update-ticket`) — 기존 티켓엔 `Module: SDK`가 그대로 쓰여 있으므로
  `SDK`와 `SDK(legacy)`를 **동일하게 취급**한다.
- 한 티켓은 하나의 Module을 갖는다. 두 패키지에 걸치면 §6-1에 따라 티켓을 쪼갠다.

## 8. 레거시 `sdk/` 취급

- **기본 읽기 전용.** 기존 동작·parity 근거로 읽되 수정 대상이 아니다.
- 스토리/요청이 **명시적으로 sdk 대상**일 때만 수정 대상으로 승격 (`Module: SDK(legacy)`).
- 기존 티켓·문서에 있는 `sdk/` 경로 서술은 **지우지 않는다.** 신구조 경로를 덧붙이고
  기존 행은 `(legacy 원본)`으로 표기한다.
- 이관 원칙(parity / deviation log / `# MIGRATION-KEEP` 마커)은 `client/docs/migration-charter.md` 참조.

## 9. ground-truth 확인 명령

로컬 체크아웃이 없어도 `gh`로 확인할 수 있다.

```bash
# 최상위 패키지 목록
gh api repos/nota-github/np-enterprise/git/trees/dev --jq '.tree[] | select(.type=="tree") | .path'

# 디렉토리 내용
gh api repos/nota-github/np-enterprise/contents/client/src/np_client?ref=dev --jq '.[].name'

# 파일 원문
gh api repos/nota-github/np-enterprise/contents/client/README.md?ref=dev --jq '.content' | base64 -d
```

> ⚠️ `gh api`에 `--ref` 플래그는 없다. `?ref=dev`를 경로에 붙인다.
