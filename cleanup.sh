#!/usr/bin/env bash

set -uo pipefail

SCRIPT_NAME="$(basename "$0")"
LOCK_DIR="/tmp/${SCRIPT_NAME}.lock"
LOG_FILE=""

PROFILE="safe"
DRY_RUN=1
ASSUME_YES=0
INTERACTIVE=0
STRICT_MODE=1
INCLUDE_VOLUMES=0
INCLUDE_GLOBAL_CACHES=0
ONLY_CSV=""
SKIP_CSV=""

STATUS_LINES=()
START_TS="$(date '+%Y-%m-%d %H:%M:%S')"
TOTAL_ESTIMATED_BYTES=0
START_FREE_BYTES=0
END_FREE_BYTES=0
RUN_FAILED=0
TASK_HAD_FAILURE=0
CURRENT_TASK_EST_BYTES=0
CURRENT_TASK_ACTUAL_BYTES=0

print_usage() {
  cat <<'USAGE'
Usage: ./cleanup.sh [options]

A re-runnable macOS cleanup script with safe defaults.

Options:
  --profile <safe|aggressive|dev>  Cleanup profile (default: safe)
  --dry-run                        Print commands without executing (default)
  --apply                          Execute commands
  --yes                            Skip confirmation prompt for apply mode
  --interactive                    Ask before risky operations
  --strict                         Stop on first task with command failures (default)
  --no-strict                      Continue even if task commands fail
  --include-volumes                Allow Docker volume pruning
  --include-global-caches          Allow global cache removal (Cargo/Go mod cache)
  --only <tasks>                   Comma-separated task list to run
  --skip <tasks>                   Comma-separated task list to skip
  -h, --help                       Show this help

Tasks:
  docker,go,node,python,ruby,brew,xcode,ios_sim,gradle,cargo

Examples:
  ./cleanup.sh
  ./cleanup.sh --apply --yes --profile safe
  ./cleanup.sh --apply --yes --no-strict --only brew,node
  ./cleanup.sh --apply --yes --profile aggressive --include-volumes --include-global-caches
USAGE
}

log() {
  local msg="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg"
  if [[ -n "$LOG_FILE" ]]; then
    mkdir -p "$(dirname "$LOG_FILE")" 2>/dev/null || true
    printf '[%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$msg" >>"$LOG_FILE" 2>/dev/null || true
  fi
}

init_log_file() {
  local preferred="${HOME}/Library/Logs/${SCRIPT_NAME%.sh}.log"
  local fallback="/tmp/${SCRIPT_NAME%.sh}.log"

  if mkdir -p "$(dirname "$preferred")" 2>/dev/null && touch "$preferred" 2>/dev/null; then
    LOG_FILE="$preferred"
    return
  fi

  if touch "$fallback" 2>/dev/null; then
    LOG_FILE="$fallback"
    return
  fi

  LOG_FILE=""
}

free_bytes() {
  df -k "$HOME" | awk 'NR==2 {print $4 * 1024}'
}

human_bytes() {
  local bytes="$1"
  awk -v b="$bytes" '
    function human(x) {
      split("B KB MB GB TB PB", u, " ")
      i = 1
      while (x >= 1024 && i < 6) {
        x /= 1024
        i++
      }
      if (i == 1) {
        return sprintf("%d %s", x, u[i])
      }
      return sprintf("%.2f %s", x, u[i])
    }
    BEGIN { print human(b) }
  '
}

parse_size_to_bytes() {
  local size="$1"
  awk -v raw="$size" '
    BEGIN {
      s = raw
      gsub(",", "", s)
      if (match(s, /^([0-9]*\.?[0-9]+)([A-Za-z]+)$/, a) == 0) {
        print 0
        exit
      }
      n = a[1] + 0
      u = a[2]
      if (u == "B") m = 1
      else if (u == "kB" || u == "KB" || u == "KiB") m = 1024
      else if (u == "MB" || u == "MiB") m = 1024 * 1024
      else if (u == "GB" || u == "GiB") m = 1024 * 1024 * 1024
      else if (u == "TB" || u == "TiB") m = 1024 * 1024 * 1024 * 1024
      else m = 0
      printf "%.0f\n", n * m
    }
  '
}

