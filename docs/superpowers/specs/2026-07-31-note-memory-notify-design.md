# /note 메모리 + 알림 훅 개선 설계

- 날짜: 2026-07-31
- 신규 스킬: `note`
- 신규 훅: `UserPromptSubmit`, `Stop`(교체), `SessionStart`, `SessionEnd`
- 관련 없음 (내부 도구 개선, Jira 티켓 없음)

## 배경

프롬프트 기록 5,945건(211세션, 2026-03-11 ~ 07-31)을 분석한 결과 두 가지 손실이 확인됐다.

**1. 세션 간 지식 소실.** 질문성 프롬프트 1,870건 중 34%가 시스템·도메인 규명형이다
(*"기존에는 .input.npir 만들 때 HF인 경우 어떻게 했는지"*, *"presigned URL은 누가 발급하는지"*).
이 질문의 답 — 코드를 읽어도 안 나오는 소유권 판정·함정·검증된 환경값 — 이 세션 종료와 함께 사라진다.
세션당 프롬프트 중앙값이 10건이라 맥락을 계속 새로 세운다.

> **정정(구현 중 확인).** 최초 분석은 "영구 메모리 디렉터리가 완전히 비어 있다"고 적었으나 이는 틀렸다.
> `-ssd1-home-wonseon-song` 한 곳만 보고 내린 결론이었고, 실제로는 np-enterprise 프로젝트에
> 메모리 49건이 이미 쌓여 있었다. 다만 그중 `Source` 근거가 붙은 것은 0건이어서 stale 감지 대상이
> 아니었다 — 즉 "기록은 하고 있으나 근거가 없어 낡음을 알 수 없는" 상태였고, 이 설계의 목표는
> 유효하다.

**2. 알림이 신호 역할을 못 함.** 현재 `Stop` 훅의 Slack 알림이 매 응답마다 발화하고,
본문은 대부분 `📝 요청: (확인 불가)`로 나온다.

## 확정된 결정

| # | 결정 | 근거 |
|---|---|---|
| 1 | 메모리 실체는 **단일 저장소 + 경로별 symlink** | 작업 경로가 sdk/qa/backend/루트로 갈리는데, 기록 대상의 상당수가 경계면 사실이라 양쪽에서 보여야 함 |
| 2 | 기록은 **수동 `/note`**, 자동 추출 없음 | 오탐이 섞이면 검증 신뢰가 깨져 도구 자체를 안 쓰게 됨 |
| 3 | **git 기반 stale 감지**, 심볼 단위 판정 | 낡은 메모리는 오염원. 파일 단위는 오탐이 많아 경고가 무시됨 |
| 4 | 알림은 **오래 걸린 턴만 + 세션 종료 요약** | 알림의 실제 용도는 "자리 비운 사이 끝났나". 20초 턴은 알릴 이유가 없음 |
| 5 | 서버 간 동기화·팀 공유는 **비목표** | 필요해지면 별도 설계 (YAGNI) |

---

## 설계 A — 구성 요소

```
~/claude-skills/note/
  SKILL.md
  scripts/memory-check.sh      # SessionStart — stale 감지
  scripts/stamp-start.sh       # UserPromptSubmit — 턴 시작 시각 기록
  scripts/notify-stop.sh       # Stop — 3분 이상 턴만 Slack
  scripts/notify-session.sh    # SessionEnd — 세션 요약 + note 누락 경고

~/claude-memory/np-enterprise/   # 메모리 실체 (git 아님)
  MEMORY.md                      # 인덱스 (매 세션 자동 로드)
  presigned-url-issuer.md
  tar-snapshot-flat-error.md
```

### symlink 대상

`setup.sh`에 루프를 추가해 아래 프로젝트 디렉터리의 `memory/`를
`~/claude-memory/np-enterprise/`로 연결한다.

```
~/.claude/projects/-ssd1-home-wonseon-song-test2-np-enterprise/memory
~/.claude/projects/-ssd1-home-wonseon-song-test2-np-enterprise-{sdk,qa,backend,engine,client,common}/memory
```

- 프로젝트 디렉터리는 cwd 경로의 `/`를 `-`로 치환한 이름이다.
- `/home/wonseon.song`와 `/ssd1/home/wonseon.song`는 같은 트리지만, 현재 프로젝트 디렉터리는
  전부 `-ssd1-` 접두사로만 생성돼 있다. 스크립트는 `realpath`로 정규화해 `-ssd1-` 형태만 만든다.
