---
name: spec-diff
description: "기획 문서(np-product-docs) 대비 실제 구현(머지된 PR)이 무엇이 다른지 점검. 스토리 티켓을 받아 하위 Task→PR을 모으고 기획 문서 섹션과 양방향 대조하여 미구현·다르게 구현·문서에 없는 구현을 분류한다. 읽기 전용이며 Jira·문서에 쓰지 않고 후속 명령 문안만 제안한다."
argument-hint: "<스토리_티켓_키> [--docs <문서경로>] [--deep]"
marketplace: false
---

# Spec-Diff — 기획 대비 구현 차이 점검

## 목적

기획 문서와 실제 구현이 어긋나도 알아차릴 방법이 없다. 파이프라인
(`/story-to-spec` → `/implement` → PR)은 티켓에서 코드로 **내려가기만** 하고,
내려간 결과가 원래 기획과 같은지 **되돌아 확인하는 단계가 없다.**

np-product-docs는 이미 **문서↔문서** 드리프트를 추적한다 (`delivery/`의 발췌본이
`> 발췌 원본: specs/... @ <hash>`를 고정하고 `git diff <hash>..HEAD`로 정본 변화를 추적).

비어 있는 건 **문서↔코드**다. 이 스킬이 그 칸을 채운다.

## 파이프라인 위치

```
/story-to-spec  → 스토리 → Task 여러 개
/add-task       → 구두·문서 요청 → 새 Task
/update-ticket  → 기존 티켓 → 내용 수정·보강
/implement      → 티켓 → 브랜치 → 구현 → PR
/spec-diff      → 기획 문서 ↔ 머지된 PR 대조 → 차이 리포트     ← 이 스킬 (읽기 전용)
```

⚠️ **읽기 전용이다.** Jira에도 문서에도 쓰지 않는다. 판단이 섞인 결과물을 자동 반영하지 않고,
후속 명령 문안만 제안한다. (`/scrum`과 같은 철학)

## 사용법

```
/spec-diff NPP02-6517                                        # 스토리 기준
/spec-diff NPP02-6517 --docs specs/commands/np-analyze.md    # 기획 문서 직접 지정
/spec-diff NPP02-6517 --deep                                 # 증거 '강'인 항목까지 diff 확인
```

- 첫 인자는 **반드시 스토리 티켓 키**.
- `--docs`: 대조할 기획 문서를 직접 지정 (np-product-docs 기준 상대경로). 생략 시 Step 3에서 결정.
- `--deep`: 판정이 갈리지 않는 항목도 diff를 확인. 느리지만 정확.

## 데이터 소스

| 소스 | 위치 | 성격 |
|---|---|---|
| 정본 스펙 | `np-product-docs/specs/commands/np-*.md` | versionless SSoT. §번호 섹션 + 시나리오 매트릭스 |
| 커맨드 인덱스 | `np-product-docs/specs/commands/_index.md` | 커맨드명 → 문서 매핑 |
| 납품 발췌본 | `np-product-docs/delivery/<고객사>/phase<N>/` | 동결된 작업 계약 |
| 티켓 | Jira NPP02 | 스토리 ─Blocks─ Task |
| 구현 | `nota-github/np-enterprise` PR | `/implement`가 `[NPP02-XXXX]` 제목 + `Resolves:` 본문으로 생성 |

문서에 **기계적 요구사항 ID는 없다.** 대신 본문에 이미 있는 아래 메타를 앵커로 쓴다:
섹션 번호(`§3`, `§5.2`) / 상태 표기(`확정`·`WIP`·`후속 EXT`·`Tier N`) /
시나리오 매트릭스(S0~S3 × 필수·선택) / 결정 타임라인(Jira 키·PR 번호).

## 전체 흐름

```
1. 스토리 트리 수집   — getJiraIssue → issuelinks에서 하위 Task
2. PR 수집            — 티켓 키로 검색 → ⚠️ 귀속 판정으로 오탐 제거 → 머지 여부 구분
3. 기획 문서 확정     — 원천 소스 필드 → --docs → 인덱스 매핑 후 사용자 확인 (실패 시 중단)
4. 요구사항 단위 추출 — 섹션별로 쪼개고 상태·시나리오 메타 부착
5. A패스              — 요구사항 → 증거 (미구현·다르게 구현 검출)
6. B패스              — 잔여 PR 변경 → 문서 (문서에 없는 구현 검출)
7. 리포트             — 5분류 + 후속 명령 제안 (자동 실행 없음)
```