path_size_bytes() {
  local p="$1"
  if [[ -e "$p" ]]; then
    du -sk "$p" 2>/dev/null | awk '{print $1 * 1024}'
  else
    echo 0
  fi
}

finish() {
  local exit_code=$?
  rm -rf "$LOCK_DIR"
  if [[ $exit_code -eq 0 ]]; then
    log "Cleanup run completed."
  else
    log "Cleanup run failed with exit code $exit_code."
  fi
}

acquire_lock() {
  if ! mkdir "$LOCK_DIR" 2>/dev/null; then
    echo "Another cleanup run appears to be active: $LOCK_DIR" >&2
    exit 1
  fi
  trap finish EXIT
}

require_cmd() {
  command -v "$1" >/dev/null 2>&1
}

should_run_task() {
  local task="$1"
  if [[ -n "$ONLY_CSV" && ",$ONLY_CSV," != *",$task,"* ]]; then
    return 1
  fi
  if [[ -n "$SKIP_CSV" && ",$SKIP_CSV," == *",$task,"* ]]; then
    return 1
  fi
  return 0
}

confirm_apply() {
  if [[ $DRY_RUN -eq 1 || $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  echo "About to run cleanup in apply mode. Continue? [y/N]"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

confirm_risky() {
  local prompt="$1"
  if [[ $INTERACTIVE -eq 0 || $ASSUME_YES -eq 1 ]]; then
    return 0
  fi
  echo "$prompt [y/N]"
  read -r answer
  [[ "$answer" =~ ^[Yy]$ ]]
}

run_cmd() {
  local desc="$1"
  shift
  local cmd=("$@")

  if [[ $DRY_RUN -eq 1 ]]; then
    log "[DRY-RUN] $desc"
    log "[DRY-RUN]   ${cmd[*]}"
    return 0
  fi

  log "[RUN] $desc"
  if "${cmd[@]}"; then
    return 0
  fi

  log "[WARN] Command failed: ${cmd[*]}"
  TASK_HAD_FAILURE=1
  return 1
}

append_status() {
  local task="$1"
  local status="$2"
  local note="$3"
  STATUS_LINES+=("${task}"$'\t'"${status}"$'\t'"${note}"$'\t'"${CURRENT_TASK_EST_BYTES}"$'\t'"${CURRENT_TASK_ACTUAL_BYTES}")
}

set_status_actual_and_failures() {
  local from_index="$1"
  local actual_bytes="$2"
  local i
  local task status note est _

  for ((i = from_index; i < ${#STATUS_LINES[@]}; i++)); do
    IFS=$'\t' read -r task status note est _ <<<"${STATUS_LINES[$i]}"
    if [[ $TASK_HAD_FAILURE -eq 1 && "$status" == "OK" ]]; then
      status="FAIL"
      note="${note} (one or more commands failed)"
    fi
    STATUS_LINES[$i]="${task}"$'\t'"${status}"$'\t'"${note}"$'\t'"${est}"$'\t'"${actual_bytes}"
  done
}

estimate_docker_reclaimable_bytes() {
  local total=0
  local line token bytes

  if ! require_cmd docker; then
    echo 0
    return
  fi

  while IFS= read -r line; do
    token="${line%% *}"
    bytes="$(parse_size_to_bytes "$token")"
    total=$((total + bytes))
  done < <(docker system df --format '{{.Reclaimable}}' 2>/dev/null)

  echo "$total"
}

estimate_task_bytes() {
  local task="$1"
  local est=0
  local p=""

  case "$task" in
    docker)
      est=$((est + $(estimate_docker_reclaimable_bytes)))
      ;;
    go)
      if require_cmd go; then
        p="$(go env GOCACHE 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
        if [[ $INCLUDE_GLOBAL_CACHES -eq 1 || "$PROFILE" == "aggressive" ]]; then
          p="$(go env GOMODCACHE 2>/dev/null || true)"
          est=$((est + $(path_size_bytes "$p")))
        fi
      fi
      ;;
    node)
      if require_cmd npm; then
        p="$(npm config get cache 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
      fi
      if require_cmd yarn; then
        p="${HOME}/Library/Caches/Yarn"
        est=$((est + $(path_size_bytes "$p")))
      fi
      if require_cmd pnpm; then
        p="$(pnpm store path 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
      fi
      ;;
    python)
      if require_cmd uv; then
        p="$(uv cache dir 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
      fi
      if require_cmd pip; then
        p="$(pip cache dir 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
      fi
      ;;
    brew)
      if require_cmd brew; then
        p="$(brew --cache 2>/dev/null || true)"
        est=$((est + $(path_size_bytes "$p")))
      fi
      ;;
    xcode)
      est=$((est + $(path_size_bytes "${HOME}/Library/Developer/Xcode/DerivedData")))
      ;;
    gradle)
      est=$((est + $(path_size_bytes "${HOME}/.gradle/caches")))
      ;;
    cargo)
      if [[ $INCLUDE_GLOBAL_CACHES -eq 1 || "$PROFILE" == "aggressive" ]]; then
        est=$((est + $(path_size_bytes "${HOME}/.cargo/registry")))
        est=$((est + $(path_size_bytes "${HOME}/.cargo/git")))
      fi
      ;;
    ruby|ios_sim)
      est=0
      ;;
    *)
      est=0
      ;;
  esac

  if [[ -z "$est" || "$est" -lt 0 ]]; then
    est=0
  fi
  echo "$est"
}

