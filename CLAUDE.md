# Claude Code Skills Repo

이 repo는 Claude Code 개인 스킬을 서버 간 동기화하기 위한 저장소입니다.

## 초기 세팅 자동 확인

사용자가 이 repo에서 작업을 시작하거나, 스킬이 동작하지 않는다고 할 때 다음을 확인하세요:

### 1. 스킬 symlink 확인

```bash
ls -la ~/.claude/skills/story-to-spec
ls -la ~/.claude/skills/add-task
ls -la ~/.claude/skills/update-ticket
ls -la ~/.claude/skills/implement
ls -la ~/.claude/skills/spec-diff
ls -la ~/.claude/skills/scrum
ls -la ~/.claude/skills/note
```

symlink이 없거나 깨져 있으면:
```bash
~/claude-skills/setup.sh
```

### 2. 필수 환경변수

| 변수 | 용도 | 확인 방법 |
|------|------|----------|
| `JIRA_EMAIL` | Jira API 인증 | `echo $JIRA_EMAIL` |
| `JIRA_API_TOKEN` | Jira API 인증 | `echo $JIRA_API_TOKEN` — 빈 값이면 [여기서 생성](https://id.atlassian.com/manage-profile/security/api-tokens) |

없으면 `~/.bashrc` 또는 `~/.zshrc`에 추가:
```bash
export JIRA_EMAIL="user@nota.ai"
export JIRA_API_TOKEN="your-token"
```

### 3. gh CLI

PR 자동 생성(`/implement`)에 필요합니다.

```bash
gh --version        # 설치 확인
gh auth status      # 인증 확인
```

미설치 시:
```bash
# Ubuntu/Debian
sudo apt install gh

# macOS
brew install gh
```

인증:
```bash
gh auth login
```

### 4. git config

```bash
git config user.name
git config user.email
```

### 5. 한 번에 전체 확인

```bash
~/claude-skills/setup.sh
```

이 스크립트가 위 항목을 모두 검증하고 결과를 보여줍니다.

## 스킬 파이프라인

```
/story-to-spec NPP02-XXXX
  │  Jira 스토리 + 원천 소스(Confluence/spec MD) 분석 → 코드 탐색
  │  → 요구사항 층위 대화 → 상세 티켓 일괄 생성
  ▼
/add-task [NPP02-XXXX] "설명 또는 문서"   (선택 — 추가 작업 발생 시)
  │  구두·문서 요청 → 버그 fix/검증/추가 Task 단건 생성
  │  스토리 있으면 동일 규칙으로 링크, 없으면 standalone
  ▼
/update-ticket NPP02-YYYY "보강 내용"   (선택 — 기존 티켓 수정 시)
  │  기존 티켓 읽기 → 추가 맥락 수집 → gh(PR/문서/코드) ground-truth 검증
  │  → 충돌·공백 표면화 → 기존 구조 유지하며 description 전체 교체
  ▼
/implement NPP02-YYYY
  │  티켓 읽기 → 브랜치 생성 → CLAUDE.md 주입 → Agent 디스패치
  │  (백그라운드: 구현 → 테스트 → 커밋 → push → PR)
  ▼
/review NPP02-YYYY
     코드 리뷰 → 머지 판단
```

파이프라인 밖 (읽기 전용):

```
/scrum [NPP02]
   내 티켓 상태 스냅샷 → 데일리 스크럼 공유 문안 4섹션
   검토 중(10094)=처리한 내용 / 진행 중(3)=오늘 할일 / Blocked(10032)=BLOCKER
   + 티켓 코멘트에서 협조·논의 항목 추론 → 슬랙 복붙용 불릿 출력
   ⚠️ Jira에 쓰지 않는다. 상태 관리는 사용자 몫.

/spec-diff NPP02-XXXX [--docs <경로>] [--deep]
   기획 문서(np-product-docs) ↔ 머지된 PR 양방향 대조
   스토리 → 하위 Task → PR 수집(귀속 판정으로 오탐 제거) → 문서 섹션과 대조
   ❌미구현 / ⚠️다르게 구현 / ➕문서에 없음 / 🕓의도된 미구현(후속 EXT·WIP)
   ⚠️ Jira·문서에 쓰지 않는다. 후속 명령 문안만 제안한다.
   ⚠️ 문서가 낡은 건지 구현이 틀린 건지는 단정하지 않는다 (판단 주체가 다름).
```

## 공유 구조 참조 (중요)

4개 스킬이 공유하는 np-enterprise 구조 지식은 **한 곳에만** 있습니다:

```
story-to-spec/references/np-enterprise-structure.md
```

담긴 내용: 패키지 지도(client/backend/engine/common + 레거시 sdk), 데이터 흐름,
키워드→경로 라우팅, 패키지 귀속 판정 트리, 패키지별 규율(core-free 등),
티켓 분할 규칙, `Module:` 필드 허용값, `gh` 확인 명령.

**np-enterprise 구조가 또 바뀌면 이 파일만 수정하세요.** 각 SKILL.md에는 4줄 요약과
참조 링크만 있습니다. (예외: `Module:` 허용값 문자열은 4개 SKILL.md에도 박혀 있으니
바뀌면 함께 갱신 — `grep -rn "Client | Backend | Engine"`)

현재 구조 요약:

```
np-client (client/src/np_client/) ──HTTP──▶ backend (backend/src/pynp/)
   thin CLI, core-free                        API·DB·오케스트레이션
                                                   │ event
np-common (common/src/np_common/)                  ▼
   이벤트·DTO 계약 공유              np-engine (engine/src/np_engine/)
                                       compute, core 허용, 이벤트 소비

[legacy] sdk/src/ — 이관 원본. strangler 방식으로 아직 살아있음 (읽기 전용)
```

## 스킬 수정 시

1. `~/claude-skills/` 에서 SKILL.md 수정
2. symlink이므로 수정 즉시 반영 (재설치 불필요)
3. `git add -A && git commit -m "..." && git push`
4. 다른 서버에서 `cd ~/claude-skills && git pull`
