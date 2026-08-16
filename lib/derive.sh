# shellcheck shell=bash
# shellcheck disable=SC2034  # WTL_* output vars are consumed by emit.sh and callers

# wtl_getvar VAR_NAME — portable indirect variable lookup (works on bash 3.2+)
# Intentional eval: the caller supplies a validated shell identifier, and this
# performs an indirect variable read rather than evaluating generated env output.
wtl_getvar() {
  eval "printf '%s' \"\${${1}:-}\""
}

wtl_hash_hex() {
  if command -v shasum >/dev/null 2>&1; then
    printf '%s' "$1" | shasum -a 256 | awk '{print $1}'
  else
    printf '%s' "$1" | sha256sum | awk '{print $1}'
  fi
}

# wtl_id_for_path PATH — return the 8-hex worktree id for a given absolute path.
# Mirrors the non-CI-lane branch of wtl_derive: sha256(path)[0:8].
# Used by db-prune to enumerate live worktree ids without spawning subprocesses.
wtl_id_for_path() {
  local path="$1"
  local hash; hash=$(wtl_hash_hex "$path")
  printf '%s' "${hash:0:8}"
}

# wtl_git_retry CMD... — run a read-only git command that can transiently fail
# under concurrent git activity (index.lock contention when several worktrees
# or agents touch the repo at once). Retries a few times with a short backoff;
# prints stdout on the first success. Returns non-zero only if every attempt
# fails, so callers can surface a clear error instead of handing an empty dump
# to the guarded environment loader.
wtl_git_retry() {
  local attempt out
  for attempt in 1 2 3 4 5; do
    if out="$("$@" 2>/dev/null)"; then
      printf '%s' "$out"
      return 0
    fi
    [ "$attempt" -lt 5 ] && sleep 0.2
  done
  return 1
}

