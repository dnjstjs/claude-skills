---
name: impl-wave
description: "스토리 하위 티켓들을 의존 그래프로 묶어 차수(wave)별로 병렬·순차 구현한다. 같은 차수는 /implement 에이전트를 동시 디스패치, 차수마다(또는 --verify-at-end 시 전체 완료 후 한 번) 자동 머지 → dev 배포 → E2E 검증 → PR 코멘트까지 무인으로 진행. 시작 전 차수 표 확인 1회 외에는 사람 개입 없음."
argument-hint: "<스토리_키 | 티켓_키 목록> [--dry-run] [--from N] [--base <브랜치>] [--verify-at-end]"
marketplace: false
---

# impl-wave — 차수 기반 병렬·순차 구현

## 목적

`/story-to-spec`이 스토리 하나에서 티켓 여러 개를 뽑아내면, `/implement`은 그중 **1건**만 안다.
나머지 판단 — 어떤 걸 동시에 띄워도 되는가, 앞 PR을 언제 dev에 넣어야 뒷 에이전트가 그 코드를
보는가, 머지만으로 충분한가 배포까지 필요한가, 배포 후 무엇으로 확인하는가 — 를 사람이 티켓
수만큼 반복해야 한다.

이 스킬이 그 판단을 대신한다. **스킬 호출 자체가 승인**이며, 시작 전 차수 표 확인 1회 외에는
끝까지 멈추지 않는다.

## 사용법

```
/impl-wave NPP02-8136                         스토리 하위 Task 전부 → 차수 추정 → 실행
/impl-wave NPP02-8136 --dry-run               차수 표만 뽑고 끝. 아무것도 안 건드림
/impl-wave NPP02-8136 --from 3                상태 파일 무시하고 3차부터 강제 재개
/impl-wave NPP02-8136 --base staging
/impl-wave NPP02-8136 --verify-at-end         차수마다 검증하지 않고 전체 완료 후 한 번만
/impl-wave NPP02-9835 NPP02-9836 NPP02-9837   스토리 없이 티켓 키를 직접 나열 (standalone 티켓들)
```

같은 스토리 키로 다시 부르면 상태 파일을 읽어 **끊긴 차수부터 자동 재개**한다.
`--from`은 그 자동 판단을 무시할 때만 쓴다.

### 입력이 스토리 키가 아니라 티켓 키 목록일 때

첫 인자가 스토리 키 형식이 아니거나, 여러 개의 티켓 키가 공백으로 나열되면 **Step 1(하위
Task 수집)을 건너뛴다** — 나열된 티켓들 자체가 대상 집합이다. 각 티켓을 `getJiraIssue`로
개별 조회해 Step 2(의존 그래프)부터 그대로 진행한다. standalone 티켓(부모 스토리 없음)들을
묶어 돌릴 때 쓴다 — 예를 들어 계약(Common) 선행 티켓 하나에 그걸 소비하는 Backend/Engine
후속 티켓 여러 개가 딸린 경우.

### `--verify-at-end` — 배포·검증을 차수마다가 아니라 전체 완료 후 한 번으로

기본은 **차수마다** 5-6(배포)·5-7(검증)을 수행한다. 하지만 EKS 배포는 다음 이유로
느리다(길게는 10분 이상):

```
PR 머지 → GitHub Actions 이미지 빌드 → ECR push → GitOps writeback PR 생성
  → (auto-merge 대기, base 대비 뒤처지면 걸림) → ArgoCD 다음 polling 주기
  → pod rolling update
```

`--verify-at-end`를 주면 각 차수는 **5-1~5-5(브랜치·디스패치·CI·머지)까지만** 하고
5-6·5-7·5-8을 건너뛴 채 다음 차수로 넘어간다. 마지막 차수까지 전부 머지된 뒤 Step 6에서
배포 확인 + 검증 + PR 코멘트를 **한 번에** 몰아서 한다. 차수 사이에 배포 대기로 멈춰
있지 않아도 되므로 전체 시간이 단축된다.

