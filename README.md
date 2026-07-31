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
| `story-to-spec` | Jira 스토리 + 원천 소스 → 코드 분석 → 요구사항 대화 → 상세 티켓 일괄 생성 | `/story-to-spec NPP02-6517` |
| `add-task` | 구두·문서 요청 → 버그 fix/검증/추가 Task 단건 생성 (동일 링크 규칙) | `/add-task NPP02-6517 "빈 입력 크래시 fix"` |
| `implement` | 티켓 → 브랜치 → 백그라운드 Agent 구현 → PR 생성 | `/implement NPP02-6559` |
| `note` | 세션 간 사라지는 도메인 판정을 근거와 함께 기록. 근거가 바뀌면 ⚠ 표시 | `/note "presigned URL은 백엔드가 발급"` |

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
