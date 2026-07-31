# `/spec-diff` — 기획 문서 대비 구현 차이 점검 스킬 설계

- 날짜: 2026-07-31
- 신규 스킬: `spec-diff`
- 함께 수정: `README.md`, `CLAUDE.md`
- 대상 데이터: `nota-github/np-product-docs` (기획), Jira NPP02 (티켓), `nota-github/np-enterprise` (PR)

## 배경

기획 문서와 실제 구현이 어긋나도 알아차릴 방법이 없다. 파이프라인
(`/story-to-spec` → `/implement` → PR)은 티켓에서 코드로 내려가기만 하고, 내려간 결과가
**원래 기획과 같은지 되돌아 확인하는 단계가 없다.**

np-product-docs는 이미 **문서↔문서** 드리프트를 추적한다. `delivery/<고객사>/phase<N>/`의
발췌본은 헤더에 `> 발췌 원본: specs/... @ <hash>`를 고정해 두고
`git diff <hash>..HEAD`로 정본 변화를 기계적으로 따라간다.

비어 있는 건 **문서↔코드**다. 이 스킬이 그 칸을 채운다.

### 데이터 소스 구조 (gh로 확인)

| 소스 | 위치 | 성격 |
|---|---|---|
| 정본 스펙 | `np-product-docs/specs/commands/np-*.md` | versionless SSoT. §번호 섹션 + 시나리오 매트릭스 + 결정 타임라인 |
| 커맨드 인덱스 | `specs/commands/_index.md` | 커맨드명 → 문서 매핑 |
| 납품 발췌본 | `delivery/<고객사>/phase<N>/` | 동결된 작업 계약 |
| 티켓 | Jira NPP02 | 스토리 ─Blocks─ Task |
| 구현 | `np-enterprise` PR | `/implement`가 `[NPP02-XXXX]` 제목 + `Resolves:` 본문으로 생성 |

문서에 **기계적 요구사항 ID는 없다.** 대신 아래 메타가 이미 본문에 있어 이를 앵커로 쓴다:

- 섹션 번호 (`§3`, `§5.2`)
- 상태 표기 (`확정` / `WIP` / `후속 EXT` / `Tier 2.5`)
- 시나리오 매트릭스 (S0~S3 × 필수/선택)
- 결정 타임라인 (Jira 키·PR 번호 참조)

## 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| 1 | **입력은 스토리 티켓** — `/spec-diff NPP02-6517` | 기존 파이프라인(story-to-spec → implement)과 축이 같고 범위가 닫힘 |
| 2 | **증거는 PR 본문 + 변경 파일목록 + 핵심 diff** | PR 설명만 믿으면 "문서↔코드 공백 찾기"라는 목적 자체와 상충. 판정이 갈리는 항목만 diff로 확인해 비용 균형 |
| 3 | **읽기 전용 리포트 + 후속 명령 제안** | 판단이 섞인 결과물을 Jira·문서에 자동 반영하지 않는다 (`/scrum`과 같은 철학) |
| 4 | **문서 상태 표기를 존중해 갭과 분리** | `확정` + 해당 시나리오 단계만 갭 판정. `후속 EXT`·`WIP`는 '의도된 미구현'으로 별도 목록 |
| 5 | **양방향 2패스 비교** | 미구현과 초과구현은 서로 반대 방향에서만 보인다. 단방향이면 한쪽이 구조적으로 안 보임 |

## 설계 A — 입력과 수집

### 사용법

```
/spec-diff NPP02-6517                                        # 스토리 기준
/spec-diff NPP02-6517 --docs specs/commands/np-analyze.md    # 문서 직접 지정
/spec-diff NPP02-6517 --deep                                 # 판정 갈리는 항목의 diff를 더 넓게
```

### Step 1 — 스토리 트리 (Jira)

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{스토리 키}"
- fields: ["summary","description","issuelinks","labels","parent","status"]
- responseContentFormat: "markdown"
```

하위 Task는 `issuelinks`에서 찾는다. `/story-to-spec`이 `outwardIssue=Task, inwardIssue=Story,
type=Blocks`로 걸므로 **스토리 쪽에서 보면 "is blocked by"가 하위 Task**다.

각 Task에서 수집: `요구사항 & 설계 결정` 표, `변경 대상`, AC, `Module:`, `🔀 Branch:`, 상태.

링크가 없으면 JQL 보조 검색(`project = NPP02 AND text ~ "{스토리 키}"`), 그래도 없으면
**추측하지 않고 사용자에게 묻는다.**

### Step 2 — PR (gh)

Task마다 티켓 키로 검색하고, 결과가 없으면 브랜치명으로 재시도한다.

```bash
gh pr list --repo nota-github/np-enterprise --search "NPP02-6559" --state all \
  --json number,title,state,mergedAt,headRefName,body,files