단, 이 옵션은 **차수 사이에 실제 배포된 코드로 다음 에이전트가 동작을 검증할 기회가
없다**는 뜻이다 — 배포 문제를 마지막에서야 발견하면 어느 차수가 원인인지 역추적해야
한다. 차수 수가 많거나(4차 이상) 차수 간 의존이 배포 결과에 민감하면(예: 2차가 1차의
API 응답을 실제로 호출해 스키마를 확인해야 함) 기본값(차수마다 검증)을 권장한다 —
Step 4 차수 표 확인 시 이 트레이드오프를 함께 안내한다.

### 실행 위치

**np-enterprise 워킹 디렉토리에서 실행한다.** git 조작·`gh`·프로젝트 스킬(`client-verify`)이
전부 그 repo 기준이다.

## `/implement`과의 관계 — 중복해서 쓰지 않는다

티켓 1건을 도는 부분은 **`/implement`의 것을 그대로 쓴다.** 여기 다시 적지 않는다.

| 가져다 쓰는 것 | 출처 |
|---|---|
| 브랜치명 규칙 (`feat/{키}-{slug}`), 존재 확인/생성 | `implement/SKILL.md` Step 3 |
| `Module:` 별 아키텍처 가이드 수집·주입 | `implement/SKILL.md` Step 4 |
| Agent 프롬프트 구성 (spec + 가이드 + 작업 규칙 + 금지사항) | `implement/SKILL.md` Step 5 |
| np-enterprise 패키지 지도·경로·규율 | `story-to-spec/references/np-enterprise-structure.md` |

이 스킬이 자기 몫으로 갖는 것은 넷뿐이다:
**차수 판정 · 병렬 디스패치와 대기 · 머지/배포/검증 게이트 · 상태 파일**.

## 전체 흐름

```
Step 1  하위 Task 수집
  │
Step 2  의존 그래프 조립 (근거 4순위)
  │
Step 3  위상정렬 → 파일 충돌 분리 → 차수 확정
  │
Step 4  차수 표 제시 ← 사람 개입 지점 (유일)
  │
Step 5  차수 루프 ── 디스패치 → 대기 → CI → 머지 → 배포 → 검증 → PR 코멘트
  │        └─ 차수 수만큼 반복
  │
Step 6  최종 검증 + 전체 리포트 + 결정 로그
```

---

## Step 1 — 하위 Task 수집

스토리에서 `Task ─Blocks→ Story` 링크를 타고 내려간다.

```
mcp__atlassian__getJiraIssue
- cloudId: "nota-dev.atlassian.net"
- issueIdOrKey: "{스토리 키}"
- fields: ["*all"]
- responseContentFormat: "markdown"
```

`issuelinks`에서 `inwardIssue`가 스토리인 항목의 `outwardIssue`가 하위 Task다.

링크가 없으면 JQL 폴백:

```
mcp__atlassian__searchJiraIssuesUsingJql
- jql: 'project = NPP02 AND (parent = {스토리키} OR text ~ "{스토리키}") ORDER BY key ASC'
```

폴백도 비면 **중단하고 사용자에게 확인**한다. 티켓을 못 찾았는데 추측으로 돌리지 않는다.

수집한 각 Task에서 뽑을 것:

| 필드 | 용도 |
|---|---|
| `summary` | 차수 표 표시 |
| `description` → `Module:` | 배포 대상·검증 방식·아키텍처 가이드 결정 |
| `description` → `선행 티켓:` | 그래프 근거 순위 2 |
| `description` → **"변경 대상" 테이블** | 파일 충돌 판정 |
| `description` → `🔀 Branch:` | 브랜치명 (없으면 `/implement` 규칙으로 생성) |
| `issuelinks` (Task↔Task) | 그래프 근거 순위 1 |
| breaking 표기 (🔴 / "breaking" 문구) | 차수 표에 표시 |

---

## Step 2 — 의존 그래프 조립

근거를 **우선순위대로** 긁어 간선을 만든다. 낮은 순위가 높은 순위를 덮어쓰지 않는다.

