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

티켓 파이프라인:

| 스킬 | 설명 | 사용법 |
|------|------|--------|
| `story-to-spec` | Jira 스토리 + 원천 소스 → 코드 분석 → 요구사항 대화 → 상세 티켓 일괄 생성 | `/story-to-spec NPP02-6517` |
| `add-task` | 구두·문서 요청 → 버그 fix/검증/추가 Task 단건 생성 (동일 링크 규칙) | `/add-task NPP02-6517 "빈 입력 크래시 fix"` |
| `update-ticket` | 기존 티켓 description 수정·보강. gh로 PR·문서·코드 ground-truth 검증 후 반영 | `/update-ticket NPP02-6929 "의존 버전 명시"` |
| `implement` | 티켓 → 브랜치 → 백그라운드 Agent 구현 → PR 생성 | `/implement NPP02-6559` |

읽기 전용 (Jira·문서에 쓰지 않음):

| 스킬 | 설명 | 사용법 |
|------|------|--------|
| `spec-diff` | 기획 문서(np-product-docs) 대비 머지된 PR을 양방향 대조 → 미구현·다르게 구현·문서에 없는 구현 분류 | `/spec-diff NPP02-6517` |
| `scrum` | 내 티켓 상태 스냅샷 → 데일리 스크럼 공유 문안 4섹션 (슬랙 복붙용) | `/scrum NPP02` |
| `note` | 세션 간 사라지는 도메인 판정을 근거와 함께 기록. 근거가 바뀌면 ⚠ 표시 | `/note "presigned URL은 백엔드가 발급"` |

인프라 디버깅:

| 스킬 | 설명 | 사용법 |
|------|------|--------|
| `np-eks-debug` | EKS(dev/stg) 인프라·배포 상태 조사 — 토폴로지, 배포버전 확인, curl 직접 호출, 진단 플레이북 | `/np-eks-debug dev` |

> np-enterprise 구조 지식(패키지 지도·경로 라우팅·`Module:` 허용값)은
> `story-to-spec/references/np-enterprise-structure.md` **한 곳에만** 있습니다.
> 구조가 바뀌면 그 파일을 고치세요.

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
