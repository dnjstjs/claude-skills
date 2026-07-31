#!/usr/bin/env bash
set -euo pipefail

# ─────────────────────────────────────────────
# Claude Code Skills — Setup & Health Check
# ─────────────────────────────────────────────
# 사용법: ~/claude-skills/setup.sh
#
# 수행 내용:
#   1. ~/.claude/skills/ 디렉토리 생성
#   2. 각 스킬 디렉토리를 symlink 연결
#   3. 필수 환경 (gh CLI, 환경변수) 검증
#   4. 메모리 저장소 생성 + 프로젝트별 memory symlink 연결
#
# 옵션:
#   --memory-only   4단계만 수행 (테스트용)
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"

MEMORY_STORE="${CC_MEMORY_STORE:-$HOME/claude-memory/np-enterprise}"
MEMORY_PROJECT_ROOT="${CC_MEMORY_PROJECT_ROOT:-/ssd1/home/wonseon.song/test2/np-enterprise}"
MEMORY_SUBDIRS=("" "/sdk" "/qa" "/backend" "/engine" "/client" "/common")

# 메모리 실체는 한 곳에 두고, 프로젝트별 memory 디렉터리를 전부 그곳으로 잇는다.
# 작업 경로가 sdk/qa/backend 로 갈려도 같은 사실이 로드되게 하기 위해서다.
link_memory_dirs() {
  mkdir -p "$MEMORY_STORE"
  echo "[4/4] 메모리 저장소: $MEMORY_STORE"
  local linked=0 sub p enc target
  for sub in "${MEMORY_SUBDIRS[@]}"; do
    p="$MEMORY_PROJECT_ROOT$sub"
    [ -d "$p" ] || continue
    # Claude Code는 프로젝트 디렉토리 이름을 만들 때 '/' 뿐 아니라 '.' 등
    # 영숫자가 아닌 모든 문자를 '-'로 치환한다 (예: wonseon.song → wonseon-song).
    # '/'만 치환하면 사용자명에 '.'이 있는 실제 환경에서 symlink이 엉뚱한
    # (Claude Code가 절대 읽지 않는) 디렉토리에 생겨 기능이 조용히 깨진다.
    # realpath의 출력 개행을 먼저 $()로 제거한 뒤 tr에 넘겨야 한다 — 개행째로
    # tr -c에 넣으면 개행이 '-'로 바뀌어버려 끝에 여분의 '-'가 남는다.
    enc=$(printf '%s' "$(realpath "$p")" | tr -c 'A-Za-z0-9' '-')
    target="$HOME/.claude/projects/$enc/memory"
    # 권한 문제 등으로 한 프로젝트가 실패해도 set -e 때문에 전체 단계가
    # 중단되지 않도록, 위험한 명령은 모두 조건문/|| 안에서만 실행한다.
    if ! mkdir -p "$(dirname "$target")" 2>/dev/null; then
      echo "  ⚠️  $(basename "$p") (프로젝트 디렉토리 생성 실패, 건너뜀)"
      continue
    fi
    if [ -L "$target" ]; then
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 갱신 실패)"; continue; }
    elif [ -d "$target" ]; then
      if ! mv "$target" "$target.bak.$(date +%s)" 2>/dev/null; then
        echo "  ⚠️  $(basename "$p") (기존 디렉토리 백업 실패, 건너뜀)"
        continue
      fi
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 생성 실패)"; continue; }
      echo "  🔄 $(basename "$p") (dir → symlink, old backed up)"
      linked=$((linked + 1))
      continue
    else
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 생성 실패)"; continue; }
    fi
    echo "  ✅ $(basename "$p")"
    linked=$((linked + 1))
  done
  echo "  $linked memory dirs linked"
}

if [ "${1:-}" = "--memory-only" ]; then
  link_memory_dirs
  return 0 2>/dev/null || exit 0
fi

echo "═══════════════════════════════════════════"
echo "  Claude Code Skills — Setup"
echo "═══════════════════════════════════════════"
echo ""

