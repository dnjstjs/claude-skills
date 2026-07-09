# Claude Code Skills Repo

이 repo는 Claude Code 개인 스킬을 서버 간 동기화하기 위한 저장소입니다.

## 초기 세팅 자동 확인

사용자가 이 repo에서 작업을 시작하거나, 스킬이 동작하지 않는다고 할 때 다음을 확인하세요:

### 1. 스킬 symlink 확인

```bash
ls -la ~/.claude/skills/story-to-spec
ls -la ~/.claude/skills/add-task
ls -la ~/.claude/skills/implement
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
/implement NPP02-YYYY
  │  티켓 읽기 → 브랜치 생성 → CLAUDE.md 주입 → Agent 디스패치
  │  (백그라운드: 구현 → 테스트 → 커밋 → push → PR)
  ▼
/review NPP02-YYYY
     코드 리뷰 → 머지 판단
```

## 스킬 수정 시

1. `~/claude-skills/` 에서 SKILL.md 수정
2. symlink이므로 수정 즉시 반영 (재설치 불필요)
3. `git add -A && git commit -m "..." && git push`
4. 다른 서버에서 `cd ~/claude-skills && git pull`
