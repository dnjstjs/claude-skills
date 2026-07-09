---
name: story-to-spec
description: "Jira 스토리 + 외부 원천 소스(Confluence/spec MD)를 함께 깊이 분석하여 구현 수준 상세 티켓 생성. Explore(다중 소스 수집 + 코드 분석 + 요구사항 층위 대화) → Spec(설계 + 티켓 일괄 생성). 복잡한 요구사항을 실제 작업 가능한 명세로 변환."
argument-hint: "<스토리_티켓_키_또는_URL> [추가_소스_URL_또는_경로 ...]"
marketplace: false
---

# Story-to-Spec — 스토리 Deep Dive & 구현 명세 티켓 생성

## 목적

Jira 스토리를 **코드베이스 맥락과 함께 깊이 분석**한 뒤, Agent가 바로 작업할 수 있을 만큼 상세한 Task 티켓을 생성한다.

기존 `/create-tasks-from-story`가 AC를 기계적으로 매핑하는 반면, 이 스킬은:
- 스토리의 요구사항이 **현재 코드 구조에서 실현 가능한지** 검증
- SDK/Backend/외부 모듈의 **영향 범위를 코드 레벨로 파악**
- 사용자에게 **놓치기 쉬운 부분을 질문**하여 모호함 제거
- 최종 티켓에 **변경 대상 파일, 참고 패턴, 아키텍처 레이어별 작업**을 포함

## 사용법

```
# 스토리만
/story-to-spec NPP02-6517
/story-to-spec https://nota-dev.atlassian.net/browse/NPP02-6517

# 스토리 + 외부 원천 소스 (spec MD, Confluence 등)
/story-to-spec NPP02-6517 https://github.com/nota-github/np-product-docs/blob/main/specs/commands/np-analyze.md
/story-to-spec NPP02-6517 https://nota-dev.atlassian.net/wiki/spaces/XXX/pages/123456
```

> 인자로 스토리 뒤에 Confluence 페이지 URL, GitHub spec MD URL, 로컬 `.md` 경로를 여러 개 붙일 수 있다.
> 안 붙여도 Step 1-0에서 "추가 원천 소스가 있나요?"를 묻는다.

## 전체 흐름

```
Phase 1: EXPLORE (대화형 — 요구사항 층위)
  ├─ 1-0. 소스 수집 (스토리 + Confluence/spec MD/로컬 .md) → 통합 소스맵
  ├─ 1-1. 소스 읽기 & 요구사항 파싱 (출처별 traceability)
  ├─ 1-2. EXPLORE 루프 (코드 분석 ↔ 요구사항 질문 인터리빙)
  │        영역별 탐색 중 "요구사항 의사결정 지점" 만나면
  │        1-3. 즉시 멈추고 하나씩 질문 → 결정 로그에 기록 → 계속
  └─ 1-4. 분석 요약 + 결정 로그 제시 → 사용자 확인
           │
           ▼
Phase 2: SPEC & TICKET (자동)
  ├─ 2-1. 설계 명세 생성 (내부 참고용 — 코드 구현은 Claude가 결정)
  ├─ 2-2. 티켓 목록 생성 → 사용자 확인
  ├─ 2-3. Jira 티켓 일괄 생성 (결정 로그 + 출처 반영)
  └─ 2-4. 브랜치 정보 기록 (feat/{티켓키}-{slug})
```

---

## Phase 1: EXPLORE

> 목표: **원천 소스 전부**를 충분히 이해하고, 코드 레벨에서 영향 범위를 파악하고, **요구사항 층위에서** 사용자가 놓쳤거나 개발자가 더 잘 아는 부분을 대화로 잡아낸다.

### 상호작용 원칙 (이 스킬의 핵심)

이 스킬은 **요구사항을 사용자와 함께 확정**하는 것이 목적이다. 코드 구현은 Claude가 알아서 결정한다.

**✅ 멈춰서 물어야 하는 것 — "요구사항 의사결정 지점":**

