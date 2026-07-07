---
name: story-to-spec
description: "Jira 스토리를 깊이 분석하여 구현 수준 상세 티켓 생성. Explore(스토리 이해 + 코드 분석 + 사용자 대화) → Spec(설계 + 티켓 일괄 생성). 복잡한 요구사항을 실제 작업 가능한 명세로 변환."
argument-hint: "<스토리_티켓_키_또는_URL>"
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
/story-to-spec NPP02-6517
/story-to-spec https://nota-dev.atlassian.net/browse/NPP02-6517
```

## 전체 흐름

```
Phase 1: EXPLORE (대화형)
  ├─ 1-1. 스토리 읽기 (Jira MCP)
  ├─ 1-2. 코드 영향 범위 분석 (코드베이스 탐색)
  ├─ 1-3. 사용자 대화 (질문 + 시각화)
  └─ 1-4. 분석 요약 제시 → 사용자 확인
           │
           ▼
Phase 2: SPEC & TICKET (자동)
  ├─ 2-1. 설계 명세 생성 (내부 참고용)
  ├─ 2-2. 티켓 목록 생성 → 사용자 확인
  ├─ 2-3. Jira 티켓 일괄 생성
  └─ 2-4. 브랜치 자동 생성 (feat/{티켓키}-{slug})
```

---

## Phase 1: EXPLORE

> 목표: 스토리를 충분히 이해하고, 코드 레벨에서 영향 범위를 파악하고, 사용자가 놓친 부분을 잡아낸다.

### Step 1-1: 스토리 읽기

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

**파싱 결과를 내부적으로 구조화:**

```
story:
  key: NPP02-6517
  goal: "..."
  background: "..."
  acceptance_criteria:
    - "AC1: ..."
    - "AC2: ..."
  modules_mentioned: [SDK, Backend, ...]
  participants: [...]
```

### Step 1-2: 코드 영향 범위 분석

스토리에서 언급된 기능/모듈을 기반으로 코드베이스를 탐색한다.

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

### Step 1-3: 사용자 대화

분석 결과를 바탕으로 사용자에게 **능동적으로 질문**한다.

#### 질문 유형

**A. 스토리 모호함 해소:**
- "AC에 '{기능}'이 있는데, 현재 코드에는 {관련 구조}가 이렇게 되어 있습니다. {A 방식}과 {B 방식} 중 어떤 접근이 맞나요?"
- "스토리에서 '{모듈}'을 언급하는데, 이 기능은 현재 {기존 구현 상태}입니다. 새로 만드는 건가요, 기존 것을 수정하는 건가요?"

**B. 놓치기 쉬운 부분 지적:**
- "이 변경을 하면 {관련 기능}에도 영향이 갈 수 있는데, 범위에 포함해야 할까요?"
- "Backend에 {엔드포인트}도 변경이 필요해 보이는데, 스토리에 언급이 없습니다. 포함할까요?"
- "DB 스키마 변경이 필요한데, 마이그레이션 티켓을 별도로 만들까요?"

**C. 기술적 결정 확인:**
- "헥사고날 이관이 안 된 레거시 코드({파일})를 건드려야 합니다. 이관 포함할까요, 레거시 패턴으로 수정할까요?"
- "외부 모듈 {모듈명}의 버전이 {현재 버전}인데, 이 기능은 {필요 버전} 이상에서 지원됩니다. 버전 업데이트도 포함할까요?"

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

Explore 결과를 구조화하여 제시한다:

```markdown
## 분석 요약

### 스토리 이해
- **Goal**: {한 문장 요약}
- **핵심 변경**: {무엇이 바뀌는지}

### 영향 범위
| 영역 | 변경 대상 | 유형 |
|------|----------|------|
| SDK Domain | workspace port | 메서드 추가 |
| SDK Application | workspace init service | 로직 변경 |
| SDK CLI | workspace init command | 옵션 추가 |
| Backend | experiment entity | 컬럼 추가 |
| Backend | experiment controller | 엔드포인트 수정 |
| DB Schema | experiments 테이블 | ALTER TABLE |

### 주의사항
- {발견된 리스크나 의존성}
- {아키텍처 결정 사항}

### 티켓 분할 방향
- SDK 티켓 N개 (Domain → Application → Adapter 순서)
- Backend 티켓 M개
- (필요 시) DB 마이그레이션 티켓 1개

이 방향으로 티켓을 생성할까요?
```

**사용자가 확인하면 Phase 2로 진행한다.**
**수정 요청이 있으면 해당 부분을 반영하여 다시 제시한다.**

---

## Phase 2: SPEC & TICKET

> 목표: Phase 1의 분석을 기반으로 Jira Task 티켓을 생성한다. 각 티켓은 Agent가 바로 작업 가능한 수준의 맥락을 담는다.

### Step 2-1: 설계 명세 생성 (내부 참고)

Phase 1의 분석 결과를 바탕으로 내부적으로 설계 방향을 정리한다. 이 내용은 티켓 본문에 녹여넣기 위한 것이지 별도 문서를 생성하지는 않는다.

정리할 내용:
- 아키텍처 레이어별 변경 계획
- 참고할 레퍼런스 구현 (예: workspace 도메인)
- 구현 순서 (의존성 기반)
- 각 티켓의 구현 순서 (Description에 명시)

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

- Phase 1에서 **반드시 사용자 확인**을 거친 후 Phase 2로 진행
- 스토리 AC에 없는 작업을 추론하여 추가하되, **반드시 사용자에게 확인** 후 포함
- SDK/Backend 영향을 판단할 때 **코드를 실제로 읽어서** 판단 (추측 금지)
- 외부 모듈 분석이 필요한 경우 호스트 경로가 없으면 **컨테이너 경로를 사용자에게 확인**
- 티켓 생성 후 **반드시 editJiraIssue로 description을 적용** (MCP 제약)

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 스토리 정보 조회
- `mcp__atlassian__createJiraIssue`: Task 티켓 생성
- `mcp__atlassian__editJiraIssue`: 티켓 내용 수정 (description 적용)
- `mcp__atlassian__lookupJiraAccountId`: 담당자 ID 조회
- `mcp__atlassian__searchJiraIssuesUsingJql`: 스프린트/관련 이슈 검색
- `mcp__atlassian__createIssueLink`: 티켓 간 링크 생성
