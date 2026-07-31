---
name: add-task
description: "구두·문서 요청으로 Task 티켓을 빠르게 추가. 버그 fix·검증·누락 작업 등 스토리 분석 없이 단건(또는 소수) 생성. 스토리키가 있으면 story-to-spec과 동일한 규칙으로 링크, 없으면 standalone. --deep 옵션으로 국소 코드 스캔."
argument-hint: "[스토리키] <설명 또는 문서_URL/경로> [--deep]"
marketplace: false
---

# Add-Task — 추가 작업 티켓 빠른 생성

## 목적

스토리 전면 분석 없이, **구두·문서 요청으로 Task 티켓을 빠르게 추가**한다.
버그 fix, 검증/테스트, 누락 작업 등 스프린트 도중 튀어나오는 작업용.

`/story-to-spec`이 "스토리 → 여러 Task 일괄"이라면, 이 스킬은 **"요청 하나 → Task 하나(또는 소수)"** 다.
티켓 템플릿·링크 규칙·생성 절차·`/implement` 연계는 story-to-spec과 **동일한 컨벤션**을 재사용한다.

## 대상 구조 (필수 선행 지식)

np-enterprise는 phase 2에서 `sdk`를 3패키지로 분리했다. **신구조가 기본이다:**

```
np-client (client/src/np_client/) ──HTTP──▶ backend (backend/src/pynp/)
   thin CLI, core-free                        API·DB·오케스트레이션
                                                   │ event
np-common (common/src/np_common/)                  ▼
   이벤트·DTO 계약 공유              np-engine (engine/src/np_engine/)
                                       compute, core 허용, 이벤트 소비

[legacy] sdk/src/ — 이관 원본. 읽기 전용 (명시적 sdk 요청일 때만 수정)
```

> **티켓 초안을 만들기 전에 읽는다:**
> `~/.claude/skills/story-to-spec/references/np-enterprise-structure.md`
> (폴백: `~/claude-skills/story-to-spec/references/np-enterprise-structure.md`)
>
> 키워드→경로 라우팅(§3), 패키지 귀속 판정 트리(§4), `Module:` 허용값(§7)이 여기 있다.

## 파이프라인 위치

```
/story-to-spec  → 스토리 → Task 여러 개
/add-task       → 구두·문서 요청 → 버그/검증/추가 Task    ← 이 스킬
/implement      → 티켓 → 브랜치 → 구현 → PR
```

## 사용법

```
# 스토리 하위에 추가 (설명 = 구두)
/add-task NPP02-6517 "np-analyze 빈 입력 시 크래시 fix"

# 스토리 하위에 추가 (설명 = 문서)
/add-task NPP02-6517 https://github.com/nota-github/np-product-docs/blob/main/bugs/np-analyze-crash.md

# standalone (스토리 생략 — 긴급 버그 등)
/add-task "CI에 np-analyze 회귀 테스트 추가"

# 국소 코드 스캔 포함 (변경 대상·완료조건을 코드 근거로 채움)
/add-task NPP02-6517 "np-analyze 빈 입력 크래시 fix" --deep
```

- **첫 인자가 이슈 키 형태(`NPP02-XXXX`)면 부모 스토리**, 아니면 설명으로 간주.
- 설명 자리에는 구두 텍스트, 문서 URL(GitHub/Confluence), 로컬 `.md` 경로 모두 허용.
- `--deep`: 관련 코드를 국소적으로 읽어 티켓을 채운다. (기본은 스캔 없음)

---

## 전체 흐름

```
1. 입력 파싱     — 스토리키(옵션) + 설명/문서 + --deep 여부
2. 소스 로딩     — 설명이 문서면 WebFetch/getConfluencePage/Read
3. 의도 파악     — 무엇을/왜 + 티켓 성격(fix / 검증 / 작업)
   └ --deep 이면 관련 파일 국소 스캔 → 변경 대상·완료조건 채움
4. 최소 질문     — 요구사항 층위로 애매한 부분만 짧게 (없으면 생략)
5. 초안 제시     → 사용자 확인
6. 티켓 생성     — createJiraIssue(type "작업") → editJiraIssue(description)
7. 스토리 링크   — 스토리 있으면 Task→Story Blocks (없으면 생략)
8. 브랜치 기록   → 결과 보고 (→ /implement 로 이어짐)
```

---

## Step 1: 입력 파싱

인자를 다음으로 분해한다:

| 요소 | 판별 | 예 |
|------|------|-----|
| 부모 스토리 | 첫 토큰이 `PROJ-숫자` 또는 Jira URL | `NPP02-6517` |
| 설명/문서 | 나머지 텍스트 / URL / 경로 | `"...크래시 fix"` |
| `--deep` | 플래그 존재 | 국소 코드 스캔 on |

- 스토리 키가 없으면 → **standalone Task** (부모/링크 없음).
- 부모 스토리가 있으면 → 담당자/스프린트/에픽을 상속하기 위해 `getJiraIssue`로 스토리를 조회.

## Step 2: 소스 로딩 (설명이 문서일 때)

설명 자리가 URL/경로면 로딩한다. (story-to-spec Step 1-0과 동일한 로더)