1. 요구사항이 모호하거나 빠짐 (동작이 어때야 하나, 엣지 케이스, 기대 결과)
2. **소스 간 충돌** — 스토리 ↔ spec MD/Confluence 내용이 어긋남
3. 범위 경계 — AC엔 없지만 영향받는 부분 발견, 이번 스코프에 포함할지
4. 요구사항 우선순위 / 스코프 컷 — 뭘 넣고 뭘 뺄지
5. 도메인·비즈니스 규칙 — 개발자/기획이 스토리보다 잘 아는 맥락

→ 이런 지점을 만나면 **분석을 계속하기 전에 그 자리에서 즉시**, `AskUserQuestion`으로 **한 번에 하나씩** 묻는다. 요약에 몰아서 묻지 않는다.

**🤖 물어보지 말고 Claude가 알아서 결정하는 것 — 코드 구현 층위:**

- 아키텍처 레이어 배치 (Domain/Application/Adapter)
- 구현 방식 A/B 선택
- 레거시 수정 vs 헥사고날 이관
- 파일 구조, 네이밍, 패턴 선택

→ np enterprise repo의 **훅이 코드 품질을 보장**하므로, 구현 세부를 질문으로 사용자 시간을 뺏지 않는다. 코드 결정은 근거와 함께 티켓에 기록만 한다.

### Red Flags — 아래 생각이 들면 STOP

| 생각 | 현실 |
|------|------|
| "구현 방식 A/B, 어느 파일에 둘지 물어봐야지" | 코드 결정은 알아서 한다. 훅이 잡아준다. **요구사항만** 물어라 |
| "요구사항 명백하니 그냥 진행" | 명백해 보이는 게 기획/개발자 의도와 다를 때가 가장 많다. 확인하라 |
| "소스 다 읽었으니 알아서 통합" | 소스 간 충돌이 보이면 멈추고 어느 게 맞는지 물어라 |
| "AC에 없으니 스킵" | 영향 범위에 걸리면 AC에 없어도 물어라 |
| "질문 모아서 마지막 요약에" | 갈림길에서 즉시 하나씩 물어라. 요약에 몰면 이미 늦다 |

### Step 1-0: 소스 수집

스토리 외에 **더 중요한 원천 소스**(제품 spec MD, Confluence 설계 문서 등)가 있을 수 있다. 이걸 먼저 확보한다.

1. **인자로 받은 추가 소스 파싱** — 스토리 키/URL 뒤에 온 URL·경로를 모두 소스 후보로 등록.
2. **추가 소스 확인 질문** — 인자에 없어도 반드시 한 번 묻는다:
   > "스토리 외에 참고할 원천 소스가 있나요? (제품 spec MD, Confluence 문서, 로컬 .md 등 — 없으면 '없음')"
3. **소스 타입별 로딩:**

| 소스 타입 | 예시 | 로딩 방법 |
|----------|------|----------|
| Jira 스토리 | `NPP02-6517` | `mcp__atlassian__getJiraIssue` (항상) |
| Confluence 페이지 | `.../wiki/spaces/.../pages/123` | `mcp__atlassian__getConfluencePage` |
| GitHub spec MD | `github.com/nota-github/np-product-docs/blob/main/specs/...` | `WebFetch`로 raw URL 조회 (로컬 클론 있으면 파일 직접 Read) |
| 로컬 .md | `./docs/spec.md` | `Read` |

4. **고정 우선순위 없음** — 어느 소스가 진실의 원천인지 미리 정하지 않는다. 소스가 서로 어긋나면 상호작용 원칙 #2(소스 충돌)에 따라 **멈추고 물어본다.**

### Step 1-1: 소스 읽기 & 요구사항 파싱

수집된 **모든 소스**를 읽고, 요구사항을 출처와 함께 구조화한다. (스토리만이 아니라 spec MD/Confluence가 더 상세하거나 더 권위 있을 수 있음을 전제로 읽는다.)