| 순위 | 근거 | 신뢰도 | 표기 |
|---|---|---|---|
| 1 | Jira **Task ↔ Task** issuelink (`Blocks`/`is blocked by`) | 명시적 | `링크` |
| 2 | 티켓 description의 `선행 티켓:` 필드 | 명시적 | `선행필드` |
| 3 | 스토리 description의 **구현 순서표** | 명시적 | `순서표` |
| 4 | Module 계층 + "변경 대상" 파일 겹침으로 추론 | 추정 | `추론` |

> ⚠️ **`story-to-spec`은 순위 1의 링크를 만들지 않는다** (`story-to-spec/SKILL.md:496`
> — "Jira 링크는 생성하지 않음"). 스토리 링크만 건다. 그러니 대부분의 스토리에서 실제로
> 잡히는 근거는 순위 2~4다. **표에 근거를 반드시 함께 출력해 어디가 추정인지 드러낸다.**

### 순위 4 추론 규칙

아무 근거도 없을 때만 쓴다.

- **계약이 소비처보다 앞선다** — `Common` → `Backend`·`Engine`·`Client`
- **스키마가 그 스키마를 쓰는 코드보다 앞선다** — `DB Migration` → `Backend`
- **제거는 뒤에 온다** — "삭제/제거/정리" 성격 티켓은, 그 대상을 안 쓰게 만든 티켓 뒤
- **파일 겹침 + 한쪽이 추가·한쪽이 수정**이면 추가가 앞

순환이 생기면 **중단하고 순환 경로를 보여준 뒤 확인**한다. 임의로 끊지 않는다.

---

## Step 3 — 위상정렬 → 파일 충돌 분리

위상정렬로 차수를 얻은 뒤 **한 겹 더 거른다.**

```
같은 차수 안의 티켓 쌍마다 "변경 대상" 파일 목록의 교집합을 구한다
  교집합 ≠ ∅  →  병렬 금지  →  뒤 티켓을 다음 차수로 내린다
```

의존이 없어도 같은 파일을 동시에 고치면 **머지 충돌이 확정**이다.

> 순위 4의 파일 겹침이 **간선**을 만드는 것과, 이 단계의 파일 겹침이 **같은 차수를 쪼개는**
> 것은 다른 일이다. 앞은 "순서가 있다"는 추정, 뒤는 순서가 없어도 "동시엔 못 돈다"는 판정.

**"변경 대상" 테이블이 없는 티켓**은 파일 목록을 얻을 수 없다. 겹침을 알 수 없으므로
**병렬로 묶지 않고 단독 차수로 세운다.** 모른다는 이유로 동시에 돌리지 않는다.

**동시 실행 상한 4개.** 초과하면 차수를 쪼갠다 — worktree 4개 + 각자 pytest면 이미 무겁다.

---

## Step 4 — 차수 표 제시 (사람 개입 지점, 유일)

배포 대상과 검증 방식까지 미리 계산해 함께 보여준다.

```markdown
## 차수 계획 — {스토리키} {스토리 제목}

| 차수 | 티켓 | 제목 | Module | 근거 | breaking |
|---|---|---|---|---|---|
| 1차 | 8137 | 스키마 2건 | Backend/DB | 링크 | — |
| 1차 | 8138 | common 계약 7건 | Common | 링크 | — |
| 2차 | 8139 | EVALUATION 병행 기록 | Backend | 선행필드 | — |
| 2차 | 8140 | engine 인라인 상세 업로드 | Engine | 선행필드 | — |
| 5차 | 8144 | job 생성 제거 | Backend | 추론 | 🔴 |

| 차수 | 배포 | 검증 |
|---|---|---|
| 1차 | backend | API 직접 호출 |
| 2차 | backend + engine | API 직접 호출 |
| 4차 | 없음 (client 단독) | client-verify (depth=run) |

⚠️ 추론 근거 {N}건 — Jira에 명시된 선후행이 아니라 Module 계층·파일 겹침으로 추정했습니다.

검증 시점: {"차수마다" 또는 "--verify-at-end — 전체 완료 후 한 번"}
  {--verify-at-end 가 아니면: EKS 배포는 GitOps 자동화라 차수당 수 분~10분 이상 걸릴 수
  있습니다. 차수가 {N}개라 배포 대기가 누적됩니다 — --verify-at-end 로 마지막에 한 번만
  검증하면 더 빠르지만, 중간 차수의 배포 문제를 그 자리에서 못 잡습니다.}

→ 이대로 진행할까요?
```

