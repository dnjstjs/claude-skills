---
name: note
description: "세션 간 사라지는 도메인 판정을 메모리로 남긴다. 소유권·경계 판정, 재현된 함정, 검증된 환경값을 근거(파일#심볼@커밋)와 함께 기록하고, 근거가 바뀌면 SessionStart에서 ⚠ 로 표시한다. --check 재검사, --verify 재확인 완료."
argument-hint: "<확정한 사실> | --check | --verify <name>"
marketplace: false
---

# Note — 도메인 판정 메모리

## 목적

코드를 읽어도 안 나오는 사실 — 누가 무엇을 소유하는가, 어떤 함정이 있는가 — 은
세션이 끝나면 사라진다. 그걸 근거와 함께 파일로 남겨 다음 세션이 0에서 시작하지 않게 한다.

## 저장 위치

실체는 `~/claude-memory/np-enterprise/` 한 곳이다.
`sdk`/`qa`/`backend`/`engine`/`client`/`common`/루트의 프로젝트 memory 디렉터리를
전부 이곳으로 symlink 해두면, **어느 디렉터리에서 시작하든 같은 메모리가 로드된다.**
이 프로젝트별 symlink 는 `setup.sh` 가 자동으로 만들고 관리한다 — 손으로 걸 필요가 없다.
대상 자리에 이미 실제 메모리 파일이 든 디렉터리가 있으면 그 내용을 저장소로 흡수(adopt)한 뒤
symlink 로 바꾼다: 저장소에 없는 파일은 그대로 옮기고, 이름은 같은데 내용이 다른 파일만
덮어쓰지 않고 `.bak` 에 남겨 보고한다. `MEMORY.md` 인덱스도 클로버하지 않고 병합한다.
경로는 `CC_MEMORY_STORE` 환경변수로 재정의할 수 있다 (`memory-check.sh` 가 읽는 기본값).

기준 repo는 `~/claude-memory/np-enterprise/.repo` 에 적는다.
없으면 `/ssd1/home/wonseon.song/test2/np-enterprise` 를 쓴다.

## 사용법

```
/note "presigned URL은 백엔드가 발급, np-client는 조립 안 함"
/note --check              # stale 재검사 수동 실행
/note --verify <name>      # ⚠ 해제
```

## 기록 기준

**남긴다:**

| 유형 | 예 |
|---|---|
| 소유권·경계 판정 | presigned URL은 백엔드가 발급, np-client는 조립 안 함 |
| 재현된 함정 | tar 에 snapshot 폴더가 없으면 flat 구조로 풀려 에러 |
| 검증된 환경값 | `SDK_DEPLOYMENT=internal` 이면 profiler 와 실제 송수신됨 |
| 의도적 예외·금지 영역 | GQ mpq 구현은 명시 요청 없으면 수정 금지 |

**남기지 않는다:** 코드를 읽으면 나오는 사실 / 일회성 디버깅 로그 /
티켓·PR 에 이미 적힌 것 / 검증 전 추측.

추측을 사실로 적지 않는다. 확인하지 못했으면 기록하지 말고 확인부터 한다.

## 기록 절차 (`/note "<사실>"`)

1. **근거 추출** — 직전 대화에서 참조한 파일 경로와 심볼, 그리고 기준 repo 의 현재 HEAD 커밋을 찾는다.
   찾지 못하면 그때만 사용자에게 한 번 되묻는다. 되묻고도 없으면 `Source` 없이 저장하되,
   stale 검사 대상에서 빠진다는 점을 알린다.
2. **중복 검사** — 저장소의 기존 `description` 과 대조한다. 같은 사실이면 새 파일을 만들지 말고 갱신한다.
3. **쓰기** — 메모리 파일 생성/갱신 + `MEMORY.md` 에 한 줄 추가.

### 파일 형식

프론트매터는 하네스 규격만 쓴다. 비표준 키를 넣지 않는다 — 처리 방식이 보장되지 않는다.

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

- `Source`: `<repo 상대경로>#<심볼>@<커밋 해시>`. 심볼을 특정할 수 없으면 `#<심볼>` 을 생략한다.
- **클래스 메서드는 반드시 `Class.method` 형태로 적는다** (`Outer.Inner.run` 처럼 중첩도 가능).
  bare 이름은 같은 이름이 여러 개일 때(모든 클래스의 `__init__` 등) 위치로 짝지어 비교하므로,
  드물게 변경을 놓칠 수 있다. dotted 이름은 해당 심볼만 정확히 찾는다.
- `Verified`: `YYYY-MM-DD` + 선택적 `(티켓키)`.
- 관련 메모리는 본문에서 `[[다른-메모리-name]]` 으로 잇는다.

### 인덱스 형식

`MEMORY.md` 는 메모리당 정확히 한 줄이다.

```
- [presigned URL 발급 주체](presigned-url-issuer.md) — 백엔드가 발급, np-client는 조립 안 함
```

## `⚠` 표시와 검사 상한

`memory-check.sh`(SessionStart 훅, `--check`로 수동 실행 가능)가 인덱스 줄 앞에 붙이는 표시:

| 표시 | 의미 |
|---|---|
| `⚠ ` | `Source`의 심볼(또는 파일)이 기준 커밋 이후 바뀜 — 재확인 필요 |
| `⚠ 삭제됨 ` | `Source`의 파일이 HEAD 에 없거나, 파일은 있지만 참조한 심볼이 사라졌거나, 파일이 더 이상 파싱되지 않음(`SyntaxError`) |

- 위 세 경우 모두 `symbol_diff.py` 가 `MISSING`(rc=2) 을 반환해 동일하게 `⚠ 삭제됨` 으로 표시된다.
  파일을 열어봐도 멀쩡해 보인다면 파일 삭제가 아니라 심볼 자체가 지워졌는지부터 의심한다.
- 메모리가 상한(`CC_MEMORY_MAX`, 기본 **200**건)을 넘으면 stale 검사를 통째로 건너뛰고
  "정리 필요" 메시지만 띄운다. 항목이 늘어나면 오래된/중복된 메모리를 먼저 정리한다.
- 상한 밑이라도 검사에는 시간 예산(`CC_MEMORY_BUDGET_SEC`, 기본 **2**초)이 있다.
  `Source`가 있는 항목마다 `symbol_diff.py`가 `git show`를 두 번 포크하므로, 항목이 늘어나면
  전체 검사 시간도 늘어난다 — 예산을 넘기면 그 순간부터 나머지 항목은 검사하지 않고
  건너뛴다. **건너뛴 항목은 이전에 붙어 있던 `⚠`/`⚠ 삭제됨` 표시를 그대로 유지한다** —
  검사를 안 했다고 경고를 지우지도, 새로 붙이지도 않는다. 이때 결과 메시지는 "부분 검사"이며
  건너뛴 건수를 함께 알려준다(상한 초과로 통째로 건너뛴 "정리 필요" 메시지와는 다른 메시지다).
- 파일 단위 폴백(파일이 HEAD 에 있는지, 기준 커밋 이후 그 경로에 커밋이 있는지만 검사)은
  세 경우에 쓰인다: `symbol_diff.py` 자체가 없을 때, `Source` 에 `#심볼` 이 없을 때,
  경로가 `.py` 가 아닐 때. 이 중 `symbol_diff.py` 가 없는 경우만 그 사실을 결과 메시지에 덧붙인다 —
  나머지 둘은 항목별로 조용히 파일 단위 검사로 넘어간다.
- `Source` 줄 자체가 없거나 거기서 기준 커밋을 뽑아낼 수 없는 항목은 애초에 stale
  검사 대상이 아니다 — 표시가 안 붙는다고 "검사해서 이상 없음"은 아니다. 이런 항목이
  하나라도 있으면 결과 메시지에 "근거 없음 N건 — stale 검사 대상 아님"이 따로 붙는다
  (재확인 필요/정리 필요/부분 검사 메시지와는 구분되는, 별도로 조합 가능한 문구다).

## `--check`

`scripts/memory-check.sh` 를 수동 실행한다. SessionStart 훅과 같은 판정을 즉시 돌린다.

```bash
bash ~/claude-skills/note/scripts/memory-check.sh
```

스크립트는 stdin(훅이 넘기는 JSON)을 의도적으로 읽지 않는다 — 인자도 입력도 없이 그대로 실행하면 된다.

## `--verify <name>`

`⚠` 가 붙은 항목을 재확인한 뒤 해제한다. **세 가지를 함께 갱신한다.**
하나라도 빠지면 다음 세션에 `⚠` 가 그대로 다시 붙는다.

1. `Source` 의 커밋 해시를 현재 HEAD 로 갱신 (비교 기준선 이동)
2. `Verified` 날짜를 오늘로 갱신
3. `MEMORY.md` 해당 줄의 `⚠` 제거

**내용이 실제로 바뀌었으면 `--verify` 가 아니라 `/note` 로 갱신한다.**
`--verify` 는 "확인해보니 여전히 사실이더라" 일 때만 쓴다.

## 관련 훅

| 훅 | 스크립트 | 역할 |
|---|---|---|
| `SessionStart` | `scripts/memory-check.sh` | 근거가 바뀐 메모리에 `⚠` |
| `UserPromptSubmit` | `scripts/stamp-start.sh` | 턴/세션 시작 시각 기록 |
| `Stop` | `scripts/notify-stop.sh` | 3분 이상 걸린 턴만 Slack |
| `SessionEnd` | `scripts/notify-session.sh` | 세션 요약 + note 누락 경고 + 세션 상태 파일(`*.turn`, `*.session`) 정리 |

`~/claude-skills/setup.sh` 는 스킬 디렉터리를 `~/.claude/skills/` 에 symlink 하는 것과,
메모리 저장소 생성 + 프로젝트별 memory symlink 연결(위 "저장 위치" 참고)까지 한다.
위 네 훅을 `~/.claude/settings.json` 에 등록하는 것은 setup.sh 가 하지 않는, 최초 1회 수동 설정이다.