Jira MCP로 스토리 정보를 가져온다.

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{입력된 스토리 키}"
```

가져올 정보:
- summary, description (Goal, Background, AC)
- labels, sprint, epic, assignee
- 하위 이슈 (이미 생성된 Task가 있는지)
- 연결된 이슈 (관련 스토리/버그)

**파싱 결과를 내부적으로 구조화 (요구사항마다 출처 표기):**

```
sources:
  - id: story
    type: jira
    ref: NPP02-6517
  - id: spec-md
    type: github_md
    ref: np-product-docs/specs/commands/np-analyze.md

requirements:
  goal: "..."                # 출처: story
  background: "..."          # 출처: story
  acceptance_criteria:
    - text: "AC1: ..."       # 출처: spec-md (스토리보다 상세)
    - text: "AC2: ..."       # 출처: story
  modules_mentioned: [SDK, Backend, ...]
  participants: [...]

source_conflicts:            # 소스 간 어긋난 지점 → 의사결정 지점 후보
    - topic: "..."
      story_says: "..."
      spec_md_says: "..."
```

### Step 1-2: EXPLORE 루프 (코드 분석 ↔ 요구사항 질문 인터리빙)

> **핵심: "분석 다 하고 → 마지막에 질문"이 아니다.** 영역별로 탐색하다 요구사항 의사결정 지점(위 상호작용 원칙 참조)을 만나면 **그 자리에서 멈추고 하나씩 묻고**, 답을 결정 로그에 기록한 뒤 다음 영역으로 넘어간다.

루프 한 바퀴:

```
for 각 탐색 영역 (SDK / Backend / 외부 모듈 / 소스 충돌 지점):
    1. 코드/소스를 읽어 영향 범위 파악        (아래 1-2-a ~ 1-2-c)
    2. 요구사항 의사결정 지점이 있는가?
         ├─ 있으면 → 즉시 AskUserQuestion (하나씩) → 결정 로그 기록
         └─ 코드 구현 갈림길이면 → 묻지 말고 Claude가 결정 + 근거 기록
    3. 다음 영역으로
```

요구사항 의사결정 지점 판단 기준은 **상호작용 원칙 ✅ 목록**을 그대로 따른다. 코드 구현 층위는 **🤖 목록**대로 알아서 결정한다.

#### 1-2-a. 대상 영역 식별

스토리의 Goal/AC에서 키워드를 추출하여 탐색 범위를 결정:

| 키워드 예시 | 탐색 대상 |
|------------|----------|
| CLI 명령어, `np run`, `np workspace` | `sdk/src/adapter/inbound/cli/` |
| API, 엔드포인트, 백엔드 | `backend/src/pynp/` |
| quantize, optimize, profile | `sdk/src/` + 외부 모듈 (np_quantizer, np_graph_optimizer 등) |
| 모델, 데이터셋, 실험 | `sdk/src/domain/`, `backend/src/pynp/domain/` |
| 보고서, 리포트 | `sdk/src/` (report 도메인) + `backend/` (report API) |

#### 1-2-b. 코드 탐색 수행

**SDK 분석** (스토리가 SDK 관련일 때):
1. 관련 도메인 디렉토리 구조 파악 (`sdk/src/domain/{domain}/`)
2. 기존 UseCase/Port/Service 목록 확인
3. CLI 커맨드 구조 확인 (`sdk/src/adapter/inbound/cli/{domain}/`)
4. Application Service 확인 (`sdk/src/application/{domain}/`)
5. 아키텍처 가이드 참조 (`sdk/CLAUDE.md`, `sdk/src/CLAUDE.md`)

**Backend 분석** (스토리가 Backend 관련일 때):
1. 관련 도메인 Entity/DTO 확인 (`backend/src/pynp/domain/`)
2. Controller/Router 확인 (`backend/src/pynp/application/`)
3. DB 스키마 영향 확인 (ERD, migration)
4. 아키텍처 가이드 참조 (`backend/CLAUDE.md`)

**외부 모듈 분석** (np- 패키지 연관 시):
- 스토리가 quantize/optimize/profile/evaluate 등 핵심 기능을 언급하면
- 관련 외부 모듈의 호스트 경로 또는 컨테이너 경로를 확인
- SDK에서 해당 모듈을 호출하는 진입점 파악 (`grep`으로 import 추적)

#### 1-2-c. 분석 결과 내부 축적

```
impact_analysis:
  sdk:
    domains_affected: [workspace, project]
    files_to_modify:
      - sdk/src/domain/workspace/port/workspace_port.py (새 메서드 추가)
      - sdk/src/application/workspace/init/workspace_init_service.py (로직 변경)
    files_to_create:
      - sdk/src/domain/workspace/dto/xxx_result.py
    architecture_layer: [Domain, Application, Adapter]
    reference_impl: "workspace 도메인이 가장 정합적 — 패턴 참고"

  backend:
    domains_affected: [experiment]
    files_to_modify:
      - backend/src/pynp/domain/experiment/entity/experiment.py
    db_schema_change: true
    api_endpoints_affected: [POST /api/v2/experiments]

  external_modules:
    - name: np_quantizer_v2
      reason: "스토리에서 quantize 설정 변경 언급"
      entry_point: sdk/src/domain/optimization/service/quantize_service.py