`AskUserQuestion`으로 확인받는다. `--dry-run`이면 여기서 끝낸다. 사용자가 여기서
검증 시점을 바꾸겠다고 답하면(예: "마지막에 한 번에 해줘") `--verify-at-end`를 켠 것과
동일하게 취급한다 — 플래그로 미리 안 줬어도 이 확인 단계에서 바뀔 수 있다.

**확인 이후로는 끝까지 묻지 않는다.**

---

## Step 5 — 차수 루프

차수마다 아래 8단계를 순서대로 수행한다. **`--verify-at-end`가 아니면** 시작 시점의
`dev`는 이전 차수까지 머지·배포·검증이 끝난 상태다. **`--verify-at-end`면** 5-6(배포)·
5-7(검증)·5-8(PR 코멘트)을 건너뛰고 5-1~5-5(브랜치·디스패치·CI·머지)만 수행한 뒤
바로 다음 차수로 넘어간다 — 시작 시점의 `dev`는 이전 차수까지 **머지만** 끝난 상태이고
아직 배포되지 않았을 수 있다. 다음 차수 브랜치를 딸 때는 그래도 최신 `origin/{base}`에서
따야 한다(머지된 소스 코드는 이미 반영돼 있다 — 배포 여부와 무관).

### 5-1. 브랜치 생성

티켓마다 `dev`(또는 `--base`)에서 브랜치를 딴다. 규칙은 `/implement` Step 3 그대로.

```bash
git fetch origin {base}
git branch feat/{브랜치명} origin/{base}
git push origin feat/{브랜치명}
```

⚠️ **반드시 최신 `origin/{base}`에서 딴다.** 이전 차수 머지분이 들어 있어야
에이전트가 선행 코드를 본다.

### 5-2. 병렬 디스패치

차수 내 티켓 수만큼 Agent를 **한 메시지 안에서 동시에** 띄운다.

```
Agent({
  description: "Implement {티켓키}: {제목 요약}",
  isolation: "worktree",
  run_in_background: true,
  prompt: <implement/SKILL.md Step 5 프롬프트 구성 그대로>
})
```

프롬프트는 `/implement` Step 4~5를 따른다 — 티켓 spec 전문 + `Module:`별 아키텍처 가이드 +
패키지 제약(core-free / no-legacy-import / 계약 소비처 경고) + 작업 규칙 + 금지사항.

**차수 내 다른 티켓 정보를 프롬프트에 넣는다:**

```
## 같은 차수 동시 작업 (충돌 주의)
- {다른 티켓키}: {제목} — 변경 대상: {파일 목록}
이 파일들은 건드리지 말 것. 겹치면 즉시 보고하고 멈출 것.
```

### 5-3. 전원 대기

백그라운드 Agent 완료 알림을 전부 받을 때까지 기다린다. 완료된 것부터 결과를 확인한다.

- **PR 생성 성공** → 5-4로
- **PR 없이 종료 / 테스트 실패** → **메인이 직접 수정.** 서브에이전트를 다시 띄우지 않는다.
  해당 worktree로 들어가 남은 작업을 마무리하고 push → PR 생성.
- **아키텍처 테스트 red** → 구현이 틀린 것이다. core-free·no-legacy-import 위반을 메인이 고친다.

### 5-4. CI 확인

```bash
gh pr checks {PR번호} --watch
```

red면 로그를 읽고 메인이 수정 → push → 재확인.

```bash
gh run view {run_id} --log-failed
```

### 5-5. 자동 머지

차수 내 PR을 전부 머지한다. **머지 주체는 메인 에이전트다** — 서브에이전트에게 넘기지 않는다.

```bash
gh pr merge {PR번호} --squash --delete-branch
```

