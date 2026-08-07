# `/impl-wave` — 티켓 의존 그래프 기반 병렬·순차 구현 스킬 설계

- 날짜: 2026-08-07
- 신규 스킬: `impl-wave`
- 함께 수정: `README.md`, `CLAUDE.md`
- 재사용: `implement`(티켓 1건 실행), np-enterprise `.claude/skills/client-verify`(실측 검증)
- 대상 데이터: Jira NPP02(티켓·링크), `nota-github/np-enterprise`(PR·CI/CD·dev 환경)

## 배경

`/story-to-spec`이 스토리 하나에서 티켓 9개를 뽑아내면, 그다음이 비어 있다.
`/implement`은 **티켓 1건**만 안다 — 브랜치 따고 에이전트 띄우고 PR 만들고 끝이다.

그래서 9개를 굴리려면 사람이 매번 이 판단을 대신 해야 한다:

- 지금 어떤 티켓들을 **동시에** 띄워도 되는가 (의존 없음 + 파일 안 겹침)
- 앞 티켓 PR이 dev에 들어가야 뒷 티켓 에이전트가 그 코드를 본다 — 언제 머지하나
- 머지만으로 충분한가, **배포까지** 확인해야 다음이 가능한가
- 배포 후 무엇으로 확인하나

이 판단을 사람이 9번 반복하면 파이프라인이 사람 속도로 떨어진다. 이 스킬이 그 칸을 채운다.

### 왜 지금 이 형태인가 (실측 확인 사항)

