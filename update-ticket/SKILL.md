---
name: update-ticket
description: "이미 생성된 Jira 티켓의 내용(description)을 수정·보강. 추가 맥락·의존 버전·제약·참조 링크를 넣거나 요구사항/AC를 다듬을 때. 새 티켓 생성이 아니라 기존 티켓 갱신. 사용자가 불러준 내용은 gh(PR/문서/코드)로 ground-truth 검증 후, 기존 구조를 유지하며 전체 description을 교체한다."
argument-hint: "<티켓키 또는 URL> [보강할 내용 / 문서_URL / 지시]"
marketplace: false
---

# Update-Ticket — 기존 티켓 내용 수정·보강

## 목적

`/story-to-spec`·`/add-task`로 **이미 만들어진 티켓의 description을 고친다.**
추가 맥락, 의존 버전, 작업 환경(컨테이너), 참조 문서/PR, 요구사항·AC 보강 등
"티켓을 새로 만드는 게 아니라 기존 티켓에 살을 붙이는" 작업용.

`/add-task`가 "요청 → 새 Task 하나"라면, 이 스킬은 **"기존 티켓 하나 → 내용 갱신"** 이다.

## 대상 구조 (필수 선행 지식)

np-enterprise는 phase 2에서 `sdk`를 3패키지로 분리했다. **신구조가 기본이다:**

```
np-client (client/src/np_client/) ──HTTP──▶ backend (backend/src/pynp/)
   thin CLI, core-free                        API·DB·오케스트레이션
                                                   │ event
np-common (common/src/np_common/)                  ▼
   이벤트·DTO 계약 공유              np-engine (engine/src/np_engine/)
                                       compute, core 허용, 이벤트 소비

[legacy] sdk/src/ — 이관 원본. 읽기 전용
```

> **Step 1 전에 읽는다:**
> `~/.claude/skills/story-to-spec/references/np-enterprise-structure.md`
> (폴백: `~/claude-skills/story-to-spec/references/np-enterprise-structure.md`)

⚠️ **이 스킬이 다루는 티켓은 대부분 구조 변경 전에 만들어졌다.** `Module: SDK`나 `sdk/src/...`
경로를 참조하고 있을 가능성이 높다. Step 4에서 **구조 드리프트를 반드시 대조**하고,
Step 6에서 **기존 서술을 지우지 않고 신구조를 덧붙인다.**

## 파이프라인 위치

```
/story-to-spec  → 스토리 → Task 여러 개
/add-task       → 구두·문서 요청 → 새 Task
/update-ticket  → 기존 티켓 → 내용 수정·보강              ← 이 스킬
/implement      → 티켓 → 브랜치 → 구현 → PR
```

## 사용법

```
# 티켓키 + 불러줄 내용
/update-ticket NPP02-6929 "의존 버전 np-evaluator v1.2.0-rc1, 컨테이너 작업 명시"

# URL도 허용
/update-ticket https://nota-dev.atlassian.net/browse/NPP02-6929 "QDQ 페어링 규칙 추가"

# 지시만 주고 대화로 채우기
/update-ticket NPP02-6929
```

- 첫 인자는 **반드시 기존 티켓 키/URL**.
- 나머지는 보강할 내용(구두), 문서 URL/경로, 또는 지시. 없으면 대화로 수집.

---

## 전체 흐름

```
0. 구조 참조 로딩  — references/np-enterprise-structure.md 읽기
1. 티켓 읽기      — getJiraIssue로 현재 description 통째로 확보 (구조 파악)
2. 의도 파악      — 무엇을 추가/수정? 어느 섹션에? (필요하면 AskUserQuestion으로 방향 좁히기)
3. 내용 수집      — 사용자 구두 + 문서 로딩(WebFetch/getConfluencePage/Read)
4. ground-truth 검증 — 불러준 내용을 gh로 PR·문서·코드 대조 + 구조 드리프트 대조 (⚠️ 핵심 단계)
5. 충돌·공백 표면화  — 검증 결과가 어긋나거나 빠진 케이스가 있으면 사용자에게 알림
6. description 재구성 — 기존 구조 유지하며 전체 description 재작성 (기존 내용 보존)
7. 적용           — editJiraIssue(contentFormat markdown, description 전체 교체)
8. 결과 보고      — 무엇을 어느 섹션에 넣었는지 요약 + 링크
```