- 대상 디렉터리가 없으면 생성한다.
- 대상 자리에 이미 심볼릭 링크가 있으면 그냥 갱신한다.
- 대상 자리에 이미 실디렉터리가 있고 그 안에 실제 메모리 파일이 있으면 **백업 후 교체가 아니라
  흡수(adopt) 후 교체**한다: 저장소에 없는 파일은 저장소로 옮기고, 이름은 같은데 내용이 다른
  파일만 덮어쓰지 않고 `.bak`에 남겨 보고한다. `MEMORY.md` 인덱스는 클로버하지 않고 병합한다.
  (최초 설계는 "백업 후 symlink로 교체"였다 — `setup.sh`의 기존 스킬 symlink 처리와 동일 규칙.
  하지만 이 경로가 실제로 메모리 파일이 든 디렉터리를 통째로 `.bak`으로 치워버려 메모리가
  전부 로드되지 않는 사고로 이어져, 흡수 방식으로 바꿨다.)
- 대상 자리에 디렉터리가 아닌 다른 노드(평범한 파일 등)가 있으면 기존대로 백업 후 symlink로
  교체한다 — 이 경우는 병합할 메모리 내용이 없으므로 단순 백업으로 충분하다.

---

## 설계 B — 메모리 파일 포맷

프론트매터는 하네스 규격을 그대로 지키고, 근거는 본문에 grep 가능한 고정 형식으로 둔다.
프론트매터에 비표준 키를 넣지 않는 이유는, 규격 외 키의 처리 방식이 보장되지 않기 때문이다.

```markdown
---
name: presigned-url-issuer
description: presigned URL은 백엔드가 발급하고 np-client는 조립하지 않는다
metadata:
  type: project
---

presigned URL은 백엔드가 발급한다. np-client는 URL을 조립하지 않고 응답을 그대로 사용한다.

**Source:** `backend/src/pynp/api/v1/models.py#create_presigned_url@a1b2c3d`
**Verified:** 2026-07-31 (NPP02-6405)
```

- `Source` 형식: `<repo 상대경로>#<심볼>@<커밋 해시>`. 심볼을 특정할 수 없으면 `#` 부분을 생략한다.
- `Verified` 형식: `YYYY-MM-DD` + 선택적 `(티켓키)`.
- `MEMORY.md` 인덱스는 메모리당 정확히 한 줄: `- [제목](파일.md) — 한 줄 요약`.

---

## 설계 C — `/note` 스킬

```
/note "presigned URL은 백엔드가 발급, np-client는 조립 안 함"
/note --check              # stale 재검사 수동 실행
/note --verify <name>      # ⚠ 해제 (아래 3가지를 함께 갱신)
```

### 동작 순서

1. **근거 추출** — 직전 대화에서 참조한 파일·심볼과 현재 HEAD 커밋을 자동으로 찾는다.
   찾지 못하면 그때만 사용자에게 한 번 되묻는다.
2. **중복 검사** — 기존 메모리의 `description`과 대조해 같은 사실이면 새로 만들지 않고 갱신한다.
3. **쓰기** — 메모리 파일 생성/갱신 + `MEMORY.md` 인덱스 한 줄 추가.

`--verify`는 세 가지를 함께 갱신한다. 하나라도 빠지면 다음 세션에 `⚠`가 그대로 다시 붙는다.

1. `Source`의 커밋 해시를 현재 HEAD로 갱신 (재확인한 시점 기준으로 비교 기준선을 옮김)
2. `Verified` 날짜를 오늘로 갱신
3. `MEMORY.md` 해당 줄의 `⚠` 제거

내용이 실제로 바뀌었으면 `--verify`가 아니라 `/note`로 갱신한다.

### 기록 기준 (SKILL.md에 명시)

| 남긴다 | 남기지 않는다 |
|---|---|
| 소유권·경계 판정 (누가 발급/조립/저장하는가) | 코드를 읽으면 나오는 사실 |
| 재현된 함정 (tar에 snapshot 없으면 flat 구조로 에러) | 일회성 디버깅 로그 |
| 검증된 환경값 (`SDK_DEPLOYMENT=internal` → profiler 실제 송수신) | 티켓·PR에 이미 적힌 것 |
| 의도적 예외·금지 영역 | 검증 전 추측 |