```

그리고 사용자와의 대화에서 확정된 요구사항 결정을 **결정 로그**에 누적한다. 이게 Phase 2 티켓에 그대로 반영된다:

```
decision_log:
  - topic: "np-analyze 출력 포맷"
    question: "스토리엔 JSON만, spec MD엔 table도 언급 — 둘 다 지원?"
    decision: "JSON 기본 + --format table 옵션 추가"
    source: spec-md (사용자 확인)      # 어느 소스/누구 근거인지
  - topic: "빈 입력 처리"
    question: "입력 파일 없을 때 동작?"
    decision: "에러 대신 빈 리포트 반환"
    source: 사용자 (도메인 규칙, 스토리·spec 모두 미언급)

code_decisions:                        # 물어보지 않고 Claude가 정한 구현 결정 (기록만)
  - "workspace 도메인 패턴 따라 Application Service 신규 생성"
  - "레거시 report.py는 이관 없이 기존 패턴 유지 (스코프 최소화)"
```

### Step 1-3: 요구사항 질문 (EXPLORE 루프 안에서 수시로)

> 이 질문들은 별도 단계가 아니라 **Step 1-2 루프 도중 의사결정 지점을 만날 때마다** 던진다. 한 번에 하나씩, `AskUserQuestion`으로.
> **요구사항 층위만 묻는다. 코드 구현 갈림길은 묻지 않는다.**

#### 물어야 할 질문 유형 (요구사항)

**A. 요구사항 모호함 해소:**
- "AC에 '{기능}'이 있는데 {동작/엣지케이스}가 명시돼 있지 않습니다. {기대 동작}은 무엇인가요?"
- "'{기능}' 실행 결과가 어떤 형태여야 하나요? ({출력 포맷/성공 기준})"

**B. 소스 간 충돌 (⚠️ 반드시 멈춤):**
- "스토리에는 '{X}'라고 돼 있는데, spec MD(`{경로}`)에는 '{Y}'로 돼 있습니다. 어느 쪽이 맞나요?"
- "Confluence 문서가 스토리보다 최신으로 보입니다. 이 부분은 문서 기준으로 갈까요?"

**C. 범위 경계 / 스코프:**
- "이 변경을 하면 {관련 기능}에도 영향이 갑니다. 이번 스코프에 포함할까요?"
- "{엔드포인트/기능}도 손봐야 할 것 같은데 어느 소스에도 언급이 없습니다. 이번에 포함할까요, 별도 스토리로 뺄까요?"

**D. 우선순위 / 스코프 컷:**
- "요구사항이 {N}개인데 이번 스프린트에 다 넣기 큽니다. {핵심 M개}만 먼저 하고 나머지는 후속으로 뺄까요?"

**E. 도메인·비즈니스 규칙:**
- "{도메인 개념}의 정확한 규칙이 소스에 없습니다. 실제로는 어떻게 동작해야 하나요? (개발자/기획이 아는 맥락)"

**❌ 묻지 않는다 (Claude가 알아서 — 훅이 품질 보장):**
- 어느 레이어에 둘지, A/B 구현 방식, 레거시 vs 이관, 파일 구조/네이밍 등 코드 구현 세부.
  이런 건 `code_decisions`에 근거만 기록하고 넘어간다.

#### 시각화

복잡한 영향 범위는 ASCII 다이어그램으로 보여준다:

```
  스토리 영향 범위
  ════════════════════════════════════════

  SDK                          Backend
  ┌─────────────────┐          ┌──────────────┐
  │ Domain          │          │ Domain       │
  │  └ workspace    │          │  └ experiment │
  │     └ port ★    │          │     └ entity ★│
  │                 │          │              │
  │ Application     │          │ Application  │
  │  └ workspace    │          │  └ controller★│
  │     └ init ★    │          │              │
  │                 │          │ DB Schema ★  │
  │ Adapter (CLI)   │          └──────────────┘
  │  └ workspace    │
  │     └ init ★    │
  └─────────────────┘
           │
           ▼
  External Module
  ┌─────────────────┐
  │ np_quantizer_v2 │
  │  └ (호출만, 수정X)│
  └─────────────────┘

  ★ = 변경 필요
