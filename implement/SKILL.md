---
name: implement
description: "Jira 티켓(story-to-spec 생성)을 받아 브랜치 생성 → 백그라운드 Agent 구현 → 커밋 → push → PR 생성까지 자동 수행. 세션 끊겨도 백그라운드로 작업 완료."
argument-hint: "<티켓_키_또는_URL>"
marketplace: false
---

# Implement — 티켓 기반 자동 구현

## 목적

`/story-to-spec`으로 생성된 상세 티켓(또는 충분한 spec이 있는 일반 티켓)을 받아, 브랜치 생성부터 구현 → 커밋 → push → PR 생성까지 **백그라운드로 자동 수행**한다.

## 사용법

```
/implement NPP02-6559
/implement https://nota-dev.atlassian.net/browse/NPP02-6559
```

## 전체 흐름

```
Step 1: 티켓 읽기 (Jira MCP)
  │
Step 2: 인터랙티브 설정 (PR 대상 브랜치, 확인)
  │
Step 3: 브랜치 확인/생성
  │
Step 4: 아키텍처 가이드 수집 (티켓 영역 기반)
  │
Step 5: Agent 디스패치 (worktree, background)
  │      └─ 구현 → 테스트 → 커밋 → push → PR 생성
  │
Step 6: 결과 보고
```

---

## Step 1: 티켓 읽기

입력에서 티켓 키를 추출하고 Jira MCP로 정보를 가져온다.

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{티켓 키}"
- fields: ["*all"]
- responseContentFormat: "markdown"
```

**파싱할 내용:**
- `summary`: 티켓 제목
- `description`: 전체 spec (Why / What / AC / 특이사항)
- `labels`: 영역 판단용 (`software-engineering` 등)
- `parent`: 에픽 정보
- `issuelinks`: 선후행 관계

**Description에서 추출할 메타데이터:**
- `Module:` 필드 → SDK / Backend / DB Migration 판단
- `🔀 Branch:` 필드 → 이미 지정된 브랜치명 확인
- `선행 티켓:` 필드 → 선행 작업 완료 여부 확인

---

## Step 2: 인터랙티브 설정

`AskUserQuestion`으로 필요한 설정을 수집한다.

```
AskUserQuestion:
- questions:
  - question: "PR 대상 브랜치를 선택해주세요"
    header: "Base Branch"
    options:
      - label: "dev"
        description: "일반 개발 브랜치"
      - label: "staging"
        description: "릴리즈 준비 브랜치"
      - label: "직접 입력"
        description: "다른 브랜치명 지정"
    multiSelect: false
```

수집 항목:
- **PR 대상 브랜치**: `dev` / `staging` / 직접 입력

---

## Step 3: 브랜치 확인/생성

### 3-1. 브랜치명 결정

티켓 Description의 `🔀 Branch:` 필드에서 브랜치명을 가져온다. 없으면 자동 생성:

```
feat/{티켓키}-{slug}
```

- **slug 생성**: 티켓 제목에서 `[SWE]` 제거 → 소문자 → 공백/특수문자를 `-`로 → 40자 이내 truncate
- **예시**: `feat/NPP02-6559-aq-rngd-scheme`

### 3-2. 브랜치 존재 확인

```bash
# 원격에 이미 있는지 확인
git fetch origin
git ls-remote --heads origin "feat/{브랜치명}" | grep -q .
```

- **이미 존재**: 그대로 사용 (사용자에게 알림)
- **존재하지 않음**: 생성

### 3-3. 브랜치 생성 (존재하지 않을 때)

```bash
# base 브랜치 기준으로 생성
git fetch origin {base_branch}
git branch feat/{브랜치명} origin/{base_branch}
git push origin feat/{브랜치명}
```

---

## Step 4: 아키텍처 가이드 수집

티켓의 `Module:` 필드를 기반으로 Agent에게 주입할 아키텍처 가이드를 **직접 읽어서** 수집한다.

### SDK 영역 티켓일 때

다음 파일들을 Read로 읽어 Agent 프롬프트에 주입:

| 파일 | 내용 | 주입 방식 |
|------|------|----------|
| `sdk/CLAUDE.md` | 헥사고날 하네스, hex-orchestrator 파이프라인 | 전문 주입 |
| `sdk/src/CLAUDE.md` | Python 코딩 규칙, DTO/Service 패턴 | 전문 주입 |
| `sdk/src/adapter/inbound/cli/CLAUDE.md` | CLI 아키텍처 규칙 | CLI 관련 티켓만 주입 |

### Backend 영역 티켓일 때

| 파일 | 내용 | 주입 방식 |
|------|------|----------|
| `backend/CLAUDE.md` | 클린 아키텍처 가이드 | **섹션 1~3만** 주입 (전문은 42K 토큰으로 과대) |

### 주입 대상 판단 로직

```
Module 필드가:
  "SDK"      → sdk/CLAUDE.md + sdk/src/CLAUDE.md
  "Backend"  → backend/CLAUDE.md (섹션 1~3)
  "SDK+CLI"  → 위 SDK + cli/CLAUDE.md
  없음       → 티켓 제목/내용에서 키워드로 추론
```

---

## Step 5: Agent 디스패치

**핵심 단계.** 수집한 모든 정보를 조합하여 Agent를 worktree 격리 + 백그라운드로 실행한다.

### Agent 프롬프트 구성

```
Agent({
  description: "Implement {티켓키}: {티켓 제목 요약}",
  isolation: "worktree",
  run_in_background: true,
  prompt: "<아래 구성>"
})
```

**프롬프트에 포함할 내용 (순서대로):**

```markdown
# 작업 지시: {티켓키} - {티켓 제목}