---

## Step 1: 스토리 트리 수집

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{스토리 키}"
- fields: ["summary","description","issuelinks","labels","parent","status"]
- responseContentFormat: "markdown"
```

하위 Task는 `issuelinks`에서 찾는다. `/story-to-spec`이
`outwardIssue=Task, inwardIssue=Story, type=Blocks`로 걸므로
**스토리 쪽에서 보면 "is blocked by"가 하위 Task**다.

각 Task마다 `getJiraIssue`로 수집:
`요구사항 & 설계 결정` 표 / `변경 대상` / AC / `Module:` / `🔀 Branch:` / 상태.

링크가 없으면 JQL 보조 검색:

```
mcp__atlassian__searchJiraIssuesUsingJql
- jql: 'project = NPP02 AND text ~ "{스토리 키}" ORDER BY created ASC'
```

그래도 못 찾으면 **추측하지 않고 사용자에게 묻는다.**

## Step 2: PR 수집

Task마다 티켓 키로 검색하고, 결과가 없으면 브랜치명으로 재시도한다.

```bash
gh pr list --repo nota-github/np-enterprise --search "NPP02-6559" --state all \
  --json number,title,state,mergedAt,headRefName,body,files

# fallback: 브랜치명
gh pr list --repo nota-github/np-enterprise --head "feat/NPP02-6559-{slug}" --state all \
  --json number,title,state,mergedAt,headRefName,body,files
```

### ⚠️ 귀속 판정 (검색 결과를 그대로 믿지 말 것)

`--search`는 **본문의 단순 언급까지 잡는다.** 실측: `--search "NPP02-6963"`가 3건을
반환했고 그중 2건은 그 티켓을 *참조만* 한 다른 티켓의 PR이었다
(#2305는 `NPP02-7032`인데 본문에 "client(NPP02-6963)와 대칭으로"라고 적혀 있음).

**아래 중 하나를 만족해야 그 티켓의 PR로 인정한다:**

1. 제목이 `[NPP02-XXXX]`로 시작
2. 본문에 `Resolves: https://nota-dev.atlassian.net/browse/NPP02-XXXX`
3. `headRefName`이 `feat/NPP02-XXXX-`로 시작

셋 다 아니면 **참조일 뿐 증거가 아니다. 버린다.**

### 증거 인정 기준 — 셋을 뭉뚱그리지 않는다

| PR 상태 | 취급 | 리포트 표기 |
|---|---|---|
| merged | ✅ 구현 증거로 인정 | — |
| open | 🔵 미구현으로 세되 사유 명시 | `PR #412 열림 — 미머지` |
| 없음 / closed(미머지) | ⚪ 증거 없음 | `대응 PR 없음` |

## Step 3: 기획 문서 구간 확정

우선순위대로 시도한다.

1. **티켓 description의 `원천 소스` 필드** (`/story-to-spec`이 기록해 둠)
2. **`--docs` 인자**
3. **커맨드명·키워드로 인덱스 매핑 후 후보 제시 → 사용자 확인**

```bash
gh api repos/nota-github/np-product-docs/contents/specs/commands/_index.md \
  --jq '.content' | base64 -d
```

3번에서도 확정하지 못하면 **추측으로 진행하지 않고 멈춘다.**
엉뚱한 문서와 대조한 리포트는 없느니만 못하다.

### 문서 커밋 해시 고정

읽은 문서는 해시를 기록해 리포트에 남긴다. `delivery/`가 이미 쓰는 `@ <hash>` 관행을 따른다.
재실행 시 "문서가 바뀐 건지 구현이 바뀐 건지"를 가를 수 있다.

```bash
gh api "repos/nota-github/np-product-docs/commits?path=specs/commands/np-analyze.md&per_page=1" \
  --jq '.[0] | "\(.sha[0:7])  \(.commit.committer.date[0:10])"'
```

> ⚠️ URL 전체를 따옴표로 감싼다. 안 그러면 셸이 `&`를 백그라운드 실행으로 먹는다.

문서 본문 읽기:

```bash
gh api repos/nota-github/np-product-docs/contents/specs/commands/np-analyze.md \
  --jq '.content' | base64 -d
```

## Step 4: 요구사항 단위 추출

문서 섹션을 순회하며 검증 가능한 단위로 쪼개고, 본문에 이미 있는 메타를 붙인다.

