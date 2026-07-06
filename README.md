# Claude Code Skills

Claude Code 개인 스킬 관리 repo. 서버 간 동기화용.

## 설치

```bash
# 1. clone
git clone git@github.com:nota-github/claude-skills.git ~/claude-skills

# 2. symlink (각 스킬을 ~/.claude/skills/에 연결)
mkdir -p ~/.claude/skills
for skill in ~/claude-skills/*/; do
  name=$(basename "$skill")
  [ "$name" = ".git" ] && continue
  ln -sfn "$skill" ~/.claude/skills/"$name"
done
```

## 업데이트

```bash
cd ~/claude-skills && git pull
# symlink이므로 즉시 반영
```

## 스킬 목록

| 스킬 | 설명 |
|------|------|
| `story-to-spec` | Jira 스토리 → 코드 분석 → 구현 수준 상세 티켓 생성 |
| `implement` | 티켓 → 브랜치 → 백그라운드 Agent 구현 → PR 생성 |