# ── Step 1: skills 디렉토리 ──
mkdir -p "$SKILLS_DIR"
echo "[1/3] ~/.claude/skills/ ✅"

# ── Step 2: symlink 생성 ──
count=0
for skill in "$SCRIPT_DIR"/*/; do
  name=$(basename "$skill")
  # .git, __pycache__ 등 제외
  [[ "$name" == .* ]] && continue
  [[ "$name" == __* ]] && continue
  # SKILL.md 없는 디렉토리는 스킬이 아님 (docs/ 등)
  [[ -f "$skill/SKILL.md" ]] || continue

  if [ -L "$SKILLS_DIR/$name" ]; then
    # 이미 symlink 존재 — 경로 확인
    current=$(readlink "$SKILLS_DIR/$name")
    if [ "$current" = "$skill" ] || [ "$current" = "${skill%/}" ]; then
      echo "  ✅ $name (already linked)"
    else
      ln -sfn "$skill" "$SKILLS_DIR/$name"
      echo "  🔄 $name (re-linked)"
    fi
  elif [ -d "$SKILLS_DIR/$name" ]; then
    # 일반 디렉토리 존재 — 백업 후 symlink
    mv "$SKILLS_DIR/$name" "$SKILLS_DIR/${name}.bak.$(date +%s)"
    ln -sfn "$skill" "$SKILLS_DIR/$name"
    echo "  🔄 $name (dir → symlink, old backed up)"
  else
    ln -sfn "$skill" "$SKILLS_DIR/$name"
    echo "  ✅ $name (linked)"
  fi
  count=$((count + 1))
done
echo "[2/3] $count skills linked ✅"
echo ""

# ── Step 3: 환경 검증 ──
echo "[3/3] Environment check:"
errors=0

# gh CLI
if command -v gh &>/dev/null; then
  echo "  ✅ gh CLI: $(gh --version | head -1)"
  # gh 인증 상태
  if gh auth status &>/dev/null 2>&1; then
    echo "  ✅ gh auth: authenticated"
  else
    echo "  ❌ gh auth: not authenticated"
    echo "     → Run: gh auth login"
    errors=$((errors + 1))
  fi
else
  echo "  ❌ gh CLI: not installed"
  echo "     → Run: sudo apt install gh  (or brew install gh)"
  errors=$((errors + 1))
fi

# JIRA 환경변수
if [ -n "${JIRA_EMAIL:-}" ]; then
  echo "  ✅ JIRA_EMAIL: set"
else
  echo "  ❌ JIRA_EMAIL: not set"
  echo "     → Add to ~/.bashrc: export JIRA_EMAIL=\"your-email@nota.ai\""
  errors=$((errors + 1))
fi

if [ -n "${JIRA_API_TOKEN:-}" ]; then
  echo "  ✅ JIRA_API_TOKEN: set"
else
  echo "  ❌ JIRA_API_TOKEN: not set"
  echo "     → Create at: https://id.atlassian.com/manage-profile/security/api-tokens"
  echo "     → Add to ~/.bashrc: export JIRA_API_TOKEN=\"your-token\""
  errors=$((errors + 1))
fi

# git config
if git config user.name &>/dev/null && git config user.email &>/dev/null; then
  echo "  ✅ git config: $(git config user.name) <$(git config user.email)>"
else
  echo "  ⚠️  git config: user.name or user.email not set"
  echo "     → Run: git config --global user.name \"Your Name\""
  echo "     → Run: git config --global user.email \"you@nota.ai\""
  errors=$((errors + 1))
fi

echo ""
echo "═══════════════════════════════════════════"
if [ $errors -eq 0 ]; then
  echo "  All checks passed ✅"
  echo "  Skills are ready to use."
else
  echo "  $errors issue(s) found — see above."
  echo "  Skills are linked but some features"
  echo "  may not work until issues are fixed."
fi
echo "═══════════════════════════════════════════"

echo ""
link_memory_dirs