---

## Step 1: 티켓 읽기 (blind overwrite 금지)

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{티켓키}"
- fields: ["summary","description","issuelinks","labels","parent"]
- responseContentFormat: "markdown"
```

> ⚠️ **editJiraIssue의 description은 전체 교체다.** 부분 수정 API가 없으므로
> 현재 내용을 통째로 확보한 뒤, 기존 섹션을 **모두 보존**한 채 재작성해야 한다.
> 읽지 않고 덮어쓰면 기존 내용이 날아간다.

기존 섹션 구조(예: `🧩 Why / 📌 Requirements / 🛠 What / ✅ AC / ➕ 특이사항`)를 파악해
어디에 무엇을 끼워 넣을지 계획한다.

## Step 2: 의도 파악

- **무엇을** 추가/수정하나 (버전, 제약, 참조, 요구사항, AC…)
- **어느 섹션에** 들어가야 자연스러운가
- 방향이 애매하면 `AskUserQuestion`으로 짧게 좁힌다 (예: "직접 불러줄 내용 / 코드 조사로 채우기 / 관련 티켓·PR 맥락 중 어떤 걸?")

## Step 3: 내용 수집

사용자 구두 내용을 받고, 문서 URL/경로면 로딩한다. (add-task Step 2와 동일 로더)

| 소스 타입 | 로딩 방법 |
|----------|----------|
| Confluence | `mcp__atlassian__getConfluencePage` |
| GitHub MD / PR | `WebFetch` 또는 `gh`(아래) |
| 로컬 파일 | `Read` |

## Step 4: ground-truth 검증 (⚠️ 이 스킬의 핵심)

**"로컬에 코드가 없어서 확인 못 한다"는 틀렸다.** `gh`로 PR·문서·코드를 실제로 본다.

```bash
gh auth status                                              # 인증 확인
gh pr view <번호> --repo <org>/<repo> --json title,state,body,files
gh api repos/<org>/<repo>/contents/<path> --jq '.content' | base64 -d   # 파일 원문
gh api repos/<org>/<repo>/contents/<path> --jq '.content' | base64 -d | grep -niE "<키워드>"
```

검증 대상:

- 사용자가 준 **버전·PR 번호·파일 경로·링크**가 실제로 맞는지
- 불러준 규칙/동작이 **문서·PR의 서술과 일치**하는지
- 티켓이 참조하는 스토리/PR/소비처 티켓의 **현재 상태**

> 티켓에 넣는 각 결정은 `근거(출처)` 컬럼에 **검증한 출처**(PR #번호, 문서 §절, 사용자)를 적는다.

### 4-b. 구조 드리프트 대조 (phase 2 전에 만들어진 티켓)

티켓이 **레거시 경로·Module을 참조하고 있는지** 확인한다. 이건 사용자가 요청하지 않아도 한다.

```bash
# 티켓이 참조하는 sdk 경로가 신구조로 이관됐는지 확인
gh api repos/nota-github/np-enterprise/contents/client/src/np_client/<대응경로>?ref=dev --jq '.[].name'
gh api repos/nota-github/np-enterprise/contents/engine/src/np_engine/<대응경로>?ref=dev --jq '.[].name'