cleanup_docker() {
  local task="docker"
  if ! require_cmd docker; then
    append_status "$task" "SKIP" "docker not installed"
    return
  fi

  run_cmd "Docker safe prune" docker system prune -f || true

  if [[ "$PROFILE" == "aggressive" ]]; then
    run_cmd "Docker aggressive prune" docker system prune -af || true
  fi

  if [[ $INCLUDE_VOLUMES -eq 1 ]]; then
    if confirm_risky "Prune unused Docker volumes?"; then
      run_cmd "Docker prune with volumes" docker system prune -af --volumes || true
      append_status "$task" "OK" "pruned including volumes"
      return
    fi
    append_status "$task" "SKIP" "volume prune declined"
    return
  fi

  append_status "$task" "OK" "pruned containers/images/cache"
}

cleanup_go() {
  local task="go"
  if ! require_cmd go; then
    append_status "$task" "SKIP" "go not installed"
    return
  fi

  run_cmd "Go build/test cache cleanup" go clean -cache -testcache || true

  if [[ $INCLUDE_GLOBAL_CACHES -eq 1 || "$PROFILE" == "aggressive" ]]; then
    if confirm_risky "Clear Go module cache (go clean -modcache)?"; then
      run_cmd "Go module cache cleanup" go clean -modcache || true
      append_status "$task" "OK" "cleared cache + modcache"
      return
    fi
  fi

  append_status "$task" "OK" "cleared build/test cache"
}

cleanup_node() {
  local task="node"
  local ran=0

  if require_cmd npm; then
    run_cmd "npm cache verify" npm cache verify || true
    run_cmd "npm cache clean" npm cache clean --force || true
    ran=1
  fi

  if require_cmd yarn; then
    run_cmd "yarn cache clean" yarn cache clean || true
    ran=1
  fi

  if require_cmd pnpm; then
    run_cmd "pnpm store prune" pnpm store prune || true
    ran=1
  fi

  if [[ $ran -eq 1 ]]; then
    append_status "$task" "OK" "package manager caches cleaned"
  else
    append_status "$task" "SKIP" "no npm/yarn/pnpm found"
  fi
}

cleanup_python() {
  local task="python"
  local ran=0

  if require_cmd uv; then
    run_cmd "uv cache prune" uv cache prune || true
    ran=1
  fi

  if require_cmd pip; then
    run_cmd "pip cache purge" pip cache purge || true
    ran=1
  fi

  if [[ $ran -eq 1 ]]; then
    append_status "$task" "OK" "python caches pruned"
  else
    append_status "$task" "SKIP" "no uv/pip found"
  fi
}