충돌하면 하나를 머지한 뒤 나머지를 rebase 하고 재머지한다.

```bash
git fetch origin {base}
git rebase origin/{base}
git push --force-with-lease origin feat/{브랜치명}
```

⚠️ `--force-with-lease`만 쓴다. 그냥 `--force`는 금지.

### 5-6. dev 배포 (`--verify-at-end`면 스킵 — Step 6에서 한 번에)

**dev EKS는 수동 트리거가 아니라 GitOps 자동 배포다.** `dev`에 push(=PR 머지)되는
순간 이미지 빌드→ECR push→GitOps writeback PR 생성까지 자동으로 시작된다 —
`gh workflow run ...`으로 사람이/에이전트가 켤 게 없다. (staging/prod는 여전히 수동
`workflow_dispatch`일 수 있다 — `--base staging` 등 dev 외 타겟이면 실제 배포 방식을
먼저 확인하고 진행한다.)

이 단계에서 할 일은 **트리거가 아니라 확인**이다. `np-eks-debug` 스킬을 그대로 쓴다:

```
Skill(skill: "np-eks-debug", args: "dev 배포 확인 — {차수}차 머지 커밋 {sha}이(가)
  backend/engine pod 이미지에 반영됐는지, GitOps writeback PR이 막혀있지 않은지")
```

`np-eks-debug`가 다음을 순서대로 확인해준다 (직접 반복 구현하지 말고 위임):
1. GitHub Actions의 `⛵ K8s [...] build → ECR → GitOps` 워크플로 완료 여부
2. `np-k8s-platform` 리포의 writeback PR — **auto-merge가 걸려 있어도 `mergeStateStatus:
   BEHIND`면 자동으로 안 머지된다.** 이 상태면 `gh api repos/nota-github/np-k8s-platform/
   pulls/{N}/update-branch -X PUT`로 브랜치를 갱신해 재시도를 유도한다.
3. ArgoCD Application의 `sync.revision`이 GitOps 리포 최신 커밋과 일치하는지
4. 실제 pod 이미지 태그가 목표 커밋 sha로 갱신됐는지 (`kubectl rollout status`까지)

**viewer role이라 ArgoCD 강제 refresh는 못 한다** — poll 주기(대략 3분)를 기다려야
한다. 완료까지 보통 5~15분 걸린다. `ScheduleWakeup`으로 폴링하며 기다린다(매번 처음부터
확인하지 말고, 직전에 어디까지 확인했는지 이어서).

배포 실패 시 원인을 구분한다: writeback PR이 BEHIND로 막힌 것처럼 **재시도로 풀리는
것**은 위 절차대로 직접 해소한다. GitHub Actions 빌드 자체가 실패했거나 ECR 인증이
깨진 것처럼 **코드로 못 고치는 인프라 실패**는 즉시 중단하고 보고한다.

### 5-7. E2E 검증 (`--verify-at-end`면 스킵 — Step 6에서 한 번에)

차수 구성으로 방식이 갈린다.

| 차수 구성 | 검증 |
|---|---|
| **Client 포함** | np-enterprise 프로젝트 스킬 `client-verify` 호출 |
| **Backend·Engine만** | 그 차수가 바꾼 **엔드포인트만** 직접 API 호출 |
| **Common만** | 소비처 배포 후 영향받는 API 호출 |

**Client 포함일 때:**

```
Skill(skill: "client-verify", args: "{depth}")
```

depth는 `client-verify` 스킬 자체가 정의한 **누적 단계**(`init ⊂ run ⊂ evaluate ⊂
analyze ⊂ report ⊂ export`)에서 고른다 — `profile`은 depth 값이 아니다(존재하지 않는
값을 넘기면 스킬이 이를 인식 못 한다). "profile 관련 변경을 검증하고 싶다"는 목적이면
`depth=run`으로 실제 파이프라인을 돌리되, profile/evaluate 결과가 DB(`measurement_
execution` 등)에 기대한 시점·형태로 저장됐는지는 client-verify 완료 후 별도로
dev RDS를 직접 조회해서 확인한다(`np-eks-debug` 또는 직접 kubectl exec 패턴,
[[backend-pod-db-access]] 참고) — client 출력 표만으로는 "언제 저장됐는지" 같은
타이밍 증거를 못 본다.