# 레거시 원본이 아직 살아있는지 (strangler — 보통 살아있다)
gh api repos/nota-github/np-enterprise/contents/sdk/src/<경로>?ref=dev --jq '.name'
```

체크 항목:

| 확인 | 판단 |
|------|------|
| `Module:` 값이 `SDK`인데 실제 작업은 CLI·compute? | 신구조 값(`Client`/`Engine`) 후보 — Step 5에서 확인 |
| 변경 대상이 `sdk/src/...`인데 신구조에 대응 경로가 존재? | **이관 완료** — 신구조 경로를 덧붙이고 기존 행은 `(legacy 원본)`으로 |
| 신구조에 대응 경로가 없음? | **아직 미이관** — `sdk/` 경로 유지가 맞다. 바꾸지 않는다 |
| Client 작업인데 core 의존(torch 등)이 필요? | 귀속 오류 가능 — Step 5에서 escalate (charter #5·#6) |

> ⚠️ **경로가 신구조에 없다는 이유로 티켓을 "고쳤다"고 하지 말 것.** 미이관이면 레거시가 정답이다.
> 라우팅 표는 참조 파일 §3, 귀속 판정은 §4.

## Step 5: 충돌·공백 표면화

검증 결과가 사용자 입력과 **어긋나거나**, 사용자가 놓친 **케이스가 있으면**
조용히 합치지 말고 **먼저 사용자에게 알린다.** (그대로 반영 ≠ 옳은 반영)

전형적 예:
- 용어 충돌: 사용자 "QDQ는 하위 Q 기준 전달" ↔ 문서 "QDQ는 비교 대상 아님" → 층위가 다름을 설명하고 문구 조율
- 범위 공백: 티켓이 GQ만 전제 ↔ 실제 target은 GO도 가능 → 누락 위험 지적 후 양쪽 명시
- 링크/버전 불일치: 사용자가 준 경로·버전이 문서와 다름 → 확인 요청
- **구조 드리프트**: 티켓이 `sdk/src/...` / `Module: SDK`를 참조하는데 해당 기능이 신구조로 이관됨
  → "이 티켓은 구구조 기준입니다. 신구조 경로(`client/src/np_client/...`)를 덧붙이고
  `Module`을 `Client`로 갱신할까요? (기존 sdk 서술은 legacy 표기로 남깁니다)"
- **패키지 귀속 오류**: Client 전제인데 core 연산이 필요 → engine 소속 가능. **결정하지 말고 escalate**
  (charter #5·#6 — 경계 결정은 위임 금지)

애매하면 `AskUserQuestion`으로 "원문 유지 vs 조율안" 중 택하게 한다.

## Step 6: description 재구성

- 기존 섹션을 **전부 유지**한 채, 새 내용을 알맞은 섹션에 끼워 넣는다.
- 표 형식 섹션(Requirements 등)은 **행 추가**로, 서술 섹션은 문단/불릿 추가로.
- 요구사항을 추가하면 대응하는 **AC 항목**도 같이 추가한다 (요구사항↔검증 짝 유지).
- 각 결정에 **출처**를 붙인다.

### 구조 갱신 규칙 (덧붙인다, 지우지 않는다)

Step 4-b에서 드리프트가 확인되고 Step 5에서 사용자가 동의했을 때만 적용한다.

1. **`Module:` 갱신** — 새 허용값으로 (`Client | Backend | Engine | Common | SDK(legacy) | DB Migration | CI`).
   기존 `SDK`는 `SDK(legacy)`와 동일 취급이므로, 실제 작업이 sdk면 그대로 둬도 된다.
2. **변경 대상 표** — 신구조 경로 행을 추가하고, **기존 `sdk/` 행은 삭제하지 않는다.**
   ```
   | `client/src/np_client/.../xxx.py` | {수정 내용} |
   | `sdk/src/.../xxx.py` | (legacy 원본 — 읽기 전용 대조) |
   ```
3. **구현 가이드 참조 문서** — 신구조 문서를 추가 (`client/README.md` / `engine/README.md`),
   기존 `sdk/CLAUDE.md` 참조는 남긴다 (코딩 규칙은 client·engine이 승계).
4. **AC 추가** — Client면 `pytest client/tests/architecture` (core-free),
   Engine이면 `pytest engine/tests/architecture` (no-legacy-import).
5. **미이관이면 아무것도 바꾸지 않는다** — 신구조에 대응 경로가 없으면 `sdk/`가 정답이다.

## Step 7: 적용

```
mcp__atlassian__editJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{티켓키}"
- contentFormat: "markdown"
- fields:
    description: "{재구성한 전체 description}"