---

## 설계 D — stale 감지 (`SessionStart`)

`memory-check.sh`는 `MEMORY.md`의 각 항목에서 `Source`를 파싱해 판정한다.

**`git log -L`은 쓰지 않는다.** 실측 결과 `git log -L :__init__:<file> <base>..HEAD`가
`fatal: -L parameter '__init__' starting at line 1: no match`로 종료(rc=128)했다.
`-L`은 심볼을 시작 리비전 기준으로 해석하고 funcname 패턴에 의존해 Python 메서드에서 신뢰할 수 없다.

대신 **AST 기반 심볼 비교**를 쓴다 (`scripts/symbol_diff.py`).

1. `git show <base>:<path>` 와 `git show HEAD:<path>` 로 두 시점의 소스를 얻는다
2. 각각 `ast.parse` 후 이름이 일치하는 `FunctionDef`/`AsyncFunctionDef`/`ClassDef` 를 찾는다
3. `ast.get_source_segment` 로 뽑은 소스 조각을 문자열 비교한다

동일 파일에서 4케이스가 정확히 구분되는 것을 확인했다
(`__init__`→UNCHANGED, `StepParamsBuilder`→CHANGED, 없는 심볼→MISSING, 없는 파일→MISSING).

| 상황 | 판정 | 표시 |
|---|---|---|
| 심볼 소스가 달라짐 | `CHANGED` (rc=1) | `⚠` |
| 심볼 소스가 동일 | `UNCHANGED` (rc=0) | 표시 없음 |
| HEAD에 심볼·파일 없음 | `MISSING` (rc=2) | `⚠ 삭제됨` |
| Python이 아닌 파일 / 심볼 미지정 | 파일 단위 폴백 | `git log --format=%h <commit>..HEAD -- <path>` 출력 있으면 `⚠` |
| 커밋 해시 없음/무효 | 검사 건너뜀 | 표시 없음 |

- 훅은 `MEMORY.md`만 수정하고, 요약 한 줄(`⚠ 재확인 필요 2건`)을 세션 시작 컨텍스트로 올린다.
- 항목이 200건(`CC_MEMORY_MAX`)을 넘으면 검사를 건너뛰고 "메모리 정리 필요" 경고만 낸다.
  세션 시작 지연을 만들지 않기 위해서다. (최초 설계값은 50건이었으나, 실사용 저장소가
  이미 49건이라 상한 50은 곧 검사를 조용히 꺼버린다는 게 드러나 200으로 올렸다.)
- 상한 밑이라도 검사에는 시간 예산(`CC_MEMORY_BUDGET_SEC`, 기본 2초)이 있다. `Source`가
  있는 항목마다 `symbol_diff.py`가 `git show`를 두 번 포크해 항목 수만큼 검사 시간이
  누적되므로(실측: 49건 루프 1.1초 + Source 있는 항목당 +0.18초), 예산을 넘기면 그 순간부터
  나머지 항목은 검사하지 않고 이전 표시를 그대로 둔 채 건너뛴다. 결과 메시지는 상한 초과
  "정리 필요"와 구분되는 "부분 검사"이며 건너뛴 건수를 알린다.
- repo 경로는 `~/claude-memory/np-enterprise/.repo` 파일에 기록한 경로를 쓴다(기본값: `/ssd1/home/wonseon.song/test2/np-enterprise`).

---

## 설계 E — 알림 (`UserPromptSubmit` / `Stop` / `SessionEnd`)

### 현재 훅의 결함과 원인

| 증상 | 원인 |
|---|---|
| `📝 요청: (확인 불가)` | `tail -n 400` 안에 `content`가 문자열인 user 레코드가 없음. 실측 결과 user 레코드 30건 중 25건이 `list`(도구 결과·첨부) |
| 간헐적 완전 실패 | `jq -rs`(slurp)는 줄 하나만 깨져도 전체가 빈 값이 됨 |
| 경로가 `/home/...`로 나옴 | `$(pwd)`의 논리 경로 사용. 훅 stdin의 `cwd`를 써야 함 |
| 매 응답마다 발화 | `Stop`은 사양상 "Claude가 응답을 마칠 때"마다 발화 |

### 타이밍

