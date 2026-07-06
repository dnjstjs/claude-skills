# Claude Code Skills

Claude Code 개인 스킬 관리 repo. 서버 간 동기화용.

## Quick Start

```bash
# 1. clone
gh repo clone dnjstjs/claude-skills ~/claude-skills

# 2. 설치 (symlink + 환경 검증)
~/claude-skills/setup.sh
```

## 스킬 목록

| 스킬 | 설명 | 사용법 |
|------|------|--------|
| `story-to-spec` | Jira 스토리 → 코드 분석 → 구현 수준 상세 티켓 생성 | `/story-to-spec NPP02-6517` |
| `implement` | 티켓 → 브랜치 → 백그라운드 Agent 구현 → PR 생성 | `/implement NPP02-6559` |

## 업데이트

```bash
cd ~/claude-skills && git pull
# symlink이므로 즉시 반영
```

## 새 스킬 추가

```bash
mkdir ~/claude-skills/my-skill
# SKILL.md 작성
~/claude-skills/setup.sh   # symlink 자동 갱신
git add -A && git commit -m "feat: my-skill 추가" && git push
```
