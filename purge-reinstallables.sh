#!/usr/bin/env bash
# purge-reinstallables.sh
#
# Safely remove reinstallable dependency/build/cache directories inside a workspace.
# Default is DRY RUN (prints what it would remove). Use --apply to actually delete.
#
# Shows estimated total space reclaimable (dry run) and actual freed (apply),
# computed by summing `du -sk` for matched directories.
#
# Usage:
#   ./purge-reinstallables.sh --help
#   ./purge-reinstallables.sh --root "$HOME/code"
#   ./purge-reinstallables.sh --root "$HOME/code" --apply
#   ./purge-reinstallables.sh --root "$HOME/code" --apply --trash

set -euo pipefail

ROOT=""
APPLY=0
USE_TRASH=0

die() { echo "Error: $*" >&2; exit 1; }

print_help() {
  cat <<'EOF'
purge-reinstallables.sh

Safely remove reinstallable dependency/build/cache directories inside a workspace.
Default is DRY RUN (prints what it would remove). Use --apply to actually delete.

Targets (directories only):
  JS/TS:  node_modules, .next, dist, build, out, coverage, .turbo, .parcel-cache, .vite, .cache
  Python: .venv, venv, env, __pycache__, .pytest_cache, .mypy_cache, .ruff_cache, .tox, .uv
  Ruby:   vendor/bundle, vendor/cache, .bundle/cache
  Rust:   target

Safety:
  - Only deletes directories matching the patterns above
  - Skips .git directories entirely
  - Refuses unsafe roots (/, /Users, $HOME, etc.)
  - Requires typing 'delete' before applying

Usage:
  ./purge-reinstallables.sh --root PATH
  ./purge-reinstallables.sh --root PATH --apply
  ./purge-reinstallables.sh --root PATH --apply --trash

Options:
  --root PATH   Workspace root to scan (required unless --help)
  --apply       Perform deletions (otherwise dry run)
  --trash       Move to Trash using `trash` command (brew install trash)
  -h, --help    Show this help

Examples:
  ./purge-reinstallables.sh --root "$HOME/code"
  ./purge-reinstallables.sh --root "$HOME/code" --apply --trash
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --root) ROOT="${2:-}"; shift 2 ;;
    --apply) APPLY=1; shift ;;
    --trash) USE_TRASH=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

[[ -n "$ROOT" ]] || die "Missing --root PATH (use --help)"
[[ -d "$ROOT" ]] || die "--root is not a directory: $ROOT"

ROOT="$(cd "$ROOT" && pwd -P)"
case "$ROOT" in
  "/"|"/System"|"/Library"|"/Applications"|"/Users"|"$HOME") die "Refusing unsafe root: $ROOT" ;;
esac

DO_DELETE() {
  local path="$1"
  if [[ "$USE_TRASH" -eq 1 ]]; then
    command -v trash >/dev/null 2>&1 || die "--trash requested but 'trash' not found (brew install trash)"
    trash -- "$path"
  else
    rm -rf -- "$path"
  fi
}

FIND=(find -P "$ROOT")

NAME_TARGETS=(
  # JS/TS
  node_modules .next dist build out coverage .turbo .parcel-cache .vite .cache
  # Python
  .venv venv env __pycache__ .pytest_cache .mypy_cache .ruff_cache .tox .uv
  # Rust
  target
)

PATH_SUFFIX_TARGETS=(
  "/vendor/bundle"
  "/vendor/cache"
  "/.bundle/cache"
)

build_find_expr() {
  local expr=()
  expr+=( \( -type d -name .git -prune \) -o )
  expr+=( \( -type d \( )

  local first=1
  for n in "${NAME_TARGETS[@]}"; do
    if [[ $first -eq 0 ]]; then expr+=( -o ); fi
    expr+=( -name "$n" )
    first=0
  done

  for sfx in "${PATH_SUFFIX_TARGETS[@]}"; do
    expr+=( -o -path "*$sfx" )
  done

  expr+=( \) \) -print0 )
  printf '%s\0' "${expr[@]}"
}

