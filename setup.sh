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
# ─────────────────────────────────────────────

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SKILLS_DIR="$HOME/.claude/skills"

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