## 1. 티켓 Spec

{Jira description 전문 — Why/What/AC/특이사항 모두 포함}

## 2. 아키텍처 가이드 (반드시 준수)

{Step 4에서 수집한 CLAUDE.md 내용}

## 3. 작업 규칙

### 구현
- 티켓의 "변경 대상" 테이블에 명시된 파일을 중심으로 구현
- "구현 가이드"에 명시된 순서(Domain → Application → Adapter)를 따를 것
- "레퍼런스 구현"으로 지정된 도메인의 패턴을 참고
- 아키텍처 가이드의 금지사항을 위반하지 말 것

### 테스트
- 구현한 코드에 대한 테스트를 작성
- 기존 테스트가 깨지지 않는지 확인: pytest 실행

### 커밋
- 커밋 메시지 형식: `feat: {한국어 설명}`
- 하나의 논리적 단위로 커밋 (너무 크면 분할)
- 커밋 전 반드시 `git diff` 로 변경사항 검토

### Push & PR
- 작업 완료 후 push:
  ```bash
  git push origin HEAD
  ```
- PR 생성:
  ```bash
  gh pr create --base {base_branch} --head feat/{브랜치명} \
    --title "[{티켓키}] {티켓 제목에서 [SWE] 제거}" \
    --body "$(cat <<'EOF'
  ## 🔍 PR의 이유
  {티켓의 Why 섹션}

  ## ✨ 주요 변경사항
  {티켓의 What 섹션 요약}

  ## ✅ 체크리스트
  - [ ] 아키텍처 가이드 준수
  - [ ] 테스트 작성 및 통과
  - [ ] 기존 테스트 regression 없음

  Resolves: https://nota-dev.atlassian.net/browse/{티켓키}
  EOF
  )"
  ```

### 금지사항
- dev, staging, main 브랜치에 직접 커밋 금지
- force push 금지
- 티켓 scope 밖의 변경 금지
```

---

## Step 6: 결과 보고

Agent 디스패치 직후 사용자에게 보고:

```markdown
## ✅ Agent 디스패치 완료

| 항목 | 값 |
|------|-----|
| 티켓 | {티켓키} - {티켓 제목} |
| 브랜치 | `feat/{브랜치명}` |
| Base | `{base_branch}` |
| 모드 | 백그라운드 (worktree 격리) |
| Jira | https://nota-dev.atlassian.net/browse/{티켓키} |

Agent가 백그라운드에서 작업 중입니다. 완료되면 자동으로 알림됩니다.

**완료 후 할 일:**
- PR 링크 확인
- `/review {티켓키}` 로 코드 리뷰
- `/agent-cleanup {티켓키}` 로 worktree 정리
```

### Agent 완료 후 보고

Agent가 완료되면 결과를 확인하여 보고:

```markdown
## 🏁 Agent 작업 완료: {티켓키}

| 항목 | 결과 |
|------|------|
| 구현 | ✅ / ❌ |
| 테스트 | ✅ 통과 / ❌ 실패 |
| 커밋 | {커밋 수}개 |
| Push | ✅ / ❌ |
| PR | {PR URL} |

**다음 단계:**
- PR 리뷰: {PR URL}
- Worktree 정리: `/agent-cleanup`
```

---

## 선행 티켓 체크

티켓 Description에 `선행 티켓:` 필드가 있으면, 해당 티켓의 상태를 확인:

```
mcp__atlassian__getJiraIssue
- issueIdOrKey: "{선행 티켓 키}"
- fields: ["status"]
```

- **완료(Done)**: 정상 진행
- **미완료**: 사용자에게 경고 후 진행 여부 확인
  ```
  ⚠️ 선행 티켓 {키}가 아직 완료되지 않았습니다.
  그래도 작업을 시작할까요?
  ```

---

## `/dispatch`와의 차이

| | `/dispatch` | `/implement` |
|---|---|---|
| 티켓 읽기 | curl REST API | Atlassian MCP |
| 브랜치 | 존재하면 중단 | 없으면 자동 생성 |
| 아키텍처 가이드 | 없음 | CLAUDE.md 직접 주입 |
| 프롬프트 상세도 | summary+description만 | spec 전문 + 가이드 + 규칙 |
| 완료 후 | 커밋만 (push/PR 안 함) | push + PR 자동 생성 |
| PR 대상 | - | dev / staging 선택 |
| 선행 티켓 | 미확인 | 상태 체크 후 경고 |

---

## 주의사항

- Agent는 **worktree 격리** 환경에서 실행 — 메인 워킹 디렉토리에 영향 없음
- Agent가 push/PR 생성까지 수행하므로 **디스패치 전 사용자 확인 필수**
- `backend/CLAUDE.md`는 42K 토큰으로 과대 — 섹션 1~3(필수 준수사항, 아키텍처 레이어, DTO 패턴)만 주입
- 선행 티켓이 미완료일 때 강제 진행하면 merge conflict 위험 있음
- Agent 완료 후 반드시 `/review`로 코드 품질 확인 권장

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 티켓 정보 조회
- `Agent`: worktree 격리 백그라운드 실행
- `gh pr create`: GitHub PR 생성