| 변경 범위 | depth |
|---|---|
| 기본 | `init` |
| 실행 경로·step 단위 처리 변경 | `run` |
| 조회/리포트 표면 변경 | `report` |

`client-verify` 스킬이 상정한 접속 대상 표(`--env dev|staging`)를 그대로 따른다 — env
별 URL 4종(`NP_CLIENT_API_URL` 등)을 손으로 다시 조합하지 말고 그 스킬에 위임한다.
⚠️ `10.169.20.121`은 **profiler 전용**이다. backend URL로 쓰지 않는다.

**Backend·Engine만일 때:**

티켓의 "변경 대상"에서 바뀐 엔드포인트를 추려 dev 백엔드에 직접 호출한다.

```bash
curl -sS -X GET "http://10.169.10.30:8000/{바뀐 경로}" -H "Authorization: Bearer {토큰}" | jq .
```

확인할 것: HTTP 상태, 응답 스키마에 이번 차수가 추가/제거한 필드가 반영됐는지,
제거 티켓이면 **없어야 할 필드가 실제로 사라졌는지**.

검증 실패 시 **메인이 수정 → 후속 커밋 → 재배포 → 재검증**. **revert 하지 않는다.**
이미 다음 차수 브랜치가 그 위에 설 예정이라 되돌리면 더 꼬인다.

### 5-8. PR 코멘트 (`--verify-at-end`면 스킵 — Step 6에서 한 번에)

**검증 결과를 그 차수 PR 전부에 남긴다. 생략 불가.**

```bash
gh pr comment {PR번호} --body "$(cat <<'EOF'
## 🧪 {N}차 dev 실측 검증

| 항목 | 값 |
|---|---|
| 배포 | backend run {id} ✅ / engine run {id} ✅ |
| 검증 방식 | client-verify (depth=run) |
| 결과 | ✅ 통과 |

{검증 상세 — 호출한 명령/엔드포인트와 응답 요약}
EOF
)"
```

`client-verify`는 Step 7에서 PR 실측 코멘트를 스스로 남긴다. 그 경우 중복으로 달지 말고
**차수 요약만** 추가한다.

머지된 PR에도 코멘트는 달린다.

---

## Step 6 — 최종 검증 + 리포트

### `--verify-at-end`일 때 — 여기서 전 차수분 배포·검증·코멘트를 한 번에

모든 차수의 PR이 머지된 뒤, 건너뛴 5-6·5-7·5-8을 **차수별로 반복하지 않고 한 번**
수행한다:

1. **배포 확인**: 마지막 차수까지 머지된 `origin/{base}` 최신 커밋 sha 기준으로
   5-6과 동일하게 `np-eks-debug`에 위임해 backend/engine 배포가 최신 커밋까지
   반영됐는지 확인한다. 여러 차수의 Module이 섞여 있으면(예: Common+Engine+Backend)
   그 합집합 컴포넌트 전부의 pod 이미지를 확인한다.
2. **검증**: 전체 차수 중 Client가 포함됐으면 `client-verify`를 필요한 최대 depth로
   한 번 돌린다. Client가 없으면 각 차수가 바꾼 엔드포인트를 모아 한 번에 API 호출로
   확인한다.
3. **PR 코멘트**: 검증에서 나온 실측 결과(타임스탬프, DB 조회 결과 등)를 **모든 차수의
   PR 전부에** 남긴다 — 한 차수만 검증한 게 아니라 전체가 함께 배포된 상태에서 나온
   결과이므로, 각 PR에 같은 내용을 남기고 "이 PR 하나만으로 낸 결과가 아니라 {관련
   PR 목록}이 함께 반영된 상태의 통합 검증"이라고 명시한다. 검증 도중 처음 낸 결론에
   빠진 부분이 드러나 사용자가 정정을 요청하면, 같은 PR들에 보완 코멘트를 추가로
   남긴다(기존 코멘트를 지우거나 덮어쓰지 않는다 — 무엇을 놓쳤고 무엇으로 정정했는지가
   그 자체로 기록이다).