`UserPromptSubmit` 훅(`stamp-start.sh`)이 `/tmp/claude-notify/<session_id>.start`에 시작 시각을 쓴다.
`Stop` 훅이 `now - start`로 경과를 계산한다. 트랜스크립트 레코드 구조에 의존하지 않으므로
내부 포맷이 바뀌어도 타이밍은 깨지지 않는다.

### 메시지 — 긴 작업 완료 (`Stop`, 경과 ≥ `CC_NOTIFY_MIN_SEC`, 기본 180초)

```
✅ 작업 완료 (12분)
📁 np-enterprise/engine · feat/NPP02-6405
📝 요청: 레거시 검증기에 AMP 예외 추가 진행해줘
💬 결과: AMP 예외 3곳 추가, 테스트 통과. PR #2412 생성함.
```

- `요청` = 트랜스크립트의 `{"type":"last-prompt","lastPrompt":...}` 레코드 (배열 파싱 불필요)
- `결과` = 훅 stdin의 `last_assistant_message` 앞 200자, 마크다운·코드블록 제거 후 개행을 공백으로 치환
- `📁` = 훅 stdin의 `cwd` 마지막 2단계 + 현재 git 브랜치

### 메시지 — 세션 종료 (`SessionEnd`)

```
🏁 세션 종료 · np-enterprise/engine · 47분 · 18턴
📌 AMP 예외 처리 및 회귀 테스트
🧠 note 0건 — 확정한 사실이 있었다면 /note 로 남기세요
```

- `📌` = 트랜스크립트의 마지막 `{"type":"ai-title","aiTitle":...}` 레코드
- `🧠` 줄은 **이번 세션의 `/note` 호출이 0건이고 사용자 프롬프트가 5개 이상일 때만** 붙인다.
  짧은 확인용 세션은 조용히 넘어간다.
  - 두 수치 모두 트랜스크립트의 `last-prompt` 레코드로 센다.
    사용자 프롬프트 수 = `last-prompt` 레코드 수, `/note` 호출 수 = `lastPrompt`가 `/note`로 시작하는 레코드 수.
  - `18턴`도 같은 값을 쓴다.
- 세션 종료 시 `/tmp/claude-notify/<session_id>.*` 를 정리한다.

### 견고성 규칙

1. `jq -s`(slurp) 금지. 줄 단위로 읽고 파싱 실패한 줄은 건너뛴다.
2. `tail -n N` 금지. 필요한 타입만 전체 스캔한다.
3. 모든 필드에 폴백을 둔다: `last_assistant_message` → `last-prompt` → `(내용 없음)`.
   "(확인 불가)"가 다시 나오지 않게 한다.
4. 훅 실패가 세션을 막지 않게 `|| true`, `async: true`를 유지한다.
5. Slack 웹훅 URL은 스크립트에 하드코딩하지 않고 `~/.claude/.slack-webhook`에서 읽는다.
   파일이 없으면 알림을 조용히 건너뛴다.

---

## 비목표 (YAGNI)

- 서버 간 메모리 동기화
- 팀 공유 / repo 커밋
- 대화에서 사실을 자동 추출해 메모리 생성
- 메모리 자동 삭제·만료

---

## 검증

### `notify-stop.sh`

| 케이스 | 기대 |
|---|---|
| 경과 3분 미만 | 전송 안 함 |
| 경과 3분 초과 | 전송, 요청·결과 모두 채워짐 |
| 트랜스크립트에 깨진 줄 포함 | 해당 줄만 건너뛰고 정상 전송 |
| `last_assistant_message` 없음 | `last-prompt`로 폴백, "(확인 불가)" 안 나옴 |

### `memory-check.sh`

| 케이스 | 기대 |
|---|---|
| 근거 심볼이 변경됨 | `⚠` 표시 |
| 근거 심볼이 그대로 | 표시 없음 |
| 근거 파일 삭제됨 | `⚠ 삭제됨` |
| 커밋 해시 없음/무효 | 건너뜀, 에러 없음 |

### 실사용 확인

이미 확정된 사실 3건을 손으로 `/note`에 넣고, 새 세션 시작 시 인덱스가 로드되는지와
`⚠` 표시가 의도대로 붙는지 확인한다.

## 마이그레이션

기존 `~/.claude/settings.json`의 `Stop` 훅(인라인 셸)은 `notify-stop.sh` 호출로 교체한다.
교체 전 `settings.json`을 백업하고, 하드코딩된 Slack 웹훅 URL은 `~/.claude/.slack-webhook`로 옮긴다.