```yaml
- id: R3                       # 리포트 안에서만 쓰는 로컬 번호 (문서엔 없음)
  section: "§3 입력 시그니처 분기"
  text: "Q 실행 여부로 사전/사후 자동 분기"
  status: 확정                  # 확정 / WIP / 후속 EXT / Tier N / 미표기
  scenario: [S1, S2, S3]       # 시나리오 매트릭스에서
```

### 갭 판정 대상

`status == 확정` **이면서** 대상 시나리오 단계에 걸린 항목.

- `후속 EXT` / `WIP` / 상위 단계 전용 → 🕓 '의도된 미구현'으로 **분리하되 숨기지 않는다.**
- `미표기` → 제외하지 않고 판정하되 `(상태 미표기)`를 리포트에 남긴다.
  상태가 안 적힌 건 문서의 공백이지 면제 사유가 아니다.

### 대상 시나리오 단계 결정

1. 스토리·Task 본문에 `S0`~`S3` 표기가 있으면 그것
2. 없으면 스프린트·에픽 이름에서 추론 (예: "S1 멀티-Run")
3. 그래도 모르면 **단계 필터를 적용하지 않고 전 단계를 판정 대상에 넣되**,
   리포트 머리에 `시나리오 단계 미확정 — 전 단계 대조`를 명시한다.

> 조용히 좁혀서 갭을 놓치는 것보다 넓게 보고 표시하는 쪽이 낫다.

## Step 5: A패스 — 요구사항 → 증거

각 요구사항에 대해 Step 2에서 모은 PR에서 증거를 찾는다.

| 등급 | 기준 | 추가 확인 |
|---|---|---|
| 강 | PR diff에 해당 동작 코드 또는 테스트가 있음 | 불필요 (`--deep`이면 확인) |
| 중 | PR 본문·파일목록이 해당 영역만 명시 | **해당 diff를 좁혀 확인** |
| 없음 | 어느 PR에도 흔적 없음 | — |

diff는 PR 전체를 받지 않고 **관련 파일만** 좁혀 받는다 (2단계):

```bash
# ① 변경 파일 목록 (patch 없이 — 먼저 범위를 좁힌다)
gh api repos/nota-github/np-enterprise/pulls/408/files \
  --jq '.[] | "\(.filename)\t\(.changes)"'

# ② 지목한 파일의 patch만
gh api repos/nota-github/np-enterprise/pulls/408/files \
  --jq '.[] | select(.filename=="client/src/np_client/.../terminal.py") | .patch'
```

판정 결과: ✅ 구현됨 / ❌ 미구현 / ⚠️ 다르게 구현.

## Step 6: B패스 — 잔여 변경 → 문서

A패스에서 **어떤 요구사항에도 매칭되지 않은 PR 변경**만 훑어, 대응하는 문서 구간이 있는지 본다.

### 노이즈 필터 — 사용자 표면에 닿는 변경만 ➕ 후보

| ➕ 후보 | 제외 |
|---|---|
| CLI 옵션·서브커맨드 추가/변경 | 리팩터링·파일 이동 |
| 출력 포맷·로그·에러 메시지 | 테스트 추가 |
| API 계약·이벤트 스키마 | 타입힌트·lint·포맷팅 |
| 저장 포맷·디렉토리 구조 | 의존성 범프 |

이 필터가 없으면 B패스 결과가 리팩터링으로 뒤덮여 쓸 수 없다.

> **왜 2패스인가**: 미구현은 문서→증거 방향에서만, 초과구현은 증거→문서 방향에서만 보인다.
> 단방향이면 한쪽이 **구조적으로** 안 보인다.

## Step 7: 리포트

```markdown
## 📋 NPP02-6517 기획 대비 구현 점검

문서: specs/commands/np-analyze.md @ a1b2c3d (2026-07-20)
증거: Task 5개 / PR 4건 (머지 3, 열림 1, 없음 1)

확정 요구사항 12개 — ✅ 8  ❌ 2  ⚠️ 2  ➕ 1  🕓 6(의도된 미구현)

### ❌ 미구현
| # | 문서 구간 | 요구사항 | 담당 티켓 | 증거 상태 |
|---|---|---|---|---|
| 1 | §5.2 | {요구사항} | NPP02-6559 | PR #412 **열림** — 미머지 |
| 2 | §7 | {요구사항} | — | 대응 티켓 자체가 없음 |

### ⚠️ 다르게 구현
| # | 문서 서술 | 실제 구현 | 근거 |
|---|---|---|---|
| 1 | 기본 JSON | 기본 table | PR #408 `terminal.py:88` |

### ➕ 문서에 없는 구현
| # | 변경 | 사용자 표면 | 근거 |
|---|---|---|---|
| 1 | `--force` 옵션 추가 | CLI 옵션 | PR #410 `commands/run.py:24` |

### 🕓 의도된 미구현 (참고 — 갭 아님)
| 문서 구간 | 요구사항 | 사유 |
|---|---|---|
| §1 | `analyze profile` | 후속 EXT |

### 다음 단계 (제안 — 자동 실행하지 않음)
- ❌#2 → `/add-task NPP02-6517 "§7 {요구사항} 구현"`
- ⚠️#1 → **기획자 확인 필요** — 문서가 낡은 건지 구현이 틀린 건지
- ➕#1 → `/update-ticket NPP02-6559 "문서에 없는 --force 옵션 반영 여부 확인"`
```

