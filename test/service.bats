#!/usr/bin/env bats
# shellcheck shell=bash
load helper

setup() {
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  export PATH="$BATS_TEST_DIRNAME/../bin:$PATH"
}

setup_root_with_fixture() {
  local fixture="$1"
  local root
  root="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/${fixture}")"
  cd "$root"
}

make_fake_run_backend_docker() {
  local fake_bin
  fake_bin="$(mktemp -d)"
  cat > "$fake_bin/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

if [ "${1:-}" = "compose" ]; then
  shift
  for arg in "$@"; do
    case "$arg" in
      up)
        exit 0
        ;;
      run)
        echo "fake backend command failed" >&2
        exit "${WTL_FAKE_RUN_EXIT:-137}"
        ;;
      down)
        exit 0
        ;;
    esac
  done
  exit 0
fi

exit 0
FAKE_DOCKER
  chmod +x "$fake_bin/docker"
  export PATH="$fake_bin:$PATH"
  FAKE_RUN_BACKEND_BIN="$fake_bin"
}

make_fake_run_backend_retry() {
  local fake_bin
  fake_bin="$(mktemp -d)"
  printf '0\n' > "$fake_bin/env-calls"
  printf '0\n' > "$fake_bin/compose-up-attempts"
  cat > "$fake_bin/worktree" <<'FAKE_WORKTREE'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env)
    calls=$(( $(cat "$FAKE_RUN_BACKEND_BIN/env-calls") + 1 ))
    printf '%s\n' "$calls" > "$FAKE_RUN_BACKEND_BIN/env-calls"
    if [ "$calls" -eq 1 ]; then
      printf '%s\n' \
        'export COMPOSE_PROJECT_NAME=wtl-run-backend' \
        'export COMPOSE_FILE=/tmp/fake-compose.yml' \
        'export WTL_INFRA_MODE=isolated' \
        'export WTL_DEV_DB_NAME=dev_db' \
        'export WTL_REDIS_DB_DEV=1' \
        'export WTL_REDIS_DB_SIDEKIQ=2' \
        'export WTL_DB_USER=fixture' \
        'export WTL_DB_PASSWORD=fixture-password'
    else
      echo "retry env derivation failed" >&2
      exit 31
    fi
    ;;
  lane-down) ;;
  *) echo "unexpected worktree invocation: $*" >&2; exit 99 ;;
esac
FAKE_WORKTREE
  cat > "$fake_bin/docker" <<'FAKE_DOCKER_RETRY'
#!/usr/bin/env bash
set -euo pipefail
if [ "${1:-}" = compose ]; then
  shift
  for arg in "$@"; do
    case "$arg" in
      up)
        attempts=$(( $(cat "$FAKE_RUN_BACKEND_BIN/compose-up-attempts") + 1 ))
        printf '%s\n' "$attempts" > "$FAKE_RUN_BACKEND_BIN/compose-up-attempts"
        if [ "$attempts" -eq 1 ]; then
          echo "port is already allocated" >&2
          exit 1
        fi
        exit 0
        ;;
      run)
        echo "backend command ran" >> "$FAKE_RUN_BACKEND_BIN/docker-events"
        exit 0
        ;;
      down) exit 0 ;;
    esac
  done
fi
exit 0
FAKE_DOCKER_RETRY
  chmod +x "$fake_bin/worktree" "$fake_bin/docker"
  export PATH="$fake_bin:$PATH"
  export FAKE_RUN_BACKEND_BIN="$fake_bin"
}

teardown() {
  if [ -n "${FAKE_RUN_BACKEND_BIN:-}" ]; then rm -rf "$FAKE_RUN_BACKEND_BIN"; fi
}