# fallback: 브랜치명
gh pr list --repo nota-github/np-enterprise --head "feat/NPP02-6559-{slug}" --state all --json ...
```

⚠️ **검색 결과를 그대로 믿으면 안 된다 (실측 확인함).** `--search`는 본문의 단순 언급까지
잡는다. 실제로 `--search "NPP02-6963"`는 3건을 반환했고 그중 2건은 그 티켓을 *참조만* 한
다른 티켓의 PR이었다 (#2305는 `NPP02-7032`인데 본문에 "client(NPP02-6963)와 대칭으로"라고
적혀 있음).

**귀속 판정 규칙 — 아래 중 하나를 만족해야 그 티켓의 PR로 인정한다:**

1. 제목이 `[NPP02-XXXX]`로 시작
2. 본문에 `Resolves: https://nota-dev.atlassian.net/browse/NPP02-XXXX`
3. `headRefName`이 `feat/NPP02-XXXX-`로 시작

셋 다 아니면 **참조일 뿐 증거가 아니다.** 버린다.

**증거 인정 기준 — 셋을 뭉뚱그리지 않는다:**

| PR 상태 | 취급 |
|---|---|
| merged | ✅ 구현 증거로 인정 |
| open | 🔵 `진행 중` — 미구현으로 세되 사유를 명시 |
| 없음 / closed(미머지) | ⚪ `증거 없음` |

### Step 3 — 기획 문서 구간 확정

우선순위대로 시도한다:

1. 티켓 description의 `원천 소스` 필드 (story-to-spec이 기록)
2. `--docs` 인자
3. 커맨드명·키워드로 `specs/commands/_index.md`를 매핑해 **후보를 제시하고 사용자 확인**

3번에서도 확정하지 못하면 **추측으로 진행하지 않고 멈춘다.** 엉뚱한 문서와 대조한 리포트는
없느니만 못하다.

읽은 문서는 **커밋 해시를 고정해 리포트에 기록**한다.

```bash
gh api repos/nota-github/np-product-docs/commits?path=specs/commands/np-analyze.md\&per_page=1 \
  --jq '.[0].sha[0:7]'
```

`delivery/`가 이미 쓰는 `@ <hash>` 관행을 따른다. 재실행 시 "문서가 바뀐 건지 구현이 바뀐
건지"를 가를 수 있다.

## 설계 B — 비교 엔진

### A패스: 요구사항 → 증거

문서 섹션을 순회하며 검증 가능한 단위로 쪼개고, 본문에 이미 있는 메타를 붙인다.

```yaml
- id: R3                       # 리포트 안에서만 쓰는 로컬 번호 (문서엔 없음)
  section: "§3 입력 시그니처 분기"
  text: "Q 실행 여부로 사전/사후 자동 분기"
  status: 확정                  # 확정 / WIP / 후속 EXT / Tier N / 미표기
  scenario: [S1, S2, S3]       # 시나리오 매트릭스에서
```

**갭 판정 대상**: `status == 확정` **이면서** 대상 시나리오 단계에 걸린 항목.

대상 단계는 이 순서로 정한다:

1. 스토리·Task 본문에 `S0`~`S3` 표기가 있으면 그것
2. 없으면 스프린트·에픽 이름에서 추론 (예: "S1 멀티-Run")
3. 그래도 모르면 **단계 필터를 적용하지 않고 전 단계를 판정 대상에 넣되**,
   리포트 머리에 `시나리오 단계 미확정 — 전 단계 대조`를 명시한다.
   (조용히 좁혀서 갭을 놓치는 것보다 넓게 보고 표시하는 쪽이 낫다)

- `후속 EXT` / `WIP` / 상위 단계 전용 → 🕓 '의도된 미구현'으로 **분리하되 숨기지 않는다.**
- `미표기` → 제외하지 않고 판정하되 리포트에 `(상태 미표기)`를 남긴다.
  상태가 안 적힌 건 문서의 공백이지 면제 사유가 아니다.

**증거 등급:**

| 등급 | 기준 | 추가 확인 |
|---|---|---|
| 강 | PR diff에 해당 동작 코드 또는 테스트가 있음 | 불필요 |
| 중 | PR 본문·파일목록이 해당 영역만 명시 | **해당 diff를 좁혀 확인** |
| 없음 | 어느 PR에도 흔적 없음 | — |

diff는 PR 전체를 받지 않고 **관련 파일만** 좁혀 받는다:

```bash
# 변경 파일 목록 (patch 없이 — 먼저 이걸로 범위를 좁힌다)
gh api repos/nota-github/np-enterprise/pulls/408/files --jq '.[] | "\(.filename)\t\(.changes)"'

# 지목한 파일의 patch만
gh api repos/nota-github/np-enterprise/pulls/408/files \
  --jq '.[] | select(.filename=="client/src/np_client/.../terminal.py") | .patch'
```

`--deep`이면 '강' 등급도 diff를 확인한다.

### B패스: 잔여 변경 → 문서

A패스에서 **어떤 요구사항에도 매칭되지 않은 PR 변경**만 훑어, 대응하는 문서 구간이 있는지 본다.