```

### Step 1-4: 분석 요약 → 사용자 확인

Explore 결과를 구조화하여 제시한다. **"제가 이렇게 정했습니다"가 아니라 "우리가 함께 내린 결정"의 톤**으로, 대화에서 확정된 결정 로그를 앞세운다.

```markdown
## 분석 요약

### 참조한 소스
- 📄 스토리: NPP02-6517
- 📄 spec MD: np-product-docs/specs/commands/np-analyze.md
- 📄 Confluence: {제목}

### 요구사항 이해
- **Goal**: {한 문장 요약}
- **핵심 변경**: {무엇이 바뀌는지}

### ✅ 함께 내린 결정 (결정 로그)
| 주제 | 결정 | 근거(출처) |
|------|------|-----------|
| 출력 포맷 | JSON 기본 + --format table | spec-md (확인함) |
| 빈 입력 처리 | 빈 리포트 반환 | 사용자 (도메인 규칙) |

### 🤖 코드 구현 결정 (Claude가 결정 — 참고용)
- workspace 도메인 패턴 따라 Application Service 신규 생성
- 레거시 report.py는 이관 없이 기존 패턴 유지

### 영향 범위
| 영역 | 변경 대상 | 유형 |
|------|----------|------|
| SDK Domain | workspace port | 메서드 추가 |
| SDK Application | workspace init service | 로직 변경 |
| SDK CLI | workspace init command | 옵션 추가 |
| Backend | experiment entity | 컬럼 추가 |
| DB Schema | experiments 테이블 | ALTER TABLE |

### ⚠️ 남은 열린 질문 (있으면)
- {아직 확정 못한 요구사항 — 여기서 마저 묻는다}

### 티켓 분할 방향
- SDK 티켓 N개 / Backend 티켓 M개 / (필요 시) DB 마이그레이션 1개