wtl_derive() {
  # Allow WTL_FAKE_ROOT to override the worktree root for golden parity tests.
  if [ -n "${WTL_FAKE_ROOT:-}" ]; then
    WTL_WORKTREE_ROOT="$WTL_FAKE_ROOT"
  else
    # Retry the toplevel read so a transient git failure doesn't silently fall
    # back to (a possibly-wrong) pwd; pwd remains the last-resort fallback.
    WTL_WORKTREE_ROOT="$(wtl_git_retry git rev-parse --show-toplevel || pwd -P)"
  fi

  # Allow WTL_FAKE_MAIN_REPO to override the main-repo path for CI portability tests.
  # When set, skip the git worktree list shell-out entirely — no real git repo needed.
  # When unset, behavior is unchanged (production unaffected).
  if [ -n "${WTL_FAKE_MAIN_REPO:-}" ]; then
    WTL_MAIN_REPO="$WTL_FAKE_MAIN_REPO"
  else
    # This shell-out was the single point that, under `set -euo pipefail`, turned
    # a transient `git worktree list` failure into an empty `worktree env` emit
    # (pipefail propagates the git failure through the awk pipe) and a cryptic
    # downstream unbound-variable crash. Retry, then fail LOUDLY with an
    # actionable message rather than emitting an empty, misleading environment.
    local _wtl_worktree_list
    if ! _wtl_worktree_list="$(wtl_git_retry git worktree list --porcelain)"; then
      printf 'worktree: could not determine the main repo — "git worktree list" failed after retries.\n' >&2
      printf '  Run inside a git repository, or set WTL_FAKE_MAIN_REPO to the main checkout path.\n' >&2
      return 1
    fi
    WTL_MAIN_REPO="$(printf '%s\n' "$_wtl_worktree_list" | awk '/^worktree/{print $2; exit}')"
    if [ -z "$WTL_MAIN_REPO" ]; then
      printf 'worktree: "git worktree list" returned no worktree entry (not inside a git repo?).\n' >&2
      return 1
    fi
  fi
  WTL_COMPOSE_FILE="$WTL_MAIN_REPO/docker-compose.yml"

  # CI lane key: honor neutral override first, then prefixed form, then auto-derive from GHA env.
  # The neutral WTL_CI_LANE_SUFFIX/WTL_CI_LANE_KEY vars are exported by libexec scripts on retry
  # so re-executing `worktree env` picks up the new suffix and produces a different WORKTREE_ID.
  local ci_lane_key_input; ci_lane_key_input="${WTL_CI_LANE_KEY:-$(wtl_getvar "${WTL_CFG_PREFIX}_CI_LANE_KEY")}"
  local ci_lane_suffix_input; ci_lane_suffix_input="${WTL_CI_LANE_SUFFIX:-$(wtl_getvar "${WTL_CFG_PREFIX}_CI_LANE_SUFFIX")}"
  WTL_CI_LANE_KEY="$ci_lane_key_input"
  if [ -z "$WTL_CI_LANE_KEY" ] && [ "${GITHUB_ACTIONS:-}" = "true" ]; then
    WTL_CI_LANE_KEY="gha-${GITHUB_RUN_ID:-0}-${GITHUB_RUN_ATTEMPT:-0}-${GITHUB_JOB:-job}-${RUNNER_NAME:-runner}"
    if [ -n "$ci_lane_suffix_input" ]; then
      WTL_CI_LANE_KEY="${WTL_CI_LANE_KEY}-${ci_lane_suffix_input}"
    fi
  fi

  WTL_IS_MAIN=0
  if [ "$WTL_WORKTREE_ROOT" = "$WTL_MAIN_REPO" ]; then
    WTL_IS_MAIN=1
  fi
  # CI lane forces non-main naming regardless of path
  if [ -n "$WTL_CI_LANE_KEY" ]; then
    WTL_IS_MAIN=0
  fi

  # Compute hash for identity + slot
  local hash_input="$WTL_WORKTREE_ROOT"
  if [ -n "$WTL_CI_LANE_KEY" ]; then
    hash_input="$WTL_WORKTREE_ROOT|$WTL_CI_LANE_KEY"
  fi
  local hash; hash=$(wtl_hash_hex "$hash_input")
  WTL_WORKTREE_ID="${hash:0:8}"
  local slot_hex="${hash:0:6}"
  local slot_dec; slot_dec=$(printf '%d' "0x$slot_hex")
  local slot_mod=200
  if [ -n "$WTL_CI_LANE_KEY" ]; then
    slot_mod=15000
  fi
  local slot=$(( slot_dec % slot_mod ))

  # Derive worktree name from directory basename
  local base_name; base_name=$(basename "$WTL_WORKTREE_ROOT")
  if [ -n "$WTL_CI_LANE_KEY" ]; then
    base_name="ci"
  fi
  local safe_name; safe_name=$(printf '%s' "$base_name" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-')
  safe_name=${safe_name#-}
  safe_name=${safe_name%-}
  WTL_WORKTREE_NAME="${safe_name:-${WTL_CFG_PROJECT}}"

  WTL_COMPOSE_PROJECT="${WTL_CFG_PROJECT}-${WTL_WORKTREE_NAME}-${WTL_WORKTREE_ID}"

  if [ "$WTL_IS_MAIN" -eq 1 ]; then
    WTL_COMPOSE_PROJECT="${WTL_CFG_PROJECT}-main"
    WTL_BACKEND_PORT="$WTL_CFG_MAIN_BACKEND_PORT"
    WTL_FRONTEND_PORT="$WTL_CFG_MAIN_FRONTEND_PORT"
    WTL_MAILHOG_UI_PORT="$WTL_CFG_MAIN_MAILHOG_UI_PORT"
    WTL_MAILHOG_SMTP_PORT="$WTL_CFG_MAIN_MAILHOG_SMTP_PORT"
    WTL_POSTGRES_PORT="$WTL_CFG_MAIN_POSTGRES_PORT"
    WTL_REDIS_PORT="$WTL_CFG_MAIN_REDIS_PORT"
    WTL_DEV_DB_NAME="${WTL_CFG_PROJECT}_development"
  else
    WTL_BACKEND_PORT=$(( WTL_CFG_NONMAIN_BACKEND_PORT_BASE + slot ))
    WTL_FRONTEND_PORT=$(( WTL_CFG_NONMAIN_FRONTEND_PORT_BASE + slot ))
    WTL_MAILHOG_UI_PORT=$(( WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE + slot ))
    WTL_MAILHOG_SMTP_PORT=$(( WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE + slot ))
    WTL_POSTGRES_PORT=$(( WTL_CFG_NONMAIN_POSTGRES_PORT_BASE + slot ))
    WTL_REDIS_PORT=$(( WTL_CFG_NONMAIN_REDIS_PORT_BASE + slot ))
    WTL_DEV_DB_NAME="${WTL_CFG_PROJECT}_dev_${WTL_WORKTREE_ID}"
  fi

  WTL_TEST_DB_NAME="${WTL_CFG_PROJECT}_test_${WTL_WORKTREE_ID}"
  WTL_POSTGRES_DB="$WTL_DEV_DB_NAME"
  WTL_REDIS_DB_DEV="$WTL_CFG_REDIS_DB_DEV"
  WTL_REDIS_DB_SIDEKIQ="$WTL_CFG_REDIS_DB_SIDEKIQ"
  WTL_REDIS_DB_TEST="$WTL_CFG_REDIS_DB_TEST"

  # Shared infra constants
  WTL_SHARED_INFRA_PROJECT_NAME="${WTL_CFG_PROJECT}-shared-infra"
  WTL_SHARED_POSTGRES_PORT=15432
  WTL_SHARED_REDIS_PORT=16379
  WTL_SHARED_MAILHOG_SMTP_PORT=11025
  WTL_SHARED_MAILHOG_UI_PORT=18025
  WTL_SHARED_DB_HOST="host.docker.internal"
  WTL_SHARED_REDIS_HOST="host.docker.internal"

  # Infra mode (isolated vs shared)
  local infra_mode_input; infra_mode_input="$(wtl_getvar "${WTL_CFG_PREFIX}_INFRA_MODE")"
  WTL_INFRA_MODE="${infra_mode_input:-isolated}"

  WTL_INFRA_DB_HOST="postgres"
  WTL_INFRA_DB_PORT=5432
  WTL_INFRA_REDIS_HOST="redis"
  WTL_INFRA_REDIS_PORT=6379
  WTL_INFRA_SMTP_HOST="mailhog"
  WTL_INFRA_SMTP_PORT=1025

  if [ "$WTL_INFRA_MODE" = "shared" ]; then
    WTL_INFRA_DB_HOST="$WTL_SHARED_DB_HOST"
    WTL_INFRA_DB_PORT="$WTL_SHARED_POSTGRES_PORT"
    WTL_INFRA_REDIS_HOST="$WTL_SHARED_REDIS_HOST"
    WTL_INFRA_REDIS_PORT="$WTL_SHARED_REDIS_PORT"
    WTL_INFRA_SMTP_HOST="$WTL_SHARED_DB_HOST"
    WTL_INFRA_SMTP_PORT="$WTL_SHARED_MAILHOG_SMTP_PORT"
  fi

  WTL_DB_HOST="$WTL_INFRA_DB_HOST"
  WTL_DB_TCP_PORT="$WTL_INFRA_DB_PORT"
  WTL_REDIS_HOST="$WTL_INFRA_REDIS_HOST"
  WTL_REDIS_TCP_PORT="$WTL_INFRA_REDIS_PORT"
  WTL_SMTP_HOST="$WTL_INFRA_SMTP_HOST"
  WTL_SMTP_TCP_PORT="$WTL_INFRA_SMTP_PORT"

  # DB credentials (consumed by ported subcommands for DATABASE_URL construction)
  WTL_DB_USER="$WTL_CFG_DB_USER"
  WTL_DB_PASSWORD="$WTL_CFG_DB_PASSWORD"

  # Feature flags (consumed by ported subcommands to gate optional services)
  WTL_HAS_FRONTEND="$WTL_CFG_HAS_FRONTEND"
  WTL_HAS_SIDEKIQ="$WTL_CFG_HAS_SIDEKIQ"
  WTL_HAS_MAILHOG="$WTL_CFG_HAS_MAILHOG"
  WTL_HAS_WEBAUTHN="$WTL_CFG_HAS_WEBAUTHN"

  # Host loopback (Firefox CI workaround)
  local host_loopback_input; host_loopback_input="$(wtl_getvar "${WTL_CFG_PREFIX}_HOST_LOOPBACK")"
  WTL_HOST_LOOPBACK="${host_loopback_input:-localhost}"
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -z "$host_loopback_input" ]; then
    WTL_HOST_LOOPBACK="127.0.0.1"
  fi

  WTL_FRONTEND_URL="http://${WTL_HOST_LOOPBACK}:${WTL_FRONTEND_PORT}"
  WTL_API_BASE_URL="http://${WTL_HOST_LOOPBACK}:${WTL_BACKEND_PORT}/api/v1"
  WTL_WS_BASE_URL="ws://${WTL_HOST_LOOPBACK}:${WTL_BACKEND_PORT}/cable"
  WTL_MAILHOG_API_URL="http://${WTL_HOST_LOOPBACK}:${WTL_MAILHOG_UI_PORT}/api"

  # WebAuthn RP (always computed; emitted selectively by emit.sh)
  WTL_WEBAUTHN_RP_ORIGIN="$WTL_FRONTEND_URL"
  WTL_WEBAUTHN_RP_ID="$WTL_HOST_LOOPBACK"

  # Allow WTL_FAKE_CONTAINER_UID/GID overrides for golden parity tests on CI
  # (id -u/id -g vary by OS/runner; override pins them to the captured values).
  WTL_CONTAINER_UID="${WTL_FAKE_CONTAINER_UID:-$(id -u)}"
  WTL_CONTAINER_GID="${WTL_FAKE_CONTAINER_GID:-$(id -g)}"

  # Frontend container UID/GID (emitted when WTL_CFG_HAS_FRONTEND=1)
  local frontend_uid_input; frontend_uid_input="$(wtl_getvar "${WTL_CFG_PREFIX}_FRONTEND_CONTAINER_UID")"
  local frontend_gid_input; frontend_gid_input="$(wtl_getvar "${WTL_CFG_PREFIX}_FRONTEND_CONTAINER_GID")"
  WTL_FRONTEND_CONTAINER_UID="${frontend_uid_input:-$WTL_CONTAINER_UID}"
  WTL_FRONTEND_CONTAINER_GID="${frontend_gid_input:-$WTL_CONTAINER_GID}"
  # macOS local: run frontend as root to avoid Vite EACCES on anonymous volumes
  if [ "$(uname -s)" = "Darwin" ] && [ "${GITHUB_ACTIONS:-}" != "true" ] \
    && [ -z "$frontend_uid_input" ] && [ -z "$frontend_gid_input" ]; then
    WTL_FRONTEND_CONTAINER_UID=0
    WTL_FRONTEND_CONTAINER_GID=0
  fi

  # Frontend run mode (emitted when WTL_CFG_HAS_FRONTEND=1)
  local frontend_run_mode_input; frontend_run_mode_input="$(wtl_getvar "${WTL_CFG_PREFIX}_FRONTEND_RUN_MODE")"
  WTL_FRONTEND_RUN_MODE="${frontend_run_mode_input:-dev}"
  if [ "${GITHUB_ACTIONS:-}" = "true" ] && [ -z "$frontend_run_mode_input" ]; then
    WTL_FRONTEND_RUN_MODE="preview"
  fi
}