| 소스 타입 | 로딩 방법 |
|----------|----------|
| Confluence 페이지 | `mcp__atlassian__getConfluencePage` |
| GitHub MD | `WebFetch` (raw URL; 로컬 클론 있으면 `Read`) |
| 로컬 .md | `Read` |

## Step 3: 의도 파악

설명/문서에서 다음을 추출:

- **무엇을** 해야 하는가 (한 문장)
- **왜** 필요한가 (버그 재현 조건 / 검증 목적 등)
- **티켓 성격**: `fix`(버그 수정) / `test`(검증·테스트) / `task`(일반 추가 작업)
- **패키지 귀속**: Client / Backend / Engine / Common / SDK(legacy) / DB Migration / CI
  → 참조 파일 §4 판정 트리로 결정. **애매하면 Step 4에서 묻는다** (charter #5·#6)

### `--deep` 일 때만: 국소 코드 스캔

대상이 명확할 때 관련 파일만 좁게 읽어 티켓을 보강한다. (story-to-spec의 전면 분석과 달리 **국소**)

1. 참조 파일 §3 라우팅 표로 **어느 패키지·경로를 볼지** 결정 (신구조 기본)
2. 설명의 키워드로 관련 파일 grep/glob (로컬 체크아웃 없으면 `gh` — 참조 파일 §9)
3. 변경 지점(파일:라인) 파악
4. 변경 대상 표 + 구체적 완료조건 작성
5. Client 대상이면 **core-free 위반 여부 확인** (torch·`np_*` 필요 → engine 소속)

> 코드 구현 방식(A/B·레이어·레거시 처리)은 **묻지 않고 Agent 재량**. np enterprise repo 훅이 품질을 보장한다. (story-to-spec과 동일 철학)

## Step 4: 최소 질문 (필요 시)

요청이 명확하면 **질문 없이** 초안으로 간다.
요구사항 층위에서 애매한 게 있을 때만 `AskUserQuestion`으로 짧게:

- "이 버그, 재현 조건이 {A}인가요 {B}인가요?"
- "검증 범위가 {단위 테스트}인가요 {E2E}인가요?"

**패키지 귀속이 애매할 때도 묻는다** (요구사항 층위 예외 — repo `client/docs/migration-charter.md`
원칙 #5·#6이 "경계 결정은 위임 금지 → escalate"로 명시):

- "이 작업, client에서 끝나나요 engine 호출로 가나요? (core 연산이 걸리면 engine)"
- "이 기능은 아직 `sdk/`에만 있습니다. client로 이관할까요, sdk에서 고칠까요?"

> **묻지 않는 경우** (참조 파일 §4 예외): core 의존이 명백(→engine), 순수 CLI 옵션·문구(→client),
> 순수 엔드포인트·스키마(→backend). 이때는 판정 후 근거만 티켓에 기록한다.
>
> **코드 구현 세부는 묻지 않는다.** 요구사항·패키지 귀속이 애매할 때만 최소한으로.

## Step 5: 초안 제시 → 확인

아래 템플릿으로 초안을 만들어 사용자에게 보여주고 확인받는다.

### 티켓 Description 템플릿 (story-to-spec 슬림 버전)

```markdown
## 🧩 Task의 이유 (Why)

* {이 작업이 필요한 이유 — 버그 증상 / 검증 목적 등}
* 관련 스토리: {스토리_키} - {스토리 제목}   ← standalone이면 생략
* 출처: {문서 링크 — 있으면}

## 🛠 작업 설명 (What)

* {무엇을 해야 하는지}

<!-- --deep 일 때만 아래 표. 경로는 해당 패키지 기준 (신구조) -->
### 변경 대상
| 파일 | 변경 내용 |
|------|----------|
| `client/src/np_client/.../xxx.py:45` | {수정 내용} |

<!-- Engine: engine/src/np_engine/... | Backend: backend/src/pynp/...
     Common: common/src/np_common/... | 레거시 대조: sdk/src/... (읽기 전용) -->

## ✅ 완료 조건 (Acceptance Criteria)

* [ ] {검증 가능한 조건}
* [ ] {Client 티켓} 아키텍처 테스트 통과 — `pytest client/tests/architecture` (core-free)
      <!-- Engine 티켓이면: pytest engine/tests/architecture (no-legacy-import) -->
* [ ] 기존 테스트 통과 (regression 없음)

## ➕ 특이사항

* 🔀 Branch: `feat/{티켓키}-{slug}`   ← 생성 후 채움
* Module: {Client | Backend | Engine | Common | SDK(legacy) | DB Migration | CI}
* 성격: {fix | test | task}
* 담당자: {상속 or 지정}
* {Common 티켓이면} 계약 소비처: {client / backend / engine 중 영향받는 쪽}
```

### 제목 규칙

성격을 태그로 구분한다:

| 성격 | 제목 예 |
|------|--------|
| 버그 수정 | `[SWE][fix] np-analyze 빈 입력 크래시 수정` |
| 검증·테스트 | `[SWE][test] np-analyze 회귀 테스트 추가` |
| 일반 작업 | `[SWE] np-analyze 출력 포맷 옵션 추가` |

여러 작업이 섞여 있으면 → **나눠서 목록으로 확인** 후 일괄 생성.

## Step 6: 티켓 생성

story-to-spec Step 2-3과 동일한 MCP 호출.

1. **담당자 ID 조회** (지정 시): `mcp__atlassian__lookupJiraAccountId`
2. **티켓 생성**:
   ```
   mcp__atlassian__createJiraIssue
   - cloudId: "nota-dev.atlassian.net"
   - projectKey: "{프로젝트 키}"
   - issueTypeName: "작업"
   - summary: "{제목}"
   - assignee_account_id: "{담당자 ID}"
   - additional_fields:
     - parent: "{에픽 키 — 스토리에서 상속, 있으면}"
     - labels: ["software-engineering"]
   ```
3. **Description + Sprint 적용**:
   ```
   mcp__atlassian__editJiraIssue
   - cloudId: "nota-dev.atlassian.net"
   - issueIdOrKey: "{생성된 티켓 키}"
   - contentFormat: "markdown"
   - fields:
     - description: "{템플릿 내용}"
     - customfield_10020: {Active Sprint ID — 스토리에서 상속, 있으면}
   ```

## Step 7: 스토리 링크 (⚠️ story-to-spec과 동일)

**스토리 키가 있을 때만.** 방향은 story-to-spec과 **완전히 동일**하게 사용:

```
mcp__atlassian__createIssueLink
- cloudId: "nota-dev.atlassian.net"
- outwardIssue: "{생성된 Task 키}"    ← Task (blocks 쪽)
- inwardIssue: "{스토리 키}"           ← Story (is blocked by 쪽)
- type: "Blocks"
```

→ Jira UI 결과: Task 화면 "blocks Story", Story 화면 "is blocked by Task"
→ ⚠️ 절대 outward/inward를 바꾸지 말 것. **outwardIssue가 항상 Task.**

standalone(스토리 없음)이면 이 단계를 건너뛴다.

## Step 8: 브랜치 기록 & 결과 보고

- 브랜치명: `feat/{티켓키}-{slug}` (slug: 제목에서 `[SWE]`·`[fix]`·`[test]` 제거 → 소문자 → `-` → 40자)
- 티켓 Description `## ➕ 특이사항`에 `🔀 Branch:` 기록 (실제 생성은 `/implement`가 수행)

```markdown
## ✅ 작업 티켓 생성 완료

| 티켓 | 제목 | 성격 | 부모 | 브랜치 | 링크 |
|------|------|------|------|--------|------|
| NPP02-XXXX | [SWE][fix] {제목} | fix | NPP02-6517 | `feat/NPP02-XXXX-{slug}` | [바로가기](...) |

→ 구현: `/implement NPP02-XXXX`
```

---

## 담당자/스프린트/에픽 결정

- **부모 스토리가 있으면** → 스토리의 담당자/스프린트/에픽을 상속 (기본).
- **standalone이거나 상속값이 없으면** → `AskUserQuestion`으로 수집.

## 주의사항

- **링크 규칙은 story-to-spec과 100% 동일** — outwardIssue=Task, inwardIssue=Story, "Blocks". 바꾸지 말 것.
- 기본은 가볍게(설명→티켓). **`--deep`일 때만 코드를 읽는다.**
- **요구사항·패키지 귀속이 애매할 때만** 질문. 코드 구현 세부는 묻지 않는다 (Agent 재량 + 훅).
- **신구조가 기본** (`client`/`backend`/`engine`/`common`). 레거시 `sdk/`는 명시적 요청일 때만.
- 한 티켓은 **하나의 Module**. 두 패키지에 걸치면 나눠서 확인 후 일괄 생성.
- 요청에 여러 작업이 섞이면 나눠서 확인 후 일괄 생성.
- 티켓 생성 후 **반드시 editJiraIssue로 description 적용** (MCP 제약).
- standalone 티켓은 부모/스프린트가 없을 수 있으므로 사용자에게 확인.

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 부모 스토리 조회(상속값)
- `mcp__atlassian__getConfluencePage`: Confluence 문서 소스
- `WebFetch`: GitHub MD 등 외부 문서 소스
- `Read` / `Grep` / `Glob`: 로컬 문서 + `--deep` 국소 코드 스캔 + 구조 참조 파일 로딩
- `gh` (CLI): 로컬 체크아웃이 없을 때 코드 확인 (참조 파일 §9)
- `mcp__atlassian__createJiraIssue`: Task 생성
- `mcp__atlassian__editJiraIssue`: description/sprint 적용
- `mcp__atlassian__lookupJiraAccountId`: 담당자 ID 조회
- `mcp__atlassian__createIssueLink`: 스토리 링크

## 관련 스킬

| 스킬 | 관계 |
|------|------|
| `/story-to-spec` | 티켓 템플릿·링크 규칙·생성 절차를 공유. 이 스킬은 그 경량 단건 버전 |
| `/implement` | 생성된 티켓을 넘겨 브랜치→구현→PR 자동화 (후속 단계) |