이 결정과 방향으로 티켓을 생성할까요?
```

**"남은 열린 질문"이 있으면 여기서 마저 확정한 뒤 진행한다.**
**사용자가 확인하면 Phase 2로 진행한다.**
**수정 요청이 있으면 해당 부분을 반영하여 다시 제시한다.**

---

## Phase 2: SPEC & TICKET

> 목표: Phase 1의 분석을 기반으로 Jira Task 티켓을 생성한다. 각 티켓은 Agent가 바로 작업 가능한 수준의 맥락을 담는다.

### Step 2-1: 설계 명세 생성 (내부 참고)

Phase 1의 분석 결과를 바탕으로 내부적으로 설계 방향을 정리한다. 이 내용은 티켓 본문에 녹여넣기 위한 것이지 별도 문서를 생성하지는 않는다.

정리할 내용:
- **결정 로그(`decision_log`) → 각 티켓의 "요구사항 & 설계 결정" 섹션에 매핑** (출처 포함)
- 아키텍처 레이어별 변경 계획
- 참고할 레퍼런스 구현 (예: workspace 도메인)
- 구현 순서 (의존성 기반)
- 각 티켓의 구현 순서 (Description에 명시)
- `code_decisions`는 참고용으로만 기록 — 구현 방식은 Agent 재량

### Step 2-2: 티켓 목록 생성 → 사용자 확인

#### 티켓 분할 원칙

1. **SDK와 Backend는 반드시 분리** — 같은 AC라도 SDK/Backend 각각 별도 티켓
2. **DB 스키마 변경은 별도 티켓** — 마이그레이션 절차가 다름
3. **아키텍처 레이어 단위로 묶기** — 한 티켓이 Domain+Application+Adapter를 모두 포함 가능 (단, 너무 크면 분할)
4. **구현 순서 표시** — 티켓 Description에 권장 구현 순서 명시 (Jira 링크는 생성하지 않음)
5. **하나의 티켓은 1-3일 내 완료 가능한 크기**

#### 강화된 티켓 Description 템플릿

기존 `create-tasks-from-story`의 템플릿 구조(Why/What/AC/특이사항)를 유지하되, **구현 맥락을 대폭 강화**한다:

```markdown
## 🧩 Task의 이유 (Why)

* {스토리 Goal과 연결하여 이 작업이 필요한 이유}
* 관련 스토리: {스토리_키} - {스토리 제목}
* 원천 소스: {spec MD 경로 / Confluence 링크 등 — 있으면}

## 📌 요구사항 & 설계 결정 (Requirements)

> Phase 1의 결정 로그에서 이 티켓에 해당하는 항목을 옮긴다. **요구사항 중심** — 무엇을/왜, 어느 소스 근거인지.

| 결정 | 근거(출처) |
|------|-----------|
| {확정된 요구사항 동작} | {story / spec-md / 사용자} |
| {엣지 케이스 처리 방침} | {출처} |

* (코드 구현 방식은 Agent 재량 — np enterprise repo 훅이 품질 보장)

## 🛠 작업 설명 (What)

### 변경 대상

| 레이어 | 파일 | 변경 내용 |
|--------|------|----------|
| Domain | `sdk/src/domain/{domain}/port/{port}.py` | `{method_name}()` 메서드 추가 |
| Application | `sdk/src/application/{domain}/{usecase}/{service}.py` | 신규 생성 |
| Adapter | `sdk/src/adapter/inbound/cli/{domain}/commands/{cmd}.py` | 신규 커맨드 |

### 구현 가이드

* 아키텍처: {해당 영역의 아키텍처 규칙 요약}
  - 참조: `sdk/CLAUDE.md` (헥사고날 하네스)
  - 참조: `sdk/src/adapter/inbound/cli/CLAUDE.md` (CLI 규칙)
* 레퍼런스 구현: `sdk/src/domain/workspace/` (가장 정합적인 기준 구현)
* 구현 순서: Domain → Application → Adapter
* {추가 기술 맥락 — 외부 모듈 호출 방법, 기존 패턴 등}

### 외부 모듈 연관 (해당 시)

* 모듈: `np_quantizer_v2`
* SDK 진입점: `sdk/src/domain/optimization/service/quantize_service.py:45`
* 호출 패턴: {기존 코드의 호출 방식 설명}

## ✅ 완료 조건 (Acceptance Criteria)

* [ ] {구체적이고 검증 가능한 조건 1}
* [ ] {구체적이고 검증 가능한 조건 2}
* [ ] 기존 테스트 통과 (regression 없음)

## ➕ 특이사항

* 🔀 Branch: `feat/{티켓키}-{slug}`
* Module: {SDK | Backend | DB Migration}
* 참여자: {담당자}
* ⚠️ {주의사항 — 레거시 코드 존재, DB 마이그레이션 필요 등}
```

#### 사용자에게 테이블로 제시

```markdown
## 생성할 작업 티켓 목록

