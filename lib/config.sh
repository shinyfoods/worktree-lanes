# shellcheck shell=bash
# shellcheck disable=SC2034  # WTL_CFG_* vars are consumed by callers (lib/derive.sh, lib/emit.sh)
wtl_find_config() {
  local dir; dir="$(pwd -P)"
  while [ "$dir" != "/" ]; do
    [ -f "$dir/worktree.config" ] && { printf '%s\n' "$dir/worktree.config"; return 0; }
    dir="$(dirname "$dir")"
  done
  return 1
}

# Assert the six non-main port windows are disjoint. Fails closed: a config
# that would overlap is rejected at load rather than producing lanes that
# collide only sometimes, on only some slots, in only some pairings.
wtl_validate_port_bands() {
  # Check numerics first: every comparison below is arithmetic, and a
  # non-numeric override would otherwise surface as a raw bash error from
  # inside a validator whose whole job is to produce actionable ones.
  local _n _v
  for _n in WTL_CFG_LOCAL_SLOT_MOD WTL_CFG_CI_LANE_SLOT_MOD \
            WTL_CFG_NONMAIN_BACKEND_PORT_BASE WTL_CFG_NONMAIN_FRONTEND_PORT_BASE \
            WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE \
            WTL_CFG_NONMAIN_POSTGRES_PORT_BASE WTL_CFG_NONMAIN_REDIS_PORT_BASE; do
    _v="${!_n:-}"
    if [[ ! "$_v" =~ ^[0-9]+$ ]] || [ "$_v" -le 0 ]; then
      printf 'worktree.config: %s must be a positive integer (got: %s)\n' "$_n" "$_v" >&2
      return 1
    fi
  done

  local widest="$WTL_CFG_LOCAL_SLOT_MOD"
  [ "$WTL_CFG_CI_LANE_SLOT_MOD" -gt "$widest" ] && widest="$WTL_CFG_CI_LANE_SLOT_MOD"

  local specs="backend:$WTL_CFG_NONMAIN_BACKEND_PORT_BASE
frontend:$WTL_CFG_NONMAIN_FRONTEND_PORT_BASE
mailhog_ui:$WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE
mailhog_smtp:$WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE
postgres:$WTL_CFG_NONMAIN_POSTGRES_PORT_BASE
redis:$WTL_CFG_NONMAIN_REDIS_PORT_BASE"

  local sorted; sorted="$(printf '%s\n' "$specs" | sort -t: -k2 -n)"
  local prev_name="" prev_base="" name base gap
  while IFS=: read -r name base; do
    [ -z "$name" ] && continue
    if [ -n "$prev_base" ]; then
      gap=$(( base - prev_base ))
      if [ "$gap" -lt "$widest" ]; then
        printf 'worktree.config: non-main port bases %s (%s) and %s (%s) are %s apart, ' \
          "$prev_name" "$prev_base" "$name" "$base" "$gap" >&2
        printf 'but a lane slot spans up to %s.\n' "$widest" >&2
        printf '  Their port windows overlap, so two concurrent lanes can be assigned the same\n' >&2
        printf '  host port for different services. Widen the gap to at least %s, or lower\n' "$widest" >&2
        printf '  WTL_CI_LANE_SLOT_MOD / WTL_LOCAL_SLOT_MOD.\n' >&2
        return 1
      fi
    fi
    prev_name="$name"; prev_base="$base"
  done <<EOF
$sorted
EOF
  return 0
}

