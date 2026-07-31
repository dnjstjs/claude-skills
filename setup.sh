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
  local -a displaced_backups=()   # 실제 내용이 백업된 경로들 — 마지막에 한 번 더 강조 출력

  # Finding 2 수정: 인덱스 병합 시 memory-check.sh 가 ⚠ 로 표시해 둔 항목도
  # 인식해야 한다 — 그렇지 않으면 그 파일들은 디스크에는 남지만 유일하게
  # 자동 로드되는 인덱스에서는 빠져 고아가 된다. 정규식을 여기 새로 쓰면
  # 두 곳이 각자 따로 드리프트할 수 있으므로, memory-check.sh:35 의
  # ENTRY_RE 값을 그대로 읽어와 재사용한다 (제3의 변형을 만들지 않는다).
  local entry_re
  entry_re=$(sed -n "s/^ENTRY_RE='\(.*\)'\$/\1/p" "$SCRIPT_DIR/note/scripts/memory-check.sh" 2>/dev/null)
  [ -n "$entry_re" ] || entry_re='^- (⚠ 삭제됨 |⚠ )?\[[^]]*\]\([^)]+\.md\)'

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
      # 실제 메모리 파일이 들어 있는 디렉터리다. 예전에는 이걸 통째로 .bak 로
      # 치우고 빈 저장소를 symlink 로 걸었다 — 그 결과 메모리 51개가 조용히
      # displaced 되어 다시는 로드되지 않는 사고가 실제로 났다. 이제는 displace
      # 대신 adopt 한다: 저장소에 아직 없는 파일은 저장소로 흡수하고, 이름은
      # 같은데 내용이 다른 파일만 충돌로 보고 .bak 에 남긴다.
      #
      # 이 함수의 불변식: 저장소에 있다고 검증되지 않은 내용은 절대 지우지
      # 않는다. 그래서 아래에서는 target 아래 "모든" 항목(일반 파일, dotfile,
      # 하위 디렉터리, 그 외 노드)을 하나도 빠짐없이 계산에 넣는다 — 예전
      # 버그는 `"$target"/*` 글롭이 dotfile을 아예 보지 못하고, `[ -f "$f" ]`
      # 가드가 하위 디렉터리를 통째로 건너뛰어, 그 항목들이 세어지지도 않은
      # 채 마지막 `rm -rf`에 그냥 같이 쓸려나갔던 것이다.
      #
      # 하위 디렉터리 설계 선택: 재귀적으로 들어가 흡수하지 않는다. 통째로
      # .bak 에 보존한다. 재귀하면 중첩된 MEMORY.md 병합, 임의 깊이, 심볼릭
      # 링크 루프, 권한 오류까지 이 함수 안에서 다시 다 처리해야 해서 실수할
      # 표면이 크게 늘어난다. 통째 보존은 구현이 단순하고, 불변식(무손실)을
      # 기계적으로 만족시키며, 사람이 나중에 직접 살펴보게 한다 — 이미 이름
      # 충돌 파일과 "파일이 이미 있던 자리" 케이스에도 같은 전략을 쓰고 있어
      # 일관적이다. 자동 병합을 포기하는 대신 안전을 산다.
      local bak="$target.bak.$(date +%s)"
      local adopted=0 conflicted=0 nonfile_preserved=0 unadopted=0 f base
      local -a conflict_names=() nonfile_names=() unadopted_names=()

      while IFS= read -r -d '' f; do
        base=$(basename "$f")
        [ "$base" = "MEMORY.md" ] && continue   # 인덱스는 아래에서 별도로 병합한다

        if [ -f "$f" ] && [ ! -L "$f" ]; then
          # 일반 파일(dotfile 포함) — 저장소로 흡수를 시도한다.
          if [ ! -e "$MEMORY_STORE/$base" ]; then
            if cp -p "$f" "$MEMORY_STORE/$base" 2>/dev/null && cmp -s "$f" "$MEMORY_STORE/$base" 2>/dev/null; then
              adopted=$((adopted + 1))
              continue
            fi
            # 저장소 쓰기 실패(용량/권한 등) — 절대 그냥 버리지 않고 .bak 로 보존한다.
            rm -f "$MEMORY_STORE/$base" 2>/dev/null   # 반쯤 쓰인 파일 정리
            if mkdir -p "$bak" 2>/dev/null && mv "$f" "$bak/$base" 2>/dev/null; then
              conflicted=$((conflicted + 1))
              conflict_names+=("$base (저장소 쓰기 실패 — 백업 보존)")
            else
              unadopted=$((unadopted + 1))
              unadopted_names+=("$base")
            fi
          elif ! cmp -s "$f" "$MEMORY_STORE/$base" 2>/dev/null; then
            # 이름은 같은데 내용이 다르다 — 어느 쪽이 최신인지 알 수 없으므로
            # 저장소 쪽을 덮어쓰지 않고, 원본을 백업으로 옮겨 사람이 보게 한다.
            if mkdir -p "$bak" 2>/dev/null && mv "$f" "$bak/$base" 2>/dev/null; then
              conflicted=$((conflicted + 1))
              conflict_names+=("$base")
            else
              unadopted=$((unadopted + 1))
              unadopted_names+=("$base")
            fi
          fi
          # 내용이 완전히 같으면 아무 것도 하지 않는다 — 저장소에 이미 있다.
        else
          # 하위 디렉터리(위 설계 선택에 따라 재귀하지 않음), 심볼릭 링크,
          # 기타 특수 노드 — 전부 통째로 .bak 에 보존한다.
          local label="$base"
          [ -d "$f" ] && [ ! -L "$f" ] && label="$base/"
          if mkdir -p "$bak" 2>/dev/null && mv "$f" "$bak/$base" 2>/dev/null; then
            nonfile_preserved=$((nonfile_preserved + 1))
            nonfile_names+=("$label")
          else
            unadopted=$((unadopted + 1))
            unadopted_names+=("$label")
          fi
        fi
      done < <(find "$target" -mindepth 1 -maxdepth 1 -print0 2>/dev/null)

      # MEMORY.md 인덱스는 통째로 덮지 않고 병합한다. 저장소 쪽 인덱스를
      # 클로버하면 이미 저장소에만 있던 항목이 사라진다 — 들어오는 쪽의
      # 항목 줄 중 저장소에 아직 없는 것만 이어붙인다. `- [...]` 뿐 아니라
      # memory-check.sh 가 붙이는 `- ⚠ [...]`, `- ⚠ 삭제됨 [...]` 도 항목으로
      # 인식해야 한다(Finding 2) — 안 그러면 그 파일들은 흡수되어도 인덱스에는
      # 실리지 않아 다시는 자동 로드되지 않는다.
      local index_lost=0
      if [ -f "$target/MEMORY.md" ]; then
        if [ -f "$MEMORY_STORE/MEMORY.md" ]; then
          while IFS= read -r idxline || [ -n "$idxline" ]; do
            [[ "$idxline" =~ $entry_re ]] || continue
            # Finding 3: 같은 파일을 가리키는 줄이 설명 문구만 다르게 두 번
            # 들어오면 중복 항목이 생기고 CC_MEMORY_MAX 카운트도 부풀려진다.
            # 전체 줄이 아니라 링크 대상 `(file.md)` 기준으로 중복을 걸러
            # 먼저 들어온 것만 남긴다.
            local file_target
            file_target=$(printf '%s' "$idxline" | sed -nE 's/.*\(([^)]+\.md)\).*/\1/p')
            # 뒤의 `|| true`: set -e 아래에서 이 append 가 실패(저장소 쓰기 불가
            # 등)해도 스크립트 전체가 죽지 않게 한다 — 실패 여부는 아래
            # index_lost 검증 루프가 실제 저장소 내용을 다시 읽어 판단한다.
            if [ -n "$file_target" ]; then
              case "$(cat "$MEMORY_STORE/MEMORY.md" 2>/dev/null)" in
                *"($file_target)"*) ;;  # 이미 있음 — 첫 등장을 유지, 건너뜀
                *) printf '%s\n' "$idxline" >> "$MEMORY_STORE/MEMORY.md" 2>/dev/null || true ;;
              esac
            else
              grep -qxF -- "$idxline" "$MEMORY_STORE/MEMORY.md" 2>/dev/null || \
                printf '%s\n' "$idxline" >> "$MEMORY_STORE/MEMORY.md" 2>/dev/null || true
            fi
          done < "$target/MEMORY.md"
        else
          cp -p "$target/MEMORY.md" "$MEMORY_STORE/MEMORY.md" 2>/dev/null || true
        fi

        # 검증: 들어오는 인덱스의 항목 줄이 전부(파일 링크 기준) 저장소
        # 인덱스에 실제로 반영됐는지 확인한다. 위 append 가 쓰기 실패 등으로
        # 조용히 안 먹었을 수 있으므로, 확인 없이 원본을 지우면 그 항목들은
        # 디스크(파일)엔 남아도 유일한 자동 로드 경로인 인덱스에서 고아가 된다.
        while IFS= read -r idxline || [ -n "$idxline" ]; do
          [[ "$idxline" =~ $entry_re ]] || continue
          local ft
          ft=$(printf '%s' "$idxline" | sed -nE 's/.*\(([^)]+\.md)\).*/\1/p')
          [ -n "$ft" ] || continue
          case "$(cat "$MEMORY_STORE/MEMORY.md" 2>/dev/null)" in
            *"($ft)"*) ;;
            *) index_lost=1 ;;
          esac
        done < "$target/MEMORY.md"

        if [ "$index_lost" -eq 1 ]; then
          if mkdir -p "$bak" 2>/dev/null && cp -p "$target/MEMORY.md" "$bak/MEMORY.md" 2>/dev/null; then
            conflicted=$((conflicted + 1))
            conflict_names+=("MEMORY.md (일부 항목 병합 실패 — 원본 보존)")
          else
            unadopted=$((unadopted + 1))
            unadopted_names+=("MEMORY.md")
          fi
        fi
      fi

      if [ "$unadopted" -gt 0 ]; then
        # 저장소로도 .bak 으로도 옮기지 못한 항목이 있다 — 이 경우 원본을
        # 절대 지우지 않는다(rm -rf 하지 않음). symlink 도 만들지 않는다.
        # "성공" 문구는 절대 찍지 않고, 무엇이 어디 남았는지만 말한다.
        echo "  ⚠️  $(basename "$p") (${unadopted}개 항목을 저장소로도 백업으로도 옮기지 못함 — 원본 보존, symlink 미생성)"
        echo "     ⚠️  → 대상: ${unadopted_names[*]}"
        echo "     ⚠️  → 원본 경로 그대로 둠: $target"
        continue
      fi

      if ! rm -rf "$target" 2>/dev/null; then
        echo "  ⚠️  $(basename "$p") (흡수 후 원본 디렉터리 정리 실패, 건너뜀 — symlink 미생성)"
        continue
      fi
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 생성 실패)"; continue; }

      local left=$((conflicted + nonfile_preserved))
      if [ "$left" -gt 0 ]; then
        # 뭔가 하나라도 .bak 에 남았으면 무조건 성공 문구를 찍지 않는다 —
        # 남은 것과 위치를 함께 말한다.
        echo "  📥 $(basename "$p") (dir → symlink, 일부만 흡수됨 — ${left}개 항목은 흡수되지 않고 .bak 에 보존: $bak)"
      else
        echo "  📥 $(basename "$p") (dir → symlink, 내용은 저장소로 흡수됨)"
      fi
      [ "$adopted" -gt 0 ] && echo "     ✅ 새 파일 ${adopted}개를 저장소로 흡수"
      if [ "$conflicted" -gt 0 ]; then
        echo "     ⚠️  저장소로 흡수하지 못하고 .bak 에 보존된 파일 ${conflicted}개: $bak"
        echo "     ⚠️  → 대상: ${conflict_names[*]}"
        displaced_backups+=("$(basename "$p")|$bak|$conflicted")
      fi
      if [ "$nonfile_preserved" -gt 0 ]; then
        echo "     ⚠️  하위 디렉터리/기타 항목 ${nonfile_preserved}개는 흡수하지 않고 통째로 .bak 에 보존: $bak"
        echo "     ⚠️  → 대상: ${nonfile_names[*]}"
        displaced_backups+=("$(basename "$p") (하위 디렉터리 등)|$bak|$nonfile_preserved")
      fi
      linked=$((linked + 1))
      continue
    elif [ -e "$target" ]; then
      # 심볼릭 링크도, 디렉터리도 아닌 무언가(파일 등)가 이미 존재한다.
      # ln -sfn 은 이런 노드를 경고 없이 덮어써버리므로, 반드시 먼저 백업한다.
      local bak="$target.bak.$(date +%s)"
      if ! mv "$target" "$bak" 2>/dev/null; then
        echo "  ⚠️  $(basename "$p") (기존 파일 백업 실패, 건너뜀)"
        continue
      fi
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 생성 실패)"; continue; }
      echo "  🔄 $(basename "$p") (file → symlink, old backed up)"
      echo "     ⚠️  기존 파일이 옮겨졌습니다 — 새로 로드되지 않습니다!"
      echo "     ⚠️  백업 위치: $bak"
      echo "     ⚠️  → 이 내용을 $MEMORY_STORE 로 직접 병합해야 다시 로드됩니다."
      displaced_backups+=("$(basename "$p")|$bak|1")
      linked=$((linked + 1))
      continue
    else
      ln -sfn "$MEMORY_STORE" "$target" || { echo "  ⚠️  $(basename "$p") (symlink 생성 실패)"; continue; }
    fi
    echo "  ✅ $(basename "$p")"
    linked=$((linked + 1))
  done
  echo "  $linked memory dirs linked"

  if [ "${#displaced_backups[@]}" -gt 0 ]; then
    echo ""
    echo "  ╔═══════════════════════════════════════════════════════════╗"
    echo "  ║  ⚠️  일부 파일은 자동으로 병합되지 않고 백업에 남아 있습니다 ║"
    echo "  ║      (이름은 같지만 내용이 다르거나, 통째로 옮겨진 파일)     ║"
    echo "  ║      확인 후 필요하면 직접 저장소로 병합하세요.              ║"
    echo "  ╚═══════════════════════════════════════════════════════════╝"
    local entry name bak nfiles
    for entry in "${displaced_backups[@]}"; do
      name="${entry%%|*}"
      entry="${entry#*|}"
      bak="${entry%%|*}"
      nfiles="${entry#*|}"
      echo "    - $name: $nfiles개 파일 → $bak"
    done
    echo "    → 각 백업 경로의 파일을 $MEMORY_STORE 아래로 직접 병합하세요."
    echo ""
  fi
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