### 항상 — 모든 차수가 끝나면

`client-verify`를 **최대 depth(`report`)** 로 한 번 더 돌려
이관 전체가 살아 있는지 확인한다.

```markdown
## 🏁 {스토리키} 전체 완료

| 차수 | 티켓 | PR | 배포 | 검증 |
|---|---|---|---|---|
| 1차 | 8137, 8138 | #2751, #2752 | backend ✅ | API ✅ |
| 2차 | 8139, 8140 | #2753, #2754 | backend+engine ✅ | API ✅ |
...

### 최종 client-verify (depth=report)
| 단계 | 결과 |
|---|---|
| workspace init | ✅ |
| run --wait | ✅ |
| profile | ✅ |
| report | ✅ |

### 내가 임의로 정한 것 {N}건
1. **{차수}차 {티켓키}** — {무엇을 정했는지}
   근거: {왜 그렇게 정했는지}. 티켓 미명시.
...

### 남은 것
- {중단됐거나 후속이 필요한 항목}
```

**결정 로그가 핵심이다.** 티켓에 안 적힌 것을 임의로 정할 때마다 *무엇을 · 왜 · 어디서*를
상태 파일에 쌓았다가 여기서 한꺼번에 내놓는다. 차수마다 짧게도 흘린다.

### 차수별 중간 보고 형식

```
✅ 2차 완료 (34분)
   8139 PR #2753 머지 · 8140 PR #2754 머지
   배포 backend+engine → dev (run 12847)
   검증 API 3개 호출 ✅ → PR 코멘트 완료
   결정 1건: 8140에서 echo 필드명을 measurement_ref 로 정함 (티켓 미명시)
```

---

## 실패 처리

| 단계 | 실패 | 대응 |
|---|---|---|
| 5-2 디스패치 | Agent가 PR 없이 종료 | 메인이 worktree 진입 → 마무리 → push → PR |
| 5-2 디스패치 | 아키텍처 테스트 red | **구현이 틀린 것.** 메인이 수정 |
| 5-4 CI | 워크플로 red | 로그 읽고 메인이 수정 → push → 재확인 |
| 5-5 머지 | 차수 내 PR끼리 충돌 | 하나 머지 → 나머지 rebase → 재머지 |
| 5-6 배포 | GitOps writeback PR이 BEHIND로 auto-merge 안 됨 | `update-branch` API로 갱신 재시도 (재시도로 풀리는 것) |
| 5-6 배포 | 이미지 빌드/ECR push 자체 실패 | **인프라면 즉시 중단**, 코드 원인이면 수정 |
| 5-7 검증 | client-verify / API 실패 | 후속 커밋 수정 → 재배포 → 재검증 |

### 중단 조건 (무한루프 방지)

- **같은 차수에서 수정 시도 3회 실패 → 중단하고 보고.** 상태 파일이 남으므로 사람이 고친 뒤
  같은 명령으로 재개된다.
- **인프라 실패는 재시도하지 않는다.** dev EC2 다운, 레지스트리 장애, 인증 만료는 코드로
  고칠 수 없다. 즉시 멈추고 무엇이 죽었는지 보고한다.

"사람 개입 0회"는 정상 경로 얘기다. 못 고치는 걸 무한히 붙잡는 건 다른 문제다.

---

## 상태 파일

`~/.claude/impl-wave/{스토리키}.json`

```json
{
  "story": "NPP02-8136",
  "base": "dev",
  "verify_at_end": false,
  "waves": [
    { "n": 1, "tickets": ["NPP02-8137", "NPP02-8138"],
      "status": "verified",
      "prs": [2751, 2752], "deploy_run": 12846, "verify": "api" },
    { "n": 2, "tickets": ["NPP02-8139", "NPP02-8140"],
      "status": "dispatched" }
  ],
  "decisions": [
    { "wave": 2, "ticket": "NPP02-8140",
      "what": "echo 필드명을 measurement_ref 로 정함",
      "why": "티켓에 필드명 미명시. common 계약(8138)의 명명 규칙을 따름" }
  ],
  "retries": { "2": 1 }
}
```