| 확인 대상 | 결과 | 설계에 미친 영향 |
|---|---|---|
| `enterprise-backend-cicd.yml` / `enterprise-engine-cicd.yml` | **`workflow_dispatch` 전용**, `environment` choice 입력(dev 기본) | 배포는 `gh workflow run --ref <브랜치> -f environment=dev`. 임의 브랜치도 dev 환경에 올릴 수 있다 |
| np-enterprise 기본 브랜치 | `dev` | 차수 브랜치의 base = `dev` |
| `story-to-spec/SKILL.md:496` | **"Jira 링크는 생성하지 않음"** — Task↔Task 선행 링크 없음. 스토리 링크(`Task ─Blocks→ Story`)만 생성 | 링크만 믿으면 차수를 못 읽는다. **다중 근거 + 시작 전 1회 확인**이 필수가 된 이유 |
| np-enterprise `.claude/skills/client-verify` (PR #2715, 머지됨) | np-client를 wheel+venv로 dev 백엔드에 대고 실측. depth `init⊂run⊂profile⊂report`. Step 7이 **PR 실측 코멘트**까지 수행 | E2E를 새로 만들지 않는다. 이 스킬을 호출한다. PR 코멘트 요구사항도 이미 충족 |
| np-enterprise `.claude/skills/np-e2e` | 양자화 파이프라인(project→run→export) E2E | **이 스킬이 쓰는 검증이 아니다.** 목적이 다름 |

## 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| 1 | **차수(wave) = 병렬 묶음.** 같은 차수는 동시 디스패치, 차수 간은 순차 | `/story-to-spec` 산출물이 이미 `[1차]/[2차]` 형태의 실행 순서를 갖는다. 그 단위를 그대로 실행 단위로 삼는다 |
| 2 | **dev 직행 머지 게이트** — 차수 PR을 dev에 머지한 뒤 다음 차수 브랜치를 dev에서 딴다 | 통합 브랜치·스택 브랜치도 검토했으나, 배포·검증이 **진짜 dev 상태**여야 의미가 있다. 사용자의 현행 방식과도 같다 |
| 3 | **전부 자동 머지. 머지 주체는 메인 에이전트** | 스킬 호출 자체가 승인이다. 차수마다 다시 묻지 않는다. 서브에이전트에게 dev 쓰기 권한을 주지 않기 위해 머지는 오케스트레이터가 한다 |
| 4 | **버그는 메인 에이전트가 직접 수정** — 서브에이전트 재디스패치 안 함 | 실패 맥락(로그·diff·앞 차수 결정)이 메인에 있다. 새 에이전트에 그걸 다시 주입하는 비용이 수정 비용보다 크다 |
| 5 | **revert 안 함.** 머지 후 문제는 후속 커밋으로 수정 | 되돌리면 이미 그 위에 서 있는 다음 차수 브랜치가 더 꼬인다. 4번의 연장 |
| 6 | **검증은 변경 범위로 갈린다** — Client 포함 차수는 `client-verify`, Backend·Engine만이면 해당 API 직접 호출 | client 변경이 없는데 wheel 빌드+venv+auth 전체를 도는 건 낭비다 |
| 7 | **검증 결과는 반드시 그 차수 PR 전부에 코멘트** | 머지 후 문제 추적의 유일한 앵커. `client-verify` Step 7이 이미 하는 일 |
| 8 | **시작 전 차수 표 1회 확인, 이후 개입 0회** | 차수를 잘못 읽으면 9개가 전부 어긋난다. 근거가 추정 섞임(결정 배경 참조)이라 확인 1회의 값이 가장 크다 |
| 9 | **상태 파일로 재개** — `~/.claude/impl-wave/{스토리키}.json` | 9티켓이면 수 시간. 세션이 끊겨도 끊긴 차수부터 재개해야 한다 |
| 10 | **수정 시도 3회 실패 시 중단.** 인프라 실패는 재시도 없이 즉시 중단 | "개입 0회"는 정상 경로 얘기다. 못 고치는 걸 무한히 붙잡는 건 다른 문제고, dev EC2·레지스트리 장애는 코드로 못 고친다 |

## 설계 A — 입력과 차수 판정

### 사용법

```
/impl-wave NPP02-8136              스토리 키 → 하위 Task 전부 → 차수 추정 → 실행
           [--dry-run]             차수 표만 뽑고 끝. 머지·배포·검증 안 함
           [--from N]              상태 파일 무시하고 N차부터 강제 재개
           [--base <브랜치>]       기본 dev
```

같은 스토리 키로 재호출하면 상태 파일을 보고 **끊긴 차수부터 자동 재개**한다.
`--from`은 그 자동 판단을 무시하고 싶을 때만 쓴다.

### Step 1 — 하위 Task 수집

스토리 티켓에서 `Task ─Blocks→ Story` 링크를 타고 하위 Task를 모은다.
링크가 없으면 JQL 보조 검색으로 폴백한다 (`spec-diff` §Step 1과 동일 규칙).

### Step 2 — 의존 그래프 조립

근거를 **우선순위대로** 긁어 간선을 만든다. 낮은 순위는 높은 순위를 덮어쓰지 않는다.

| 순위 | 근거 | 신뢰도 | 표기 |
|---|---|---|---|
| 1 | Jira **Task ↔ Task** issuelink (`Blocks`/`is blocked by`) | 명시적 | `링크` |
| 2 | 각 티켓 description의 `선행 티켓:` 필드 | 명시적 | `선행필드` |
| 3 | 스토리 description의 **구현 순서표** | 명시적 | `순서표` |
| 4 | Module 계층 순서 + "변경 대상" 파일 겹침으로 추론 | 추정 | `추론` |

순위 4의 추론 규칙: 계약이 소비처보다 앞선다(`Common → Backend·Engine`),
스키마가 그 스키마를 쓰는 코드보다 앞선다(`DB Migration → Backend`),
제거 성격 티켓은 그 대상을 안 쓰게 만든 티켓보다 뒤에 온다.

> ⚠️ `story-to-spec`은 순위 1의 링크를 **만들지 않는다.** 대부분의 스토리에서 실제로
> 잡히는 근거는 순위 2~4다. 표에 근거를 반드시 함께 출력해 어디가 추정인지 드러낸다.

### Step 3 — 위상정렬 후 파일 충돌 분리

위상정렬로 차수를 얻은 뒤 **한 겹 더 거른다.**

```
같은 차수 안의 티켓 쌍에 대해 "변경 대상" 파일 목록의 교집합을 구한다.
교집합이 비어 있지 않으면 → 병렬 금지 → 뒤 티켓을 다음 차수로 내린다.
```

의존이 없어도 같은 파일을 동시에 고치면 머지 충돌이 확정이다.
동시 실행 상한은 **4개**. 초과하면 차수를 쪼갠다 (worktree 4개 + 각자 pytest면 이미 무겁다).

> 순위 4의 파일 겹침이 **간선**을 만드는 것과, 이 단계의 파일 겹침이 **같은 차수를 쪼개는**
> 것은 다른 일이다. 앞은 "순서가 있다"는 추정이고, 뒤는 순서가 없어도 "동시에는 못 돈다"는
> 판정이다.

**"변경 대상" 테이블이 없는 티켓**은 파일 목록을 얻을 수 없다. 이때는 겹침을 알 수 없으므로
**병렬로 묶지 않고 단독 차수로 세운다.** 모른다는 이유로 동시에 돌리지 않는다.

### Step 4 — 차수 표 제시 (사람 개입 지점, 유일)

```
1차  8137 스키마 2건        Backend/DB   ⟵ 링크
     8138 common 계약 7건   Common       ⟵ 링크
2차  8139 EVALUATION 병행   Backend      ⟵ 선행필드
     8140 engine 인라인     Engine       ⟵ 선행필드
...
5차  8144 job 생성 제거     Backend  🔴  ⟵ 추론 (파일 겹침)

배포: 1차 backend / 2차 backend+engine / 4차 없음(client) ...
검증: 1차 API / 4차 client-verify(depth=run) ...
→ 이대로 갑니까?
```

`--dry-run`이면 여기서 끝난다.

## 설계 B — 차수 1개를 도는 루프

```
차수 N 시작  (dev = N-1차까지 머지·배포·검증 완료된 상태)
  │
  ├─ 1. 브랜치      티켓마다 dev에서 feat/{키}-{slug} 생성
  │
  ├─ 2. 병렬 디스패치  티켓 수만큼 Agent 동시 기동 (worktree 격리, background)
  │                  각 Agent = 기존 /implement Step 4~5 그대로
  │                  → 구현 → 아키텍처·유닛 테스트 → 커밋 → push → PR
  │
  ├─ 3. 전원 대기    실패한 놈 → 메인이 해당 worktree 진입해 직접 수정 → push
  │
  ├─ 4. CI 확인      gh pr checks → red면 메인이 로그 읽고 수정 → push → 재확인
  │
  ├─ 5. 자동 머지    gh pr merge --squash  (차수 내 전부)
  │
  ├─ 6. dev 배포     차수의 Module 합집합으로 워크플로 선택 (아래 표)
  │                  gh workflow run --ref dev -f environment=dev → gh run watch
  │
  ├─ 7. E2E 검증     변경 범위로 갈림 (아래 표)
  │                  실패 → 메인이 수정 → 후속 커밋 → 재배포 → 재검증
  │
  └─ 8. PR 코멘트    그 차수 PR 전부에 검증 결과 기록
  ▼
차수 N+1
```

### 배포 대상 결정 (Step 6)

차수에 포함된 티켓들의 `Module:` 합집합으로 정한다.

| Module | 워크플로 |
|---|---|
| `Backend`, `DB Migration` | `enterprise-backend-cicd.yml` |
| `Engine` | `enterprise-engine-cicd.yml` |
| `Common` | **소비처 전부** — backend + engine |
| `Client` 단독 | 배포 없음 (검증이 wheel을 직접 빌드한다) |
| `CI` | 해당 없음 |

### 검증 방식 결정 (Step 7)

| 차수 구성 | 검증 |
|---|---|
| Client 포함 | np-enterprise `.claude/skills/client-verify` 호출. depth는 변경 범위로 결정 — `client/src/np_client/**/profile/` 를 건드렸으면 `depth=profile` 이상 |
| Backend·Engine만 | 그 차수가 바꾼 **엔드포인트만** 직접 API 호출로 확인 |
| Common만 | 소비처(backend·engine) 배포 후 영향받는 API 호출로 확인 |

`client-verify`는 dev 기본값(`NP_CLIENT_API_URL=http://10.169.10.30:8000`,
`NP_CLIENT_AUTH_API_URL=https://auth.dev.netspresso.ai`)을 그대로 쓴다.
`10.169.20.121`은 profiler 전용이므로 backend URL로 쓰지 않는다.

## 설계 C — 실패 처리

| 단계 | 실패 | 메인 에이전트 대응 |
|---|---|---|
| 2 디스패치 | Agent가 PR 없이 종료 | worktree 진입 → 남은 작업 마무리 → push → PR |
| 2 디스패치 | 아키텍처 테스트 red | **구현이 틀린 것.** core-free / no-legacy-import 위반을 메인이 수정 |
| 4 CI | 워크플로 red | 로그 읽고 수정 → push → 재확인 |
| 5 머지 | 차수 내 PR끼리 충돌 | 하나 머지 → 나머지 rebase → 재머지 |
| 6 배포 | 배포 워크플로 실패 | 로그 확인 → 원인이 코드면 수정, **인프라면 즉시 중단 후 보고** |
| 7 검증 | client-verify / API 호출 실패 | 후속 커밋으로 수정 → 재배포 → 재검증 |

### 중단 조건

- 같은 차수에서 **수정 시도 3회** 실패 → 중단하고 사용자에게 보고. 상태 파일이 남으므로
  사람이 고친 뒤 같은 명령으로 재개된다.
- **인프라 실패는 재시도하지 않는다.** dev EC2 다운, 레지스트리 장애, 인증 만료는
  코드로 고칠 수 없다. 즉시 중단하고 무엇이 죽었는지 보고한다.

## 설계 D — 상태 파일

`~/.claude/impl-wave/{스토리키}.json`

```json
{
  "story": "NPP02-8136",
  "base": "dev",
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
  ]
}
```

`status` 전이: `pending → dispatched → merged → deployed → verified`

재호출 시 `verified`가 아닌 첫 차수부터 재개한다.

## 설계 E — 리포트

세 지점에서만 말한다.

1. **시작** — 차수 표 + 근거 + 배포/검증 계획 (설계 A Step 4). 여기서 1회 확인
2. **차수마다** — 한 덩어리로 짧게

   ```
   ✅ 2차 완료 (34분)
      8139 PR #2751 머지 · 8140 PR #2752 머지
      배포 backend+engine → dev (run 12847)
      검증 API 3개 호출 ✅ → PR 코멘트 완료
      결정 1건: 8140에서 echo 필드명을 measurement_ref 로 정함 (티켓 미명시)
   ```

3. **끝** — 전체 표 + 최종 `client-verify`(최대 depth) 결과 + **결정 로그 전부**

세 번째의 결정 로그가 핵심이다. 티켓에 안 적힌 것을 메인이 임의로 정할 때마다
*무엇을 · 왜 · 어디서*를 상태 파일에 쌓았다가 마지막에 한꺼번에 내놓는다.

## 문서 중복 금지

`impl-wave`는 티켓 1건을 도는 부분 — 브랜치 생성, 아키텍처 가이드 수집·주입,
Agent 프롬프트 구성 — 을 **`/implement`에서 그대로 가져다 쓴다.** SKILL.md에 다시
쓰지 않고 참조만 한다. `add-task`가 `story-to-spec`의 링크 규칙을 참조하는 것과 같다.

`impl-wave`가 자기 몫으로 갖는 것은 넷뿐이다:

1. 차수 판정 (설계 A)
2. 병렬 디스패치와 대기 (설계 B Step 1~3)
3. 머지 / 배포 / 검증 게이트 (설계 B Step 4~8)
4. 상태 파일과 재개 (설계 D)

np-enterprise 구조 지식은 기존대로 `story-to-spec/references/np-enterprise-structure.md`
**한 곳만** 참조한다.

## 검토했으나 채택하지 않은 것

| 대안 | 기각 사유 |
|---|---|
| **통합 브랜치** (`integration/NPP02-XXXX`를 모든 PR의 base로) | dev를 안 더럽히는 건 장점이나, 배포·검증이 진짜 dev 상태가 아니게 된다. 최종 PR이 9티켓치로 커지고 dev와 drift |
| **스택 브랜치** (차수 N+1을 차수 N 브랜치에서 딴다) | 머지 대기가 0이지만 앞 PR이 수정되면 뒤 전부 리베이스 연쇄. 자동 머지 결정과 조합하면 이점 자체가 사라진다 |
| **차수마다 사람 승인** | 밤새 돌리지 못한다. 스킬 호출이 승인이라는 결정(#3)과 충돌 |
| **차수를 인자로 직접 받기** (`--waves "8137,8138 \| ..."`) | 매번 손으로 써야 한다. 시작 전 확인 1회(#8)로 같은 안전성을 더 싸게 얻는다 |
| **np-e2e로 검증** | 양자화 파이프라인 E2E라 목적이 다르다. 이관 검증에는 `client-verify`가 정본 |
| **실패 시 revert** | 결정 #5 참조 |