### ⚠️ 항목의 판단 주체

"문서가 낡음"과 "구현이 틀림"을 **스킬이 단정하지 않는다.** 둘 다 가능하고 판단 주체가 다르다
(기획자 vs 개발자). 리포트는 차이를 제시하고 **판단을 사람에게 넘긴다.**

---

## 실패 모드

| 상황 | 동작 |
|---|---|
| 스토리에 하위 Task 링크 없음 | JQL 보조 검색 → 실패 시 사용자에게 확인 |
| PR을 못 찾음 | 브랜치명 fallback → 실패 시 `증거 없음`으로 **정직하게 기록** (구현됐다고 추정 금지) |
| 문서 구간 확정 실패 | 후보 제시 → 확인 안 되면 **중단** |
| 문서에 상태 표기 없음 | `(상태 미표기)`로 판정 대상에 포함 |
| `gh` 미인증 | 즉시 중단하고 `gh auth login` 안내 |
| 요구사항이 여러 문서에 걸침 | 문서별로 섹션을 나눠 각각 대조, 리포트에 문서별 해시 병기 |

## 핵심 원칙

| 원칙 | 이유 |
|------|------|
| **머지된 PR만 증거** | 열린 PR·티켓 상태는 의도이지 구현이 아니다 |
| **귀속을 검증한다** | `--search`는 단순 언급까지 잡는다. 남의 PR을 증거로 세면 리포트 전체가 거짓이 된다 |
| **양방향으로 본다** | 미구현과 초과구현은 반대 방향에서만 보인다 |
| **문서 상태를 존중하되 숨기지 않는다** | `후속 EXT`를 갭으로 세면 노이즈, 안 보여주면 누락 |
| **판단은 사람에게** | 문서가 낡은 건지 구현이 틀린 건지는 스킬이 정할 일이 아니다 |
| **모르면 멈춘다** | 엉뚱한 문서와 대조한 리포트는 없느니만 못하다 |

## 주의사항

- **읽기 전용.** Jira 코멘트·티켓 생성·문서 PR 모두 하지 않는다. 후속 명령은 **문안만** 제안한다.
- 첫 인자는 **스토리**다. Task 키를 주면 그 Task의 부모 스토리를 찾아 되묻는다.
- PR 검색 결과는 **반드시 귀속 판정을 통과시킨다** (Step 2).
- 문서 해시를 리포트에 **항상** 남긴다. 없으면 재실행 시 비교가 불가능하다.
- 증거가 없을 때 "아마 구현됐을 것"으로 채우지 않는다. `증거 없음`이 정직한 답이다.

## 관련 도구

- `mcp__atlassian__getJiraIssue`: 스토리·Task 조회
- `mcp__atlassian__searchJiraIssuesUsingJql`: 하위 Task 보조 검색
- `gh pr list` / `gh api .../pulls/{n}/files`: PR 메타·변경 파일·patch
- `gh api .../contents/...` / `.../commits?path=...`: 기획 문서 본문·커밋 해시
- `AskUserQuestion`: 문서 구간 후보 확인

## 관련 스킬

| 스킬 | 관계 |
|------|------|
| `/story-to-spec` | 이 스킬이 검증하는 티켓·`원천 소스` 필드의 생산자 |
| `/implement` | 이 스킬이 증거로 읽는 PR의 생산자 (`[키]` 제목 + `Resolves:` 규약) |
| `/add-task` | 미구현 갭을 후속 티켓으로 만들 때 (제안만, 자동 실행 X) |
| `/update-ticket` | 차이를 기존 티켓에 반영할 때 (제안만, 자동 실행 X) |
| `/scrum` | 같은 읽기 전용 철학 — Jira에 쓰지 않는다 |
