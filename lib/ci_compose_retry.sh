# shellcheck shell=bash
# shellcheck disable=SC2034  # WTL_CI_RETRYABLE_ERROR_PATTERN is consumed by callers via the functions below
# shellcheck disable=SC1091,SC2119  # loader is sourced from the installed CLI root and intentionally receives no caller args
. "$WTL_ROOT/lib/env.sh"

# Docker/Compose startup failure signatures safe to retry with a fresh CI lane
# suffix. Extracted from libexec/test-backend's original compose_up_isolated_with_retry
# so lane-up and test-backend classify failures identically. Anything outside
# this pattern fails fast — retrying a non-transient error would burn 3x the
# CI timeout masking a real bug.
WTL_CI_RETRYABLE_ERROR_PATTERN='port is already allocated|failed to bind host port|Port in use:|predefined address pools have been fully subnetted|missing dependency [a-z0-9_-]+|dependency [a-z0-9_-]+ failed to start|container [^ ]+ exited \(0\)|No such container:'

wtl_is_retryable_compose_error() {
  local logfile="$1"
  grep -Eqi "$WTL_CI_RETRYABLE_ERROR_PATTERN" "$logfile"
}

wtl_persist_ci_lane_suffix() {
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -n "${GITHUB_ENV:-}" ] && [ -n "${WTL_CI_LANE_SUFFIX:-}" ]; then
    echo "WTL_CI_LANE_SUFFIX=${WTL_CI_LANE_SUFFIX}" >> "$GITHUB_ENV"
  fi
}

# wtl_compose_up_with_ci_retry BASE_LABEL -- [compose up extra args...]
#
# Brings up $COMPOSE_PROJECT_NAME/$COMPOSE_FILE via `docker compose up -d`,
# retrying up to 3 attempts total under GITHUB_ACTIONS when the failure
# matches WTL_CI_RETRYABLE_ERROR_PATTERN. Each retry regenerates
# WTL_CI_LANE_SUFFIX="${BASE_LABEL}-r${attempt}", tears down the failed
# compose project, re-derives COMPOSE_PROJECT_NAME/ports via
# `worktree env --shell`, and logs the reason to stderr and
# $GITHUB_STEP_SUMMARY (when set). Outside CI, or on a non-retryable error,
# fails immediately on the first failure. On success, persists the final
# suffix to $GITHUB_ENV via wtl_persist_ci_lane_suffix so later steps in the
# same CI job (e2e runs, `worktree lane-down`, `worktree runner-clean-ci`)
# re-derive the identical compose project.
wtl_compose_up_with_ci_retry() {
  local base_label="$1"
  shift
  if [ "${1:-}" = "--" ]; then shift; fi

  local max_attempts=3
  local base_suffix="${WTL_CI_LANE_SUFFIX:-}"
  local attempt=1
  local janitor_ran=0
  local env_status

  while [ "$attempt" -le "$max_attempts" ]; do
    if [ "$attempt" -gt 1 ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
      WTL_CI_LANE_SUFFIX="${base_suffix:-$base_label}-r$((attempt - 1))"
      export WTL_CI_LANE_SUFFIX
      # shellcheck disable=SC2119  # caller arguments are not env-loader arguments
      if wtl_load_env; then
        :
      else
        env_status=$?
        return "$env_status"
      fi
    fi

    local up_log; up_log="$(mktemp)"
    if docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" up -d "$@" >"$up_log" 2>&1; then
      rm -f "$up_log"
      wtl_persist_ci_lane_suffix
      return 0
    fi

    if [ "${GITHUB_ACTIONS:-}" = "true" ] && wtl_is_retryable_compose_error "$up_log"; then
      local reason; reason="$(grep -Eio "$WTL_CI_RETRYABLE_ERROR_PATTERN" "$up_log" | head -1)"
      echo "CI lane startup retry ${attempt}/${max_attempts} (${base_label}): ${reason}" >&2
      sed -n '1,120p' "$up_log" >&2 || true
      if [ -n "${GITHUB_STEP_SUMMARY:-}" ]; then
        echo "- ⚠️ CI lane startup retry ${attempt}/${max_attempts} (\`${base_label}\`): ${reason}" >> "$GITHUB_STEP_SUMMARY"
      fi
      docker compose -p "$COMPOSE_PROJECT_NAME" -f "$COMPOSE_FILE" down -v --remove-orphans >/dev/null 2>&1 || true
      if printf '%s' "$reason" | grep -Eqi 'predefined address pools have been fully subnetted' && [ "$janitor_ran" -eq 0 ]; then
        echo "Running CI compose janitor before retry to free leaked Docker networks..." >&2
        worktree runner-clean-ci --apply --max-age=120 >&2 || true
        janitor_ran=1
      fi
      rm -f "$up_log"
      attempt=$((attempt + 1))
      continue
    fi

    cat "$up_log" >&2 || true
    rm -f "$up_log"
    return 1
  done

  echo "Failed to start CI lane (${base_label}) after ${max_attempts} attempts." >&2
  return 1
}