```

> description은 **전체 문자열을 다시 넣는다.** (부분 patch 아님)
> 반환된 결과에서 렌더링을 확인해 **깨진 표·오타**가 없는지 점검한다.

## Step 8: 결과 보고

무엇을 **어느 섹션에** 넣었는지, 그리고 **검증으로 확인/미확인한 것**을 구분해 보고한다.

```markdown
## ✅ NPP02-XXXX 업데이트 완료

- Requirements: {추가 행 요약}
- 구현 가이드: {추가 항목}
- AC: {추가 체크}
- 특이사항: {참조 보강}
- 구조: {Module SDK → Client 갱신 / 신구조 경로 추가, sdk 행은 legacy 표기로 보존}
        {또는: 미이관 확인 — sdk 경로 유지}

검증: PR #166 ✅ / 문서 §5.3 ✅ / 구조 드리프트 ✅(client로 이관 확인) / 버전 핀 ❓(문서엔 없음, 사용자 신뢰)
🔗 {티켓 URL}
```

---

## 핵심 원칙

| 원칙 | 이유 |
|------|------|
| **읽고 나서 고친다** | description 전체 교체 API — 안 읽으면 기존 내용 소실 |
| **gh로 실제 검증한다** | "코드 못 본다"는 핑계. PR·문서·코드를 실제로 대조해야 근거가 선다 |
| **어긋나면 표면화** | 사용자 입력을 조용히 합치지 말고, 충돌·공백을 먼저 알린다 |
| **출처를 남긴다** | 각 결정에 PR/문서/사용자 근거 표기 → 나중에 추적 가능 |
| **요구사항↔AC 짝** | 요구사항을 넣으면 검증 항목도 같이 넣는다 |
| **구조는 덧붙인다, 지우지 않는다** | phase 2 이전 티켓은 `sdk/` 기준. 신구조를 추가하되 legacy 서술은 `(legacy 원본)`으로 보존 |
| **미이관이면 손대지 않는다** | 신구조에 대응 경로가 없으면 `sdk/`가 정답. "최신화"로 오히려 틀리게 만들지 말 것 |

## 주의사항

- **첫 인자는 기존 티켓.** 새로 만드는 거면 `/add-task`·`/story-to-spec`을 쓴다.
- description은 **markdown으로 전체 교체.** 부분 수정 없음 → 기존 섹션 보존 필수.
- 코드 검증이 필요한데 로컬 체크아웃이 없어도 **포기하지 말 것** — `gh`로 확인.
- 검증으로 확정 못 한 항목(예: 런타임 버전 핀)은 결과 보고에서 **❓로 구분** 표기.
- 링크(issuelinks) 방향은 story-to-spec 규칙과 동일 — 새 링크를 걸 땐 `outwardIssue`가 항상 Task.
- **구조 드리프트 대조(Step 4-b)는 사용자가 요청하지 않아도 수행**한다. 단, 갱신은 Step 5 동의 후에만.
- 패키지 귀속이 어긋나 보이면 **고치지 말고 escalate** (charter #5·#6).
- `Module: SDK`와 `SDK(legacy)`는 **동일 취급** — 기존 티켓 표기를 강제로 바꾸지 않는다.

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 현재 티켓 내용 확보 (Step 1)
- `mcp__atlassian__editJiraIssue`: description 전체 교체 (Step 7)
- `gh` (CLI): PR/문서/코드 ground-truth 검증 (Step 4) — `gh pr view`, `gh api .../contents/...`
- `WebFetch` / `mcp__atlassian__getConfluencePage` / `Read`: 문서 소스 로딩
- `AskUserQuestion`: 방향 좁히기 / 충돌 조율안 선택

## 관련 스킬

| 스킬 | 관계 |
|------|------|
| `/story-to-spec` | 티켓 구조·링크 규칙의 원본. 이 스킬은 그 산출물을 수정 |
| `/add-task` | 새 티켓 생성(단건). 이 스킬은 기존 티켓 수정 |
| `/implement` | 갱신된 티켓을 넘겨 구현 자동화 (후속 단계) |