cleanup_ruby() {
  local task="ruby"
  if ! require_cmd bundle; then
    append_status "$task" "SKIP" "bundler not installed"
    return
  fi

  run_cmd "bundle clean" bundle clean --force || true
  append_status "$task" "OK" "bundler cleaned"
}

cleanup_brew() {
  local task="brew"
  if ! require_cmd brew; then
    append_status "$task" "SKIP" "brew not installed"
    return
  fi

  run_cmd "brew cleanup" brew cleanup -s || true
  run_cmd "brew autoremove" brew autoremove || true
  append_status "$task" "OK" "brew cleanup + autoremove"
}

cleanup_xcode() {
  local task="xcode"
  local target="${HOME}/Library/Developer/Xcode/DerivedData"
  if [[ ! -d "$target" ]]; then
    append_status "$task" "SKIP" "DerivedData not found"
    return
  fi

  run_cmd "Remove Xcode DerivedData" rm -rf "$target" || true
  append_status "$task" "OK" "DerivedData removed"
}

cleanup_ios_sim() {
  local task="ios_sim"
  if ! require_cmd xcrun; then
    append_status "$task" "SKIP" "xcrun not installed"
    return
  fi

  run_cmd "Delete unavailable iOS simulators" xcrun simctl delete unavailable || true
  append_status "$task" "OK" "unavailable simulators deleted"
}

cleanup_gradle() {
  local task="gradle"
  local target="${HOME}/.gradle/caches"
  if [[ ! -d "$target" ]]; then
    append_status "$task" "SKIP" "~/.gradle/caches not found"
    return
  fi

  run_cmd "Remove Gradle caches" rm -rf "$target" || true
  append_status "$task" "OK" "gradle caches removed"
}

cleanup_cargo() {
  local task="cargo"
  local registry="${HOME}/.cargo/registry"
  local git_cache="${HOME}/.cargo/git"

  if [[ $INCLUDE_GLOBAL_CACHES -eq 0 && "$PROFILE" != "aggressive" ]]; then
    append_status "$task" "SKIP" "global cache cleanup disabled"
    return
  fi

  if [[ ! -d "$registry" && ! -d "$git_cache" ]]; then
    append_status "$task" "SKIP" "cargo global caches not found"
    return
  fi

  if confirm_risky "Delete Cargo global caches (~/.cargo/registry ~/.cargo/git)?"; then
    run_cmd "Remove Cargo global caches" rm -rf "$registry" "$git_cache" || true
    append_status "$task" "OK" "cargo global caches removed"
    return
  fi

  append_status "$task" "SKIP" "cargo cache cleanup declined"
}

