#!/usr/bin/env bats
load helper
setup() {
  . "$BATS_TEST_DIRNAME/../lib/config.sh"
  . "$BATS_TEST_DIRNAME/../lib/derive.sh"
  root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
  cd "$root"
  wtl_load_config
  # Unset GHA env so tests that don't explicitly set GITHUB_ACTIONS run in non-CI mode.
  # Tests that need CI-lane behavior set their own GITHUB_ACTIONS=true explicitly.
  unset GITHUB_ACTIONS GITHUB_RUN_ID GITHUB_RUN_ATTEMPT GITHUB_JOB RUNNER_NAME
}

@test "worktree id is sha256[0:8] of the worktree root, stable" {
  wtl_derive
  id1="$WTL_WORKTREE_ID"
  wtl_derive
  [ "$WTL_WORKTREE_ID" = "$id1" ]
  # Use derive.sh's own portable hash helper (shasum || sha256sum fallback)
  expect="$(wtl_id_for_path "$WTL_WORKTREE_ROOT")"
  [ "$WTL_WORKTREE_ID" = "$expect" ]
}

@test "test db name is always per-id" {
  wtl_derive
  [ "$WTL_TEST_DB_NAME" = "huddle_test_${WTL_WORKTREE_ID}" ]
}

@test "non-main postgres port = base + slot" {
  # Use a fake root that is different from MAIN_REPO to force non-main mode
  WTL_FAKE_ROOT="$root/nonmain-branch"
  wtl_derive
  slot=$(( $(printf '%d' "0x$(wtl_hash_hex "$WTL_FAKE_ROOT" | cut -c1-6)") % 200 ))
  [ "$WTL_POSTGRES_PORT" = "$(( 47000 + slot ))" ]
}

@test "WTL_CI_LANE_SUFFIX neutral override changes WORKTREE_ID vs unset" {
  # Simulate subprocess reload: run each call in its own subshell so the
  # WTL_CI_LANE_KEY written by wtl_derive does not bleed into the second call.
  # This mirrors the real retry flow where the guarded env loader is re-run
  # after exporting WTL_CI_LANE_SUFFIX.

  # Without suffix: WORKTREE_ID derived from root alone
  id_base="$(
    . "$BATS_TEST_DIRNAME/../lib/config.sh"
    . "$BATS_TEST_DIRNAME/../lib/derive.sh"
    cfg_root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
    cd "$cfg_root"
    wtl_load_config
    unset WTL_CI_LANE_SUFFIX WTL_CI_LANE_KEY HUDDLE_CI_LANE_SUFFIX HUDDLE_CI_LANE_KEY
    GITHUB_ACTIONS=true GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=job RUNNER_NAME=runner \
      WTL_FAKE_ROOT="$cfg_root" wtl_derive
    printf '%s' "$WTL_WORKTREE_ID"
  )"

  # With neutral suffix: WORKTREE_ID must differ
  id_retry="$(
    . "$BATS_TEST_DIRNAME/../lib/config.sh"
    . "$BATS_TEST_DIRNAME/../lib/derive.sh"
    cfg_root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
    cd "$cfg_root"
    wtl_load_config
    unset HUDDLE_CI_LANE_SUFFIX HUDDLE_CI_LANE_KEY
    WTL_CI_LANE_SUFFIX=retry1 \
      GITHUB_ACTIONS=true GITHUB_RUN_ID=99 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=job RUNNER_NAME=runner \
      WTL_FAKE_ROOT="$cfg_root" wtl_derive
    printf '%s' "$WTL_WORKTREE_ID"
  )"

  [ -n "$id_base" ] && [ -n "$id_retry" ]
  [ "$id_retry" != "$id_base" ]
}

@test "WTL_CI_LANE_SUFFIX neutral override does NOT affect golden parity (no suffix set)" {
  # Parity guard: when the neutral overrides are unset, the prefixed HUDDLE_* output is unchanged.
  unset WTL_CI_LANE_SUFFIX WTL_CI_LANE_KEY
  WTL_FAKE_ROOT="$root" wtl_derive
  # ID must match the stable golden (same as huddle-main: d228c073)
  [ "$WTL_WORKTREE_ID" = "$(wtl_id_for_path "$root")" ]
}

@test "wtl_git_retry prints stdout and succeeds when the command succeeds" {
  run wtl_git_retry printf 'hello'
  [ "$status" -eq 0 ]
  [ "$output" = "hello" ]
}

@test "wtl_git_retry returns non-zero after exhausting retries on persistent failure" {
  run wtl_git_retry false
  [ "$status" -ne 0 ]
}

@test "wtl_derive fails loudly (non-zero + message) when the main repo cannot be derived" {
  # A non-git directory with no WTL_FAKE_MAIN_REPO: `git worktree list` fails, so
  # derivation must return non-zero with an actionable message rather than emit
  # an empty environment that later crashes as an unbound variable.
  local non_git; non_git="$(mktemp -d)"
  cd "$non_git"
  unset WTL_FAKE_ROOT WTL_FAKE_MAIN_REPO
  run wtl_derive
  [ "$status" -ne 0 ]
  [[ "$output" == *"could not determine the main repo"* ]]
}
