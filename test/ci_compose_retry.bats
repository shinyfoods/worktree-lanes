#!/usr/bin/env bats
# shellcheck shell=bash
load helper

setup() {
  TEST_ROOT="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config")"
  export PATH="$BATS_TEST_DIRNAME/../bin:$PATH"
  cd "$TEST_ROOT"
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  # shellcheck source=../lib/ci_compose_retry.sh
  . "$WTL_ROOT/lib/ci_compose_retry.sh"
  COMPOSE_PROJECT_NAME="wtl-test-project"
  COMPOSE_FILE="$TEST_ROOT/docker-compose.yml"
  touch "$COMPOSE_FILE"
  unset GITHUB_ACTIONS GITHUB_ENV GITHUB_STEP_SUMMARY WTL_CI_LANE_SUFFIX
}

teardown() {
  [ -n "${FAKE_BIN:-}" ] && rm -rf "$FAKE_BIN"
  [ -n "${GITHUB_ENV:-}" ] && rm -f "$GITHUB_ENV"
  [ -n "${GITHUB_STEP_SUMMARY:-}" ] && rm -f "$GITHUB_STEP_SUMMARY"
  [ -n "${ATTEMPTS_FILE:-}" ] && rm -f "$ATTEMPTS_FILE"
  true
}

# Writes a fake `docker` onto PATH. `$1` is how many `compose ... up` calls
# should fail with a retryable port-bind message before succeeding (0 = always
# succeeds). `compose ... down` always succeeds.
make_fake_docker() {
  local fail_count="$1"
  ATTEMPTS_FILE="$(mktemp)"
  echo 0 > "$ATTEMPTS_FILE"
  FAKE_BIN="$(mktemp -d)"
  cat > "$FAKE_BIN/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "compose" ]; then
  shift
  for arg in "\$@"; do
    if [ "\$arg" = "up" ]; then
      n=\$(( \$(cat "$ATTEMPTS_FILE") + 1 ))
      echo "\$n" > "$ATTEMPTS_FILE"
      if [ "\$n" -le "$fail_count" ]; then
        echo "Error response from daemon: driver failed programming external connectivity on endpoint x: Bind for 0.0.0.0:5432 failed: port is already allocated" >&2
        exit 1
      fi
      exit 0
    fi
    if [ "\$arg" = "down" ]; then
      exit 0
    fi
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/docker"
  export PATH="$FAKE_BIN:$PATH"
}

# Writes a fake `docker` that always fails with a NON-retryable error.
make_fake_docker_nonretryable() {
  ATTEMPTS_FILE="$(mktemp)"
  echo 0 > "$ATTEMPTS_FILE"
  FAKE_BIN="$(mktemp -d)"
  cat > "$FAKE_BIN/docker" <<EOF
#!/usr/bin/env bash
if [ "\$1" = "compose" ]; then
  shift
  for arg in "\$@"; do
    if [ "\$arg" = "up" ]; then
      n=\$(( \$(cat "$ATTEMPTS_FILE") + 1 ))
      echo "\$n" > "$ATTEMPTS_FILE"
      echo "Error: pull access denied for huddle/backend, repository does not exist" >&2
      exit 1
    fi
    if [ "\$arg" = "down" ]; then
      exit 0
    fi
  done
  exit 0
fi
exit 0
EOF
  chmod +x "$FAKE_BIN/docker"
  export PATH="$FAKE_BIN:$PATH"
}

@test "wtl_is_retryable_compose_error matches the known port-bind signature" {
  logfile="$(mktemp)"
  echo "Bind for 0.0.0.0:5432 failed: port is already allocated" > "$logfile"
  run wtl_is_retryable_compose_error "$logfile"
  [ "$status" -eq 0 ]
  rm -f "$logfile"
}

@test "wtl_is_retryable_compose_error rejects an unrelated error" {
  logfile="$(mktemp)"
  echo "Error: pull access denied for huddle/backend" > "$logfile"
  run wtl_is_retryable_compose_error "$logfile"
  [ "$status" -eq 1 ]
  rm -f "$logfile"
}

@test "outside CI, a failing compose up is not retried" {
  make_fake_docker 1
  unset GITHUB_ACTIONS
  run wtl_compose_up_with_ci_retry "lane-up" -- backend
  [ "$status" -ne 0 ]
  [ "$(cat "$ATTEMPTS_FILE")" -eq 1 ]
}

@test "under CI, retries once on a retryable error then succeeds" {
  make_fake_docker 1
  export GITHUB_ACTIONS=true
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV
  GITHUB_STEP_SUMMARY="$(mktemp)"; export GITHUB_STEP_SUMMARY
  run wtl_compose_up_with_ci_retry "lane-up" -- backend
  [ "$status" -eq 0 ]
  [ "$(cat "$ATTEMPTS_FILE")" -eq 2 ]
  grep -q "WTL_CI_LANE_SUFFIX=lane-up-r1" "$GITHUB_ENV"
  grep -q "CI lane startup retry 1/3" "$GITHUB_STEP_SUMMARY"
}

@test "under CI, a non-retryable error fails fast without retrying" {
  make_fake_docker_nonretryable
  export GITHUB_ACTIONS=true
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV
  run wtl_compose_up_with_ci_retry "lane-up" -- backend
  [ "$status" -ne 0 ]
  [ "$(cat "$ATTEMPTS_FILE")" -eq 1 ]
  ! grep -q "WTL_CI_LANE_SUFFIX" "$GITHUB_ENV"
}

@test "under CI, exhausts after 3 attempts and returns failure" {
  make_fake_docker 99
  export GITHUB_ACTIONS=true
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV
  GITHUB_STEP_SUMMARY="$(mktemp)"; export GITHUB_STEP_SUMMARY
  run wtl_compose_up_with_ci_retry "lane-up" -- backend
  [ "$status" -ne 0 ]
  [ "$(cat "$ATTEMPTS_FILE")" -eq 3 ]
  ! grep -q "WTL_CI_LANE_SUFFIX" "$GITHUB_ENV"
}

@test "under CI, env derivation failure on a retry stops before the next compose attempt" {
  make_fake_docker 1
  cat > "$FAKE_BIN/worktree" <<'EOF'
#!/usr/bin/env bash
echo "retry env derivation failed" >&2
exit 29
EOF
  chmod +x "$FAKE_BIN/worktree"
  export GITHUB_ACTIONS=true
  export WTL_ENV_STATUS=29
  GITHUB_ENV="$(mktemp)"; export GITHUB_ENV
  run wtl_compose_up_with_ci_retry "lane-up" -- backend
  [ "$status" -eq 29 ]
  [ "$(cat "$ATTEMPTS_FILE")" -eq 1 ]
  [[ "$output" == *"retry env derivation failed"* ]]
  [[ "$output" == *"worktree env --shell failed (status 29)"* ]]
  ! grep -q "WTL_CI_LANE_SUFFIX" "$GITHUB_ENV"
}