run_task() {
  local task="$1"
  local start_index=0
  local estimated=0
  local start_task_free=0
  local end_task_free=0

  if ! should_run_task "$task"; then
    return 0
  fi

  TASK_HAD_FAILURE=0
  CURRENT_TASK_ACTUAL_BYTES=0
  start_index="${#STATUS_LINES[@]}"

  estimated="$(estimate_task_bytes "$task")"
  CURRENT_TASK_EST_BYTES="$estimated"
  TOTAL_ESTIMATED_BYTES=$((TOTAL_ESTIMATED_BYTES + estimated))

  if [[ $DRY_RUN -eq 0 ]]; then
    start_task_free="$(free_bytes)"
  fi

  case "$task" in
    docker) cleanup_docker ;;
    go) cleanup_go ;;
    node) cleanup_node ;;
    python) cleanup_python ;;
    ruby) cleanup_ruby ;;
    brew) cleanup_brew ;;
    xcode) cleanup_xcode ;;
    ios_sim) cleanup_ios_sim ;;
    gradle) cleanup_gradle ;;
    cargo) cleanup_cargo ;;
    *) log "[WARN] Unknown task: $task" ;;
  esac

  if [[ $DRY_RUN -eq 0 ]]; then
    end_task_free="$(free_bytes)"
    if [[ "$end_task_free" -gt "$start_task_free" ]]; then
      CURRENT_TASK_ACTUAL_BYTES="$((end_task_free - start_task_free))"
    fi
  fi

  if [[ "${#STATUS_LINES[@]}" -gt "$start_index" ]]; then
    set_status_actual_and_failures "$start_index" "$CURRENT_TASK_ACTUAL_BYTES"
  fi

  if [[ $TASK_HAD_FAILURE -eq 1 && $STRICT_MODE -eq 1 ]]; then
    log "[ERROR] Strict mode stopping on failed task: $task"
    RUN_FAILED=1
    return 1
  fi

  return 0
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --profile)
        PROFILE="${2:-}"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=1
        shift
        ;;
      --apply)
        DRY_RUN=0
        shift
        ;;
      --yes)
        ASSUME_YES=1
        shift
        ;;
      --interactive)
        INTERACTIVE=1
        shift
        ;;
      --strict)
        STRICT_MODE=1
        shift
        ;;
      --no-strict)
        STRICT_MODE=0
        shift
        ;;
      --include-volumes)
        INCLUDE_VOLUMES=1
        shift
        ;;
      --include-global-caches)
        INCLUDE_GLOBAL_CACHES=1
        shift
        ;;
      --only)
        ONLY_CSV="${2:-}"
        shift 2
        ;;
      --skip)
        SKIP_CSV="${2:-}"
        shift 2
        ;;
      -h|--help)
        print_usage
        exit 0
        ;;
      *)
        echo "Unknown argument: $1" >&2
        print_usage
        exit 1
        ;;
    esac
  done

  case "$PROFILE" in
    safe|aggressive|dev) ;;
    *)
      echo "Invalid profile: $PROFILE (expected safe|aggressive|dev)" >&2
      exit 1
      ;;
  esac
}

main() {
  parse_args "$@"
  init_log_file
  acquire_lock

  log "Cleanup run started at $START_TS"
  log "Settings: profile=$PROFILE dry_run=$DRY_RUN yes=$ASSUME_YES strict=$STRICT_MODE only=${ONLY_CSV:-all} skip=${SKIP_CSV:-none}"
  START_FREE_BYTES="$(free_bytes)"

  if [[ $DRY_RUN -eq 0 ]] && ! confirm_apply; then
    log "Aborted by user before apply mode execution."
    exit 1
  fi

  local tasks=(docker go node python ruby brew)

  if [[ "$PROFILE" == "aggressive" || "$PROFILE" == "dev" ]]; then
    tasks+=(xcode ios_sim gradle)
  fi

  if [[ "$PROFILE" == "aggressive" ]]; then
    tasks+=(cargo)
  fi

  local task
  for task in "${tasks[@]}"; do
    if ! run_task "$task"; then
      break
    fi
  done

  log "Summary:"
  log "task       status   estimated    reclaimed    note"
  log "---------- -------- ------------ ------------ -----------------------------------------"

  local line row_task row_status row_note row_est row_actual
  for line in "${STATUS_LINES[@]}"; do
    IFS=$'\t' read -r row_task row_status row_note row_est row_actual <<<"$line"
    if [[ $DRY_RUN -eq 1 ]]; then
      log "$(printf '%-10s %-8s %-12s %-12s %s' "$row_task" "$row_status" "$(human_bytes "$row_est")" "n/a" "$row_note")"
    else
      log "$(printf '%-10s %-8s %-12s %-12s %s' "$row_task" "$row_status" "$(human_bytes "$row_est")" "$(human_bytes "$row_actual")" "$row_note")"
    fi
  done

  if [[ $DRY_RUN -eq 1 ]]; then
    log "Estimated total space to reclaim: $(human_bytes "$TOTAL_ESTIMATED_BYTES")"
  else
    END_FREE_BYTES="$(free_bytes)"
    if [[ "$END_FREE_BYTES" -gt "$START_FREE_BYTES" ]]; then
      log "Total space reclaimed: $(human_bytes "$((END_FREE_BYTES - START_FREE_BYTES))")"
    else
      log "Total space reclaimed: 0 B"
    fi
  fi

  log "Tip: schedule with launchd using '--apply --yes --profile safe'."

  if [[ $RUN_FAILED -eq 1 ]]; then
    exit 1
  fi
}

main "$@"
