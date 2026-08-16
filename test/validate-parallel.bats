#!/usr/bin/env bats
# shellcheck shell=bash
load helper

# Structural tests for libexec/validate-parallel: confirm it references the
# parameterized vars rather than hard-coded Huddle paths.

VALIDATE_PARALLEL="$BATS_TEST_DIRNAME/../libexec/validate-parallel"

setup() {
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  FAKE_BIN="$(mktemp -d)"
  export FAKE_BIN
  export PATH="$FAKE_BIN:$BATS_TEST_DIRNAME/../bin:$PATH"
}

teardown() {
  rm -rf "$FAKE_BIN"
  rm -rf "${WTL_TEST_TMP:-}"
}

write_shared_env_failure_fixture() {
  cat > "$FAKE_BIN/worktree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = env ] && [ "${2:-}" = --shell ] && [ "${3:-}" = --infra-mode=shared ]; then
  printf '%s\n' 'shared env fixture failed' >&2
  exit 37
fi
printf 'unexpected worktree invocation: %s\n' "$*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/worktree"
}

write_shared_env_absent_fixture() {
  cat > "$FAKE_BIN/worktree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = env ] && [ "${2:-}" = --shell ] && [ "${3:-}" = --infra-mode=shared ]; then
  printf '%s\n' \
    'export WTL_SHARED_INFRA_PROJECT_NAME=fixture-shared' \
    'export COMPOSE_FILE=/tmp/fixture-compose.yml'
  exit 0
fi
printf 'unexpected worktree invocation: %s\n' "$*" >&2
exit 99
EOF
  chmod +x "$FAKE_BIN/worktree"

  cat > "$FAKE_BIN/docker" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = compose ] || exit 99
exit 0
EOF
  chmod +x "$FAKE_BIN/docker"
}

assert_shared_env_probe_failure() {
  local script="$1"
  local root output status

  root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
  if output="$(cd "$root" && env WTL_ROOT="$BATS_TEST_DIRNAME/.." \
    bash "$script" --quick 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -ne 125 ]; then
    echo "named assertion failed: shared env probe remains a hard failure (got $status)"
    return 1
  fi
  case "$output" in
    *"shared env fixture failed"*) ;;
    *) echo "named assertion failed: shared env fixture stderr was preserved"; return 1 ;;
  esac
  case "$output" in
    *"shared-mode environment load failed"*"status 37"*) ;;
    *) echo "named assertion failed: shared env loader failure was named"; return 1 ;;
  esac
  case "$output" in
    *"refusing to continue or tear down shared infrastructure"*) ;;
    *) echo "named assertion failed: shared probe refused continuation and teardown"; return 1 ;;
  esac
  case "$output" in
    *"Creating temp worktrees..."*) echo "named assertion failed: validation continued"; return 1 ;;
  esac
  case "$output" in
    *"shared-infra-down"*) echo "named assertion failed: shared cleanup ran"; return 1 ;;
  esac
}

@test "validate-parallel references \${WTL_VALIDATE_SMOKE_SPEC} not hard-coded spec path" {
  # Must contain the variable reference
  grep -q '\${WTL_VALIDATE_SMOKE_SPEC' "$VALIDATE_PARALLEL"
  # Must NOT contain the bare hard-coded path in a worktree test-backend call
  run grep 'worktree test-backend spec/requests/api/v1/health_spec.rb' "$VALIDATE_PARALLEL"
  [ "$status" -ne 0 ]
}

@test "validate-parallel gates doctor step on WTL_VALIDATE_DOCTOR" {
  grep -q 'WTL_VALIDATE_DOCTOR' "$VALIDATE_PARALLEL"
  grep -q 'Skipping doctor step' "$VALIDATE_PARALLEL"
}

@test "a shared env-loader failure is a hard named failure before cleanup" {
  write_shared_env_failure_fixture

  run assert_shared_env_probe_failure "$VALIDATE_PARALLEL"
  [ "$status" -eq 0 ]
}

@test "an absent shared compose project is distinct from an env-loader failure" {
  write_shared_env_absent_fixture
  root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"

  run bash -c 'cd "$1" && env WTL_ROOT="$2" bash "$3" --quick' \
    bash "$root" "$BATS_TEST_DIRNAME/.." "$VALIDATE_PARALLEL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"Refusing to run validation from a dirty worktree"* ]]
  [[ "$output" != *"shared-mode environment load failed"* ]]
  [[ "$output" != *"shared infrastructure probe failed"* ]]
}

@test "removing the hard shared-probe exit fails the named regression assertion" {
  write_shared_env_failure_fixture
  mutant="$BATS_TEST_TMPDIR/validate-parallel-mutant"
  sed 's/    exit "\$shared_probe_status"/    exit 0/' \
    "$VALIDATE_PARALLEL" > "$mutant"

  run assert_shared_env_probe_failure "$mutant"
  [ "$status" -ne 0 ]
  [[ "$output" == *"named assertion failed: shared env probe remains a hard failure"* ]]
}