mapfile -d '' FIND_ARGS < <(build_find_expr)
mapfile -d '' MATCHES < <("${FIND[@]}" "${FIND_ARGS[@]}")

if [[ "${#MATCHES[@]}" -eq 0 ]]; then
  echo "No matching reinstallable directories found under: $ROOT"
  exit 0
fi

# Compute total KB and keep per-path KB for later reporting.
SIZES=()
TOTAL_KB=0
for p in "${MATCHES[@]}"; do
  kb=0
  if out="$(du -sk -- "$p" 2>/dev/null)"; then
    kb="${out%%[[:space:]]*}"
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  fi
  SIZES+=("${kb}"$'\t'"${p}")
  TOTAL_KB=$((TOTAL_KB + kb))
done

human_kb() {
  # Input: KB as integer. Output: human-ish string.
  python3 - "$1" <<'PY'
import sys
kb = int(sys.argv[1])
b = kb * 1024
units = ["B","KB","MB","GB","TB","PB"]
u = 0
v = float(b)
while v >= 1024.0 and u < len(units)-1:
    v /= 1024.0
    u += 1
if u == 0:
    print(f"{int(v)} {units[u]}")
elif u in (1,2):
    print(f"{v:.1f} {units[u]}")
else:
    print(f"{v:.2f} {units[u]}")
PY
}

TOTAL_HUMAN="$(human_kb "$TOTAL_KB")"

echo "Found ${#MATCHES[@]} directories under:"
echo "  $ROOT"
echo "Estimated reclaimable space: $TOTAL_HUMAN"
echo
echo "Largest candidates:"
# show top 30 by KB, descending
if [[ "${#SIZES[@]}" -gt 0 ]]; then
  while IFS=$'\t' read -r kb p; do
    printf "%10s  %s\n" "$(human_kb "$kb")" "$p"
  done < <(printf '%s\n' "${SIZES[@]}" | sort -nr -k1,1 | head -n 30)
fi
echo

if [[ "$APPLY" -eq 0 ]]; then
  echo "DRY RUN (no deletions)."
  echo "Total estimated space that would be freed: $TOTAL_HUMAN"
  echo
  echo "To delete these directories, rerun with:"
  echo "  $0 --root \"$ROOT\" --apply"
  if command -v trash >/dev/null 2>&1; then
    echo "Or to move to Trash:"
    echo "  $0 --root \"$ROOT\" --apply --trash"
  fi
  echo
  echo "Would delete:"
  for line in "${SIZES[@]}"; do
    kb="${line%%$'\t'*}"
    path="${line#*$'\t'}"
    # Print with per-item size
    printf "  %10s  %s\n" "$(human_kb "$kb")" "$path"
  done
  exit 0
fi

echo "ABOUT TO DELETE ${#MATCHES[@]} directories under:"
echo "  $ROOT"
echo "Planned space to free (estimate): $TOTAL_HUMAN"
echo
echo "Type EXACTLY: delete"
read -r CONFIRM
[[ "$CONFIRM" == "delete" ]] || die "Confirmation failed; exiting."

deleted=0
deleted_kb=0
for line in "${SIZES[@]}"; do
  kb="${line%%$'\t'*}"
  p="${line#*$'\t'}"
  [[ -d "$p" ]] || continue
  case "$(cd "$(dirname "$p")" && pwd -P)/$(basename "$p")" in
    "$ROOT"/*) ;;
    *) echo "Skipping (outside root?): $p" >&2; continue ;;
  esac
  DO_DELETE "$p"
  deleted=$((deleted+1))
  deleted_kb=$((deleted_kb + kb))
done

echo "Deleted $deleted directories."
echo "Estimated space freed: $(human_kb "$deleted_kb")"