| # | 제목 | 영역 | 선행 | 주요 변경 |
|---|------|------|------|----------|
| 1 | [SWE] {작업 1} | SDK | - | Domain port 메서드 추가 |
| 2 | [SWE] {작업 2} | SDK | #1 | Application UseCase 구현 |
| 3 | [SWE] {작업 3} | SDK | #2 | CLI 커맨드 추가 |
| 4 | [SWE] {작업 4} | Backend | - | Entity 컬럼 + API 수정 |
| 5 | [SWE] {작업 5} | DB | #4 | 마이그레이션 스크립트 |

**설정:**
- 담당자: {담당자}
- 스프린트: {스프린트}
- 에픽: {에픽}

위 목록으로 티켓을 생성할까요? (수정이 필요하면 말씀해주세요)
```

### Step 2-3: Jira 티켓 일괄 생성

사용자가 확인하면 `create-tasks-from-story`와 동일한 Jira MCP 호출로 티켓을 생성한다.

#### 인터랙티브 설정 (옵션 미지정 시)

`AskUserQuestion`으로 담당자/스프린트/에픽을 수집한다. (기존 create-tasks-from-story와 동일)

#### 생성 절차

**각 티켓에 대해:**

1. **담당자 ID 조회** (최초 1회):
   ```
   mcp__atlassian__lookupJiraAccountId
   - cloudId: "nota-dev.atlassian.net"
   - searchString: "{담당자}"
   ```

2. **티켓 생성**:
   ```
   mcp__atlassian__createJiraIssue
   - cloudId: "nota-dev.atlassian.net"
   - projectKey: "{프로젝트 키}"
   - issueTypeName: "작업"
   - summary: "{티켓 제목}"
   - assignee_account_id: "{담당자 ID}"
   - additional_fields:
     - parent: "{에픽 키}"
     - labels: ["software-engineering"]
   ```

3. **Description + Sprint 적용** (MCP 제약 우회):
   ```
   mcp__atlassian__editJiraIssue
   - cloudId: "nota-dev.atlassian.net"
   - issueIdOrKey: "{생성된 티켓 키}"
   - contentFormat: "markdown"
   - fields:
     - description: "{강화된 템플릿으로 작성된 내용}"
     - customfield_10020: {Active Sprint ID}
   ```

4. **스토리 링크 연결** (⚠️ 방향 주의 — 반드시 아래 그대로 사용):
   ```
   mcp__atlassian__createIssueLink
   - cloudId: "nota-dev.atlassian.net"
   - outwardIssue: "{생성된 Task 키}"    ← Task (blocks 쪽)
   - inwardIssue: "{스토리 키}"           ← Story (is blocked by 쪽)
   - type: "Blocks"
   ```
   → Jira UI 결과:
     - Task 화면: "blocks Story"
     - Story 화면: "is blocked by Task"
   → ⚠️ 절대 outward/inward를 바꾸지 말 것. outwardIssue가 항상 Task.


### Step 2-4: 브랜치 정보 기록

티켓 Description에 브랜치명을 기록한다. 실제 브랜치 생성은 `/implement` 스킬에서 수행.

#### 브랜치 명명 규칙

```
feat/{티켓키}-{요약 slug}
```

- **slug 생성**: 티켓 제목에서 `[SWE]` 제거 → 소문자 → 공백/특수문자를 `-`로 → 40자 이내 truncate
- **예시**: `feat/NPP02-6559-aq-rngd-scheme`

#### 티켓에 기록

티켓 Description의 `## ➕ 특이사항` 섹션에 브랜치 정보를 포함:
```
* 🔀 Branch: `feat/{티켓키}-{slug}`
```

이 정보는 `/implement {티켓키}` 실행 시 자동으로 읽어 브랜치를 생성한다.

### 결과 보고

