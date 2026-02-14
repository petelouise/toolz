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
LIST_ALL=0

die() { echo "Error: $*" >&2; exit 1; }

setup_colors() {
  if [[ -t 1 && -z "${NO_COLOR:-}" ]] && command -v tput >/dev/null 2>&1; then
    if [[ "$(tput colors 2>/dev/null || echo 0)" -ge 8 ]]; then
      C_RESET="$(tput sgr0)"
      C_BOLD="$(tput bold)"
      C_DIM="$(tput dim)"
      C_RED="$(tput setaf 1)"
      C_GREEN="$(tput setaf 2)"
      C_YELLOW="$(tput setaf 3)"
      C_BLUE="$(tput setaf 4)"
      C_CYAN="$(tput setaf 6)"
      return
    fi
  fi
  C_RESET=""
  C_BOLD=""
  C_DIM=""
  C_RED=""
  C_GREEN=""
  C_YELLOW=""
  C_BLUE=""
  C_CYAN=""
}

info() { printf "%b%s%b\n" "${C_CYAN}" "$*" "${C_RESET}"; }
warn() { printf "%b%s%b\n" "${C_YELLOW}" "$*" "${C_RESET}"; }
ok() { printf "%b%s%b\n" "${C_GREEN}" "$*" "${C_RESET}"; }
section() { printf "%b%s%b\n" "${C_BOLD}${C_BLUE}" "$*" "${C_RESET}"; }

progress() {
  local phase="$1" current="$2" total="$3"
  if [[ "$total" -le 0 ]]; then
    return
  fi
  local pct
  pct="$(( current * 100 / total ))"
  printf "\r%b%-12s%b %6d/%-6d %3d%%" "${C_DIM}" "$phase" "${C_RESET}" "$current" "$total" "$pct" >&2
  if [[ "$current" -ge "$total" ]]; then
    printf "\n" >&2
  fi
}

target_label() {
  local p="$1"
  case "$p" in
    */vendor/bundle) printf "vendor/bundle" ;;
    */vendor/cache) printf "vendor/cache" ;;
    */.bundle/cache) printf ".bundle/cache" ;;
    *) basename "$p" ;;
  esac
}

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
  --list-all    In dry run, print every matched path (can be very long)
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
    --list-all) LIST_ALL=1; shift ;;
    -h|--help) print_help; exit 0 ;;
    *) die "Unknown arg: $1 (use --help)" ;;
  esac
done

setup_colors

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
  expr+=( \( -type d -name .git -prune \) -o \( -type d \( )

  local first=1
  for n in "${NAME_TARGETS[@]}"; do
    if [[ $first -eq 0 ]]; then expr+=( -o ); fi
    expr+=( -name "$n" )
    first=0
  done

  for sfx in "${PATH_SUFFIX_TARGETS[@]}"; do
    expr+=( -o -path "*$sfx" )
  done

  # Print and prune matches so nested targets inside a matched directory
  # do not appear as additional noisy entries.
  expr+=( \) -print0 -prune \) )
  printf '%s\0' "${expr[@]}"
}

section "Scanning for reinstallable directories"
mapfile -d '' FIND_ARGS < <(build_find_expr)
mapfile -d '' MATCHES < <("${FIND[@]}" "${FIND_ARGS[@]}")

if [[ "${#MATCHES[@]}" -eq 0 ]]; then
  ok "No matching reinstallable directories found under: $ROOT"
  exit 0
fi

# Compute total KB and keep per-path KB for later reporting.
SIZES=()
TOTAL_KB=0
TOTAL_MATCHES="${#MATCHES[@]}"
idx=0
section "Estimating reclaimable space"
for p in "${MATCHES[@]}"; do
  idx=$((idx + 1))
  kb=0
  if out="$(du -sk -- "$p" 2>/dev/null)"; then
    kb="${out%%[[:space:]]*}"
    [[ "$kb" =~ ^[0-9]+$ ]] || kb=0
  fi
  SIZES+=("${kb}"$'\t'"${p}")
  TOTAL_KB=$((TOTAL_KB + kb))
  progress "Sizing" "$idx" "$TOTAL_MATCHES"
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

section "Summary"
printf "%bFound:%b %s directories under %s\n" "${C_BOLD}" "${C_RESET}" "${#MATCHES[@]}" "$ROOT"
printf "%bEstimated reclaimable space:%b %s\n" "${C_BOLD}" "${C_RESET}" "$TOTAL_HUMAN"
echo

section "By Type"
TYPE_ROWS=()
for line in "${SIZES[@]}"; do
  kb="${line%%$'\t'*}"
  path="${line#*$'\t'}"
  TYPE_ROWS+=("$(target_label "$path")"$'\t'"$kb")
done
while IFS=$'\t' read -r kind count kb; do
  [[ -n "$kind" ]] || continue
  printf "%10s  %6s  %s\n" "$(human_kb "$kb")" "$count" "$kind"
done < <(printf '%s\n' "${TYPE_ROWS[@]}" | awk -F'\t' '{c[$1]+=1; s[$1]+=$2} END {for (k in c) printf "%s\t%d\t%d\n", k, c[k], s[k]}' | sort -t$'\t' -k3,3nr)
echo

section "Largest Candidates"
# show top 30 by KB, descending
if [[ "${#SIZES[@]}" -gt 0 ]]; then
  rank=0
  while IFS=$'\t' read -r kb p; do
    rank=$((rank + 1))
    printf "%3d. %10s  %s\n" "$rank" "$(human_kb "$kb")" "$p"
  done < <(printf '%s\n' "${SIZES[@]}" | sort -nr -k1,1 | head -n 40)
fi
echo

if [[ "$APPLY" -eq 0 ]]; then
  warn "DRY RUN (no deletions)."
  printf "Total estimated space that would be freed: %s\n" "$TOTAL_HUMAN"
  echo
  info "To delete these directories, rerun with:"
  echo "  $0 --root \"$ROOT\" --apply"
  if command -v trash >/dev/null 2>&1; then
    info "Or to move to Trash:"
    echo "  $0 --root \"$ROOT\" --apply --trash"
  fi
  if [[ "$LIST_ALL" -eq 1 ]]; then
    echo
    section "Full Candidate List"
    rank=0
    while IFS=$'\t' read -r kb p; do
      rank=$((rank + 1))
      printf "%4d. %10s  %s\n" "$rank" "$(human_kb "$kb")" "$p"
    done < <(printf '%s\n' "${SIZES[@]}" | sort -nr -k1,1)
  else
    echo
    warn "Skipping full list to keep output readable. Use --list-all to print everything."
  fi
  exit 0
fi

section "Delete Plan"
printf "ABOUT TO DELETE %s directories under:\n" "${#MATCHES[@]}"
printf "  %s\n" "$ROOT"
printf "Planned space to free (estimate): %s\n" "$TOTAL_HUMAN"
echo
warn "Type EXACTLY: delete"
read -r CONFIRM
[[ "$CONFIRM" == "delete" ]] || die "Confirmation failed; exiting."

deleted=0
deleted_kb=0
section "Deleting"
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
  progress "Deleting" "$deleted" "$TOTAL_MATCHES"
done

ok "Deleted $deleted directories."
printf "%bEstimated space freed:%b %s\n" "${C_BOLD}" "${C_RESET}" "$(human_kb "$deleted_kb")"