@test "frontend scripts exit 0 with clear message when WTL_HAS_FRONTEND=0" {
  # Use a config without frontend
  setup_root_with_fixture "locals.worktree.config"
  # Override has_frontend to 0 for this test by creating a minimal config
  local tmpdir
  tmpdir="$(mktemp -d)"
  git -C "$tmpdir" init -q
  cat > "$tmpdir/worktree.config" <<'EOF'
WTL_PROJECT=nofrontend
WTL_ENV_PREFIX=NOFRONTEND
WTL_MAIN_BACKEND_PORT=4001
WTL_MAIN_FRONTEND_PORT=5001
WTL_MAIN_POSTGRES_PORT=5501
WTL_MAIN_REDIS_PORT=6501
WTL_HAS_FRONTEND=0
WTL_HAS_SIDEKIQ=0
EOF
  cd "$tmpdir"
  run bash "$BATS_TEST_DIRNAME/../libexec/up-frontend"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "sidekiq scripts exit 0 with clear message when WTL_HAS_SIDEKIQ=0" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  git -C "$tmpdir" init -q
  cat > "$tmpdir/worktree.config" <<'EOF'
WTL_PROJECT=nosidekiq
WTL_ENV_PREFIX=NOSIDEKIQ
WTL_MAIN_BACKEND_PORT=4002
WTL_MAIN_FRONTEND_PORT=5002
WTL_MAIN_POSTGRES_PORT=5502
WTL_MAIN_REDIS_PORT=6502
WTL_HAS_FRONTEND=0
WTL_HAS_SIDEKIQ=0
EOF
  cd "$tmpdir"
  run bash "$BATS_TEST_DIRNAME/../libexec/up-sidekiq"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "stop-frontend exits 0 with clear message when WTL_HAS_FRONTEND=0" {
  local tmpdir
  tmpdir="$(mktemp -d)"
  git -C "$tmpdir" init -q
  cat > "$tmpdir/worktree.config" <<'EOF'
WTL_PROJECT=nofrontend2
WTL_ENV_PREFIX=NOFRONTEND2
WTL_MAIN_BACKEND_PORT=4003
WTL_MAIN_FRONTEND_PORT=5003
WTL_MAIN_POSTGRES_PORT=5503
WTL_MAIN_REDIS_PORT=6503
WTL_HAS_FRONTEND=0
WTL_HAS_SIDEKIQ=0
EOF
  cd "$tmpdir"
  run bash "$BATS_TEST_DIRNAME/../libexec/stop-frontend"
  [ "$status" -eq 0 ]
  [[ "$output" == *"not configured"* ]]
}

@test "run-backend classifies child exit 137 as infrastructure/resource failure and preserves status" {
  setup_root_with_fixture "locals.worktree.config"
  make_fake_run_backend_docker

  run env GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=backend bash "$BATS_TEST_DIRNAME/../libexec/run-backend" swagger:coverage
  [ "$status" -eq 137 ]
  [[ "$output" == *"Infrastructure/resource diagnostic"* ]]
  [[ "$output" == *"exited 137"* ]]
}

@test "run-backend does not classify a non-137 child failure as resource exhaustion" {
  setup_root_with_fixture "locals.worktree.config"
  make_fake_run_backend_docker

  run env GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=backend WTL_FAKE_RUN_EXIT=1 bash "$BATS_TEST_DIRNAME/../libexec/run-backend" swagger:coverage
  [ "$status" -eq 1 ]
  [[ "$output" != *"Infrastructure/resource diagnostic"* ]]
}

@test "run-backend reports an initial env failure before invoking Docker" {
  setup_root_with_fixture "locals.worktree.config"
  make_fake_run_backend_docker
  cat > "$FAKE_RUN_BACKEND_BIN/worktree" <<'EOF'
#!/usr/bin/env bash
echo "initial env derivation failed" >&2
exit 23
EOF
  chmod +x "$FAKE_RUN_BACKEND_BIN/worktree"

  run env GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=backend \
    bash "$BATS_TEST_DIRNAME/../libexec/run-backend" swagger:coverage
  [ "$status" -eq 23 ]
  [[ "$output" == *"initial env derivation failed"* ]]
  [[ "$output" == *"worktree env --shell failed (status 23)"* ]]
  [[ "$output" != *"fake backend command failed"* ]]
}

@test "run-backend retry env failure stops before a second compose startup" {
  setup_root_with_fixture "locals.worktree.config"
  make_fake_run_backend_retry

  run env GITHUB_ACTIONS=true GITHUB_RUN_ID=1 GITHUB_RUN_ATTEMPT=1 GITHUB_JOB=backend \
    bash "$BATS_TEST_DIRNAME/../libexec/run-backend" swagger:coverage
  [ "$status" -eq 31 ]
  [ "$(cat "$FAKE_RUN_BACKEND_BIN/env-calls")" -eq 2 ]
  [ "$(cat "$FAKE_RUN_BACKEND_BIN/compose-up-attempts")" -eq 1 ]
  [[ "$output" == *"retry env derivation failed"* ]]
  [[ "$output" == *"worktree env --shell failed (status 31)"* ]]
  [[ ! -e "$FAKE_RUN_BACKEND_BIN/docker-events" ]]
}
