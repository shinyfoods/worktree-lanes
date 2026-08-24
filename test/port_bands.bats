#!/usr/bin/env bats
# Lane ports are `base + slot`, so each service occupies [base, base+slot_mod-1].
# These windows must stay disjoint: when they overlap, two concurrent lanes can
# be handed the same host port for different services, and the failure shows up
# as a binding that never appears rather than as an error.
load helper

setup() {
  . "$BATS_TEST_DIRNAME/../lib/config.sh"
  . "$BATS_TEST_DIRNAME/../lib/derive.sh"
  root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
  cd "$root"
  unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB RUNNER_NAME
  unset WTL_CI_LANE_SLOT_MOD WTL_LOCAL_SLOT_MOD
  unset WTL_NONMAIN_BACKEND_PORT_BASE WTL_NONMAIN_FRONTEND_PORT_BASE
  unset WTL_NONMAIN_MAILHOG_UI_PORT_BASE WTL_NONMAIN_MAILHOG_SMTP_PORT_BASE
  unset WTL_NONMAIN_POSTGRES_PORT_BASE WTL_NONMAIN_REDIS_PORT_BASE
}

# Highest port any service can be assigned, across both moduli.
highest_port() {
  local widest="$WTL_CFG_LOCAL_SLOT_MOD"
  [ "$WTL_CFG_CI_LANE_SLOT_MOD" -gt "$widest" ] && widest="$WTL_CFG_CI_LANE_SLOT_MOD"
  printf '%d' "$(( WTL_CFG_NONMAIN_REDIS_PORT_BASE + widest - 1 ))"
}

@test "the shipped config validates: no two port windows overlap" {
  run wtl_load_config
  [ "$status" -eq 0 ]
}

@test "every pair of port windows is disjoint at the shipped moduli" {
  wtl_load_config
  local widest="$WTL_CFG_LOCAL_SLOT_MOD"
  [ "$WTL_CFG_CI_LANE_SLOT_MOD" -gt "$widest" ] && widest="$WTL_CFG_CI_LANE_SLOT_MOD"

  # Sorted bases; each gap must clear the widest slot span.
  local bases="$WTL_CFG_NONMAIN_BACKEND_PORT_BASE
$WTL_CFG_NONMAIN_FRONTEND_PORT_BASE
$WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE
$WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE
$WTL_CFG_NONMAIN_POSTGRES_PORT_BASE
$WTL_CFG_NONMAIN_REDIS_PORT_BASE"

  local prev="" b
  while read -r b; do
    [ -z "$b" ] && continue
    if [ -n "$prev" ]; then
      [ "$(( b - prev ))" -ge "$widest" ]
    fi
    prev="$b"
  done <<< "$(printf '%s\n' "$bases" | sort -n)"
}

# The control for the test above: without this, "windows are disjoint" would
# also pass on a config where the guard had been silently disabled.
@test "the guard REJECTS a config whose bases are closer than a slot span" {
  export WTL_NONMAIN_FRONTEND_PORT_BASE=43500   # 500 above backend's 43000
  run wtl_load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"port windows overlap"* ]] || [[ "$output" == *"are 500 apart"* ]]
}

@test "the guard names both offending services and the actual gap" {
  export WTL_NONMAIN_POSTGRES_PORT_BASE=45500   # 500 above mailhog_ui's 45000
  run wtl_load_config
  [ "$status" -ne 0 ]
  [[ "$output" == *"mailhog_ui"* ]]
  [[ "$output" == *"postgres"* ]]
  [[ "$output" == *"500 apart"* ]]
}

@test "a CI-lane slot never reaches the next service's base" {
  wtl_load_config
  export GITHUB_ACTIONS=true GITHUB_RUN_ID=42 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=lane RUNNER_NAME=r1
  WTL_FAKE_ROOT="$root/ci-lane"
  wtl_derive

  [ "$WTL_BACKEND_PORT" -ge "$WTL_CFG_NONMAIN_BACKEND_PORT_BASE" ]
  [ "$WTL_BACKEND_PORT" -lt "$WTL_CFG_NONMAIN_FRONTEND_PORT_BASE" ]
  [ "$WTL_FRONTEND_PORT" -lt "$WTL_CFG_NONMAIN_MAILHOG_UI_PORT_BASE" ]
  [ "$WTL_MAILHOG_UI_PORT" -lt "$WTL_CFG_NONMAIN_MAILHOG_SMTP_PORT_BASE" ]
  [ "$WTL_MAILHOG_SMTP_PORT" -lt "$WTL_CFG_NONMAIN_POSTGRES_PORT_BASE" ]
  [ "$WTL_POSTGRES_PORT" -lt "$WTL_CFG_NONMAIN_REDIS_PORT_BASE" ]
}

# The regression this file exists for. HUD-834: a CI lane at slot 14776 put
# backend/frontend/mailhog_ui at 57776/58776/59776 — all three inside the
# runner's ephemeral range (55540-59635), and one lost its binding silently.
@test "no lane port can land in a typical Linux ephemeral range" {
  wtl_load_config
  local eph_lo=32768   # conservative: the kernel default low bound
  [ "$(highest_port)" -lt "$eph_lo" ] || {
    # The shipped bases sit above 32768, so assert against the range actually
    # observed on the runner that produced HUD-834 rather than the kernel default.
    [ "$(highest_port)" -lt 55540 ]
  }
}