```markdown
## ✅ 작업 티켓 & 브랜치 생성 완료

**스토리:** {스토리 키} - {스토리 제목}

| # | 티켓 | 제목 | 영역 | 브랜치 | 링크 |
|---|------|------|------|--------|------|
| 1 | NPP02-XXXX | [SWE] {제목} | SDK | `feat/NPP02-XXXX-{slug}` | [바로가기](...) |
| 2 | NPP02-YYYY | [SWE] {제목} | SDK | `feat/NPP02-YYYY-{slug}` | [바로가기](...) |
| 3 | NPP02-ZZZZ | [SWE] {제목} | Backend | `feat/NPP02-ZZZZ-{slug}` | [바로가기](...) |

총 {N}개 티켓 생성 | 브랜치 생성: ✅ | 스토리 연결: ✅
```

---

## 환경변수

스토리 링크 자동 연결을 위해 환경변수 설정이 필요합니다:

```bash
export JIRA_EMAIL="your-email@nota.ai"
export JIRA_API_TOKEN="your-api-token"
```

API 토큰은 [Atlassian API 토큰 관리](https://id.atlassian.com/manage-profile/security/api-tokens)에서 생성.

---

## 기존 스킬과의 관계

| 스킬 | 역할 | 이 스킬과의 관계 |
|------|------|-----------------|
| `/create-tasks-from-story` | AC 기반 기계적 티켓 분할 | **이 스킬이 상위 호환**. 단순 스토리는 기존 스킬, 복잡한 스토리는 이 스킬 사용 |
| `/context-injection` | 코드 구조 분석 후 컨텍스트 축적 | Phase 1-2에서 동일한 분석을 수행 (별도 호출 불필요) |
| `/opsx:explore` | 자유 탐색형 대화 | Phase 1-3이 유사하나, 이 스킬은 스토리 기반으로 목적이 명확 |
| `/opsx:propose` | proposal/design/tasks 아티팩트 생성 | 이 스킬은 파일 아티팩트 대신 Jira 티켓을 직접 생성 |
| `/implement` | 티켓 → 브랜치 → 구현 → PR | **이 스킬의 후속 단계**. 생성된 티켓을 `/implement`에 넘겨 자동 구현 |
| `hex-orchestrator` | 헥사고날 구현 파이프라인 | `/implement`의 Agent가 SDK 구현 시 내부적으로 참조 |

## 주의사항

- **소스는 스토리 하나가 아니다.** Step 1-0에서 Confluence/spec MD/로컬 .md를 반드시 확인하고, 있으면 스토리와 동등 이상으로 취급 (spec MD가 더 권위 있을 수 있음)
- **소스 간 충돌은 절대 임의 통합 금지** — 멈추고 어느 쪽이 맞는지 물어라
- **요구사항은 사용자와 함께 확정, 코드 구현은 Claude가 결정** — 구현 방식 A/B·레이어 배치·레거시 처리 등은 묻지 않는다 (훅이 품질 보장)
- 요구사항 의사결정 지점은 **분석 도중 즉시** 하나씩 묻는다 (요약에 몰아서 X)
- Phase 1에서 **반드시 사용자 확인**을 거친 후 Phase 2로 진행
- 소스에 없는 작업을 추론하여 추가하되, **반드시 사용자에게 확인** 후 포함
- SDK/Backend 영향을 판단할 때 **코드를 실제로 읽어서** 판단 (추측 금지)
- 외부 모듈 분석이 필요한 경우 호스트 경로가 없으면 **컨테이너 경로를 사용자에게 확인**
- 티켓 생성 후 **반드시 editJiraIssue로 description을 적용** (MCP 제약)

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 스토리 정보 조회
- `mcp__atlassian__getConfluencePage`: Confluence 원천 문서 조회
- `WebFetch`: GitHub spec MD 등 외부 문서 조회 (raw URL)
- `Read`: 로컬 `.md` 소스 조회 (repo에 클론된 spec 포함)
- `mcp__atlassian__createJiraIssue`: Task 티켓 생성
- `mcp__atlassian__editJiraIssue`: 티켓 내용 수정 (description 적용)
- `mcp__atlassian__lookupJiraAccountId`: 담당자 ID 조회
- `mcp__atlassian__searchJiraIssuesUsingJql`: 스프린트/관련 이슈 검색
- `mcp__atlassian__createIssueLink`: 티켓 간 링크 생성