**노이즈 필터 — 사용자 표면에 닿는 변경만 ➕ 후보로 본다:**

| ➕ 후보 | 제외 |
|---|---|
| CLI 옵션·서브커맨드 추가/변경 | 리팩터링·파일 이동 |
| 출력 포맷·로그·에러 메시지 | 테스트 추가 |
| API 계약·이벤트 스키마 | 타입힌트·lint·포맷팅 |
| 저장 포맷·디렉토리 구조 | 의존성 범프 |

이 필터가 없으면 B패스 결과가 리팩터링으로 뒤덮여 쓸 수 없다.

### 판정 분류

| 판정 | 의미 | 검출 방향 |
|---|---|---|
| ✅ 구현됨 | 요구사항 ↔ 증거 일치 | A |
| ❌ 미구현 | `확정`인데 증거 없음 | A |
| ⚠️ 다르게 구현 | 증거는 있으나 문서 서술과 어긋남 | A |
| ➕ 문서에 없음 | 사용자 표면 변경인데 대응 문서 구간 없음 | B |
| 🕓 의도된 미구현 | `후속 EXT`·`WIP`·상위 시나리오 전용 | 분리 목록 |

## 설계 C — 리포트

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

### 🕓 의도된 미구현 (참고 — 갭 아님)
| 문서 구간 | 요구사항 | 사유 |
|---|---|---|
| §1 | `analyze profile` | 후속 EXT |

### 다음 단계 (제안 — 자동 실행하지 않음)
- ❌#2 → `/add-task NPP02-6517 "§7 {요구사항} 구현"`
- ⚠️#1 → **기획자 확인 필요** — 문서가 낡은 건지 구현이 틀린 건지
- ➕#1 → `/update-ticket NPP02-6559 "문서에 없는 {변경} 반영 여부 확인"`
```

### ⚠️ 항목의 판단 주체

"문서가 낡음"과 "구현이 틀림"을 **스킬이 단정하지 않는다.** 둘 다 가능하고 판단 주체가 다르다
(기획자 vs 개발자). 리포트는 차이를 제시하고 판단을 사람에게 넘긴다.

## 실패 모드

| 상황 | 동작 |
|---|---|
| 스토리에 하위 Task 링크 없음 | JQL 보조 검색 → 실패 시 사용자에게 확인 |
| PR을 못 찾음 | 브랜치명 fallback → 실패 시 `증거 없음`으로 **정직하게 기록** (구현됐다고 추정 금지) |
| 문서 구간 확정 실패 | 후보 제시 → 확인 안 되면 **중단** |
| 문서에 상태 표기 없음 | `(상태 미표기)`로 판정 대상에 포함 |
| `gh` 미인증 | 즉시 중단하고 `gh auth login` 안내 |
| 요구사항이 여러 문서에 걸침 | 문서별로 섹션을 나눠 각각 대조, 리포트에 문서별 해시 병기 |

## 산출물

1. **`spec-diff/SKILL.md`** (신규) — 위 설계 전체
2. **`README.md`** — 스킬 목록에 `spec-diff` 추가. **현재 누락된 `update-ticket`·`scrum`·`note`도
   함께 채운다** (목록이 이미 낡음)
3. **`CLAUDE.md`** — 파이프라인 다이어그램에 `/spec-diff`를 "파이프라인 밖 (읽기 전용)" 절로
   추가. `/scrum` 옆에 나란히 둔다

## 검증

이 repo엔 자동 테스트가 없으므로 수동 점검 3개로 확인한다.

1. `bash setup.sh` — `spec-diff`가 symlink 목록에 뜨고 `~/.claude/skills/spec-diff/SKILL.md`가 도달
2. README 스킬 목록과 실제 스킬 디렉토리 목록이 일치 —
   `ls -d */ | grep -v docs` vs README 표
3. SKILL.md에 적은 `gh` 호출을 **실제로 1회씩 실행**해 문법이 맞는지 확인

설계 시점에 이미 실행해 확인한 것:

| 명령 | 결과 |
|---|---|
| `gh api "repos/.../commits?path=...&per_page=1"` | ✅ `74757da 2026-07-22` — URL 전체를 따옴표로 감싸야 `&`가 살아남음 |
| `gh pr list --search "NPP02-6963" --json ...` | ⚠️ 3건 반환, 그중 2건은 오탐 → 귀속 판정 규칙 도입 (설계 A Step 2) |
| `gh api repos/.../pulls/2295/files --jq ...` | ✅ 파일명·변경량 목록 반환 |

## 범위 밖

- Jira·문서에 자동 쓰기 (결정 3)
- 납품 phase 기준·문서 기준 진입 (결정 1에서 스토리 축으로 좁힘 — 후속 확장 여지)
- 문서↔문서 드리프트 (`delivery/`의 `@hash` + `git diff`가 이미 담당)
- 구현 품질·코드 리뷰 (`/review` 영역)