`status` 전이: `pending → dispatched → merged → deployed → verified`

- 각 하위 단계가 끝날 때마다 갱신한다. 세션이 끊겨도 여기까지는 남는다.
- 재호출 시 `verified`가 아닌 **첫 차수부터** 재개한다.
- `retries`가 3에 도달한 차수는 재개 시 사용자에게 먼저 알린다.
- `verify_at_end: true`면 각 차수는 `merged`에서 멈추고(`deployed`/`verified`로
  안 넘어감), Step 6에서 전체가 한 번에 `deployed`→`verified`로 전이한다.

---

## 주의사항

- **실행 위치는 np-enterprise 워킹 디렉토리.** `client-verify`는 그 repo의 프로젝트 스킬이다.
- **자동 머지는 dev를 직접 바꾼다.** 스킬 호출이 그 승인이다. 확신 없으면 `--dry-run`부터.
- **차수 표가 틀리면 전부 어긋난다.** Step 4의 확인이 유일한 안전장치이므로 근거 표기(`추론`)를
  반드시 보고 넘어간다.
- 브랜치는 **매 차수 새로 딴다.** 앞 차수 머지분이 base에 들어간 뒤여야 한다
  (`--verify-at-end`도 마찬가지 — 배포 여부와 무관하게 머지된 **소스**는 새 브랜치에 필요하다).
- `--force-with-lease`만 쓴다. `--force` 금지.
- dev·staging·main에 직접 커밋 금지 (머지는 `gh pr merge`로만).
- **dev EKS 배포는 GitOps 자동화다** — push(머지) 자체가 트리거이고, 사람/에이전트가
  워크플로를 수동으로 켤 필요가 없다. `workflow_dispatch` 수동 트리거가 필요한 대상은
  다른 배포 방식(EC2 등)이니 `--base`로 dev 외 환경을 지정했다면 실제 배포 방식부터
  확인한다.
- EKS 배포 확인·writeback PR 상태·ArgoCD sync는 **`np-eks-debug` 스킬에 위임**한다.
  같은 조사를 여기서 처음부터 다시 짜지 않는다.
- `10.169.20.121`은 profiler 전용 — backend URL 아님.
- `client-verify`의 depth 값은 `init/run/evaluate/analyze/report/export` 뿐이다.
  `profile` 같은 임의 문자열을 depth로 넘기지 않는다 — 검증 목표가 profile/evaluate
  결과물이면 `depth=run`으로 실행한 뒤 DB를 별도로 조회한다.

## 관련 도구

- `mcp__atlassian__getJiraIssue` / `searchJiraIssuesUsingJql`: 티켓·링크 수집
- `Agent` (isolation=worktree, background): 티켓별 병렬 구현
- `gh pr checks` / `gh pr merge` / `gh pr comment`: CI·머지·코멘트
- `Skill(np-eks-debug)`: dev EKS GitOps 배포 반영 여부·writeback PR·ArgoCD sync 확인
- `Skill(client-verify)`: np-enterprise 프로젝트 스킬 — dev 실측 검증
- `ScheduleWakeup`: GitOps 배포 완료(수 분~10분+)를 폴링하며 기다릴 때

## 관련 스킬

| 스킬 | 관계 |
|---|---|
| `/story-to-spec` | 이 스킬의 입력(스토리 + 하위 Task)을 만든다. 티켓 키를 직접 나열하면 이 단계를 건너뛸 수도 있다 |
| `/implement` | 티켓 1건 실행을 담당. 이 스킬이 그대로 재사용한다 |
| `client-verify` (np-enterprise) | 차수 검증과 최종 검증의 정본 |
| `np-eks-debug` | dev/stg EKS 배포·GitOps·ArgoCD 상태 확인의 정본. 5-6/Step 6 배포 확인이 위임하는 곳 |
| `/spec-diff` | 완료 후 기획 문서와 대조할 때 |