wtl_load_config() {
  local cfg; cfg="$(wtl_find_config)" || {
    echo "worktree: no worktree.config found (searched up from $(pwd)). Add one at the repo root." >&2
    return 1
  }
  # shellcheck disable=SC1090
  . "$cfg"
  : "${WTL_PROJECT:?worktree.config: WTL_PROJECT is required}"
  : "${WTL_ENV_PREFIX:?worktree.config: WTL_ENV_PREFIX is required}"
  # Validate WTL_ENV_PREFIX is a safe shell identifier before it reaches wtl_getvar's eval.
  # Rejects anything with $, (, ), whitespace, or other shell-special characters that would
  # allow command substitution or expansion inside the eval "printf '%s' \"\${...}\"" call.
  if [[ ! "$WTL_ENV_PREFIX" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
    echo "worktree.config: WTL_ENV_PREFIX must be a valid shell identifier (got: $WTL_ENV_PREFIX)" >&2
    return 1
  fi
  WTL_CFG_PROJECT="$WTL_PROJECT"
  WTL_CFG_PREFIX="$WTL_ENV_PREFIX"
  WTL_CFG_DB_USER="${WTL_DB_USER:-$WTL_PROJECT}"
  WTL_CFG_DB_PASSWORD="${WTL_DB_PASSWORD:-${WTL_PROJECT}_password}"
  WTL_CFG_MAIN_BACKEND_PORT="${WTL_MAIN_BACKEND_PORT:?worktree.config: WTL_MAIN_BACKEND_PORT is required}"
  WTL_CFG_MAIN_FRONTEND_PORT="${WTL_MAIN_FRONTEND_PORT:?worktree.config: WTL_MAIN_FRONTEND_PORT is required}"
  WTL_CFG_MAIN_POSTGRES_PORT="${WTL_MAIN_POSTGRES_PORT:?worktree.config: WTL_MAIN_POSTGRES_PORT is required}"
  WTL_CFG_MAIN_REDIS_PORT="${WTL_MAIN_REDIS_PORT:?worktree.config: WTL_MAIN_REDIS_PORT is required}"
  WTL_CFG_MAIN_MAILHOG_UI_PORT="${WTL_MAIN_MAILHOG_UI_PORT:-8025}"
  WTL_CFG_MAIN_MAILHOG_SMTP_PORT="${WTL_MAIN_MAILHOG_SMTP_PORT:-1025}"
  WTL_CFG_NONMAIN_BACKEND_PORT_BASE="${WTL_NONMAIN_BACKEND_PORT_BASE:-43000}"
  WTL_CFG_NONMAIN_FRONTEND_PORT_BASE="${WTL_NONMAIN_FRONTEND_PORT_BASE:-44000}"
  WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE="${WTL_NONMAIN_MAILHOG_UI_PORT_BASE:-45000}"
  WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE="${WTL_NONMAIN_MAILHOG_SMTP_PORT_BASE:-46000}"
  WTL_CFG_NONMAIN_POSTGRES_PORT_BASE="${WTL_NONMAIN_POSTGRES_PORT_BASE:-47000}"
  WTL_CFG_NONMAIN_REDIS_PORT_BASE="${WTL_NONMAIN_REDIS_PORT_BASE:-48000}"

  # Every non-main port is `base + slot`, so a service's ports occupy
  # [base, base + slot_mod - 1]. If any modulus exceeds the gap between two
  # bases those windows overlap, and two concurrent lanes can be handed the
  # same host port for *different* services — a collision that surfaces as a
  # binding that never appears rather than as an error, because the unit of
  # failure becomes the port number instead of the service.
  WTL_CFG_LOCAL_SLOT_MOD="${WTL_LOCAL_SLOT_MOD:-200}"
  WTL_CFG_CI_LANE_SLOT_MOD="${WTL_CI_LANE_SLOT_MOD:-1000}"

  wtl_validate_port_bands || return 1

  WTL_CFG_HAS_FRONTEND="${WTL_HAS_FRONTEND:-0}"
  WTL_CFG_HAS_SIDEKIQ="${WTL_HAS_SIDEKIQ:-0}"
  WTL_CFG_HAS_MAILHOG="${WTL_HAS_MAILHOG:-0}"
  WTL_CFG_HAS_WEBAUTHN="${WTL_HAS_WEBAUTHN:-0}"
  WTL_CFG_VALIDATE_SMOKE_SPEC="${WTL_VALIDATE_SMOKE_SPEC:-spec/requests/api/v1/health_spec.rb}"
  WTL_CFG_VALIDATE_DOCTOR="${WTL_VALIDATE_DOCTOR:-1}"
  WTL_CFG_REDIS_DB_DEV="${WTL_REDIS_DB_DEV:-1}"
  WTL_CFG_REDIS_DB_SIDEKIQ="${WTL_REDIS_DB_SIDEKIQ:-2}"
  WTL_CFG_REDIS_DB_TEST="${WTL_REDIS_DB_TEST:-3}"
}
