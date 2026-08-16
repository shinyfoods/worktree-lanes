#!/usr/bin/env bats
# shellcheck shell=bash
load helper

setup() {
  TEST_ROOT="$(setup_repo_root "$BATS_TEST_DIRNAME/fixtures/locals.worktree.config")"
  export PATH="$BATS_TEST_DIRNAME/../bin:$PATH"
  cd "$TEST_ROOT"
  # We need the worktree command to resolve WTL_ROOT to the worktree-lanes root
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  unset GITHUB_ACTIONS WTL_INFRA_MODE
}

teardown() {
  if [ -n "${FAKE_BIN:-}" ]; then rm -rf "$FAKE_BIN"; fi
  if [ -n "${EVENTS_FILE:-}" ]; then rm -f "$EVENTS_FILE"; fi
  if [ -n "${HEALTH_FILE:-}" ]; then rm -f "$HEALTH_FILE"; fi
  if [ -n "${HEALTH_INDEX_FILE:-}" ]; then rm -f "$HEALTH_INDEX_FILE"; fi
}

# The fake Docker command models Compose startup, health transitions, and the
# two backend commands. Its event log makes the readiness-to-db:prepare order
# observable without requiring a Docker daemon or a Rails image.
make_fake_docker() {
  EVENTS_FILE="$(mktemp)"
  HEALTH_FILE="$(mktemp)"
  HEALTH_INDEX_FILE="$(mktemp)"
  printf '0\n' > "$HEALTH_INDEX_FILE"
  printf '%s\n' "$@" > "$HEALTH_FILE"
  FAKE_BIN="$(mktemp -d)"
  cat > "$FAKE_BIN/docker" <<'FAKE_DOCKER'
#!/usr/bin/env bash
set -euo pipefail

record_event() {
  printf '%s\n' "$1" >> "$WTL_FAKE_DOCKER_EVENTS"
}

if [ "${1:-}" = "inspect" ]; then
  next_index=$(( $(cat "$WTL_FAKE_DOCKER_HEALTH_INDEX") + 1 ))
  printf '%s\n' "$next_index" > "$WTL_FAKE_DOCKER_HEALTH_INDEX"
  health="$(sed -n "${next_index}p" "$WTL_FAKE_DOCKER_HEALTH" || true)"
  if [ -z "$health" ]; then
    health="$(tail -n 1 "$WTL_FAKE_DOCKER_HEALTH")"
  fi
  record_event "inspect:$health"
  if [[ "$*" == *"|healthcheck"* ]]; then
    case "$health" in
      no-healthcheck) printf 'no-healthcheck|running\n' ;;
      *) printf '%s|running\n' "$health" ;;
    esac
  else
    printf '%s\n' "$health"
  fi
  exit 0
fi

if [ "${1:-}" = "compose" ]; then
  shift
  subcommand=""
  has_quiet=0
  last_arg=""
  compose_project=""
  expect_project=0
  for arg in "$@"; do
    last_arg="$arg"
    if [ "$expect_project" -eq 1 ]; then
      compose_project="$arg"
      expect_project=0
    fi
    [ "$arg" = "-p" ] && expect_project=1
    [ "$arg" = "-q" ] && has_quiet=1
    case "$arg" in
      up|ps|run|logs|down) subcommand="$arg" ;;
    esac
  done

  case "$subcommand" in
    up)
      record_event "compose-up:$compose_project"
      ;;
    ps)
      if [ "$has_quiet" -eq 1 ]; then
        record_event "compose-ps:$compose_project:$last_arg"
        printf 'fake-postgres-container\n'
      else
        printf 'postgres status: running (fake)\n'
      fi
      ;;
    logs)
      printf 'fake postgres diagnostics: accepting connections soon\n'
      ;;
    run)
      for arg in "$@"; do
        case "$arg" in
          db:prepare) record_event db:prepare ;;
          rspec) record_event rspec ;;
        esac
      done
      ;;
    down)
      ;;
  esac
  exit 0
fi

exit 0
FAKE_DOCKER
  chmod +x "$FAKE_BIN/docker"
  cat > "$FAKE_BIN/curl" <<'FAKE_CURL'
#!/usr/bin/env bash
exit 0
FAKE_CURL
  chmod +x "$FAKE_BIN/curl"
  export WTL_FAKE_DOCKER_EVENTS="$EVENTS_FILE"
  export WTL_FAKE_DOCKER_HEALTH="$HEALTH_FILE"
  export WTL_FAKE_DOCKER_HEALTH_INDEX="$HEALTH_INDEX_FILE"
  export PATH="$FAKE_BIN:$PATH"
}

@test "test-backend dry-run prints DATABASE_URL containing _test_ and db:prepare" {
  run env WTL_DRYRUN=1 bash "$BATS_TEST_DIRNAME/../libexec/test-backend"
  [ "$status" -eq 0 ]
  [[ "$output" == *"_test_"* ]]
  [[ "$output" == *"db:prepare"* ]]
}

@test "test-backend readiness regression guard blocks db:prepare until Postgres is healthy" {
  make_fake_docker starting unhealthy healthy

  run env WTL_POSTGRES_READINESS_TIMEOUT=5 bash "$BATS_TEST_DIRNAME/../libexec/test-backend"
  [ "$status" -eq 0 ]
  grep -q '^inspect:starting$' "$EVENTS_FILE"
  grep -q '^inspect:unhealthy$' "$EVENTS_FILE"
  grep -q '^inspect:healthy$' "$EVENTS_FILE"
  grep -q '^db:prepare$' "$EVENTS_FILE"

  healthy_line="$(grep -n '^inspect:healthy$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  prepare_line="$(grep -n '^db:prepare$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  [ -n "$healthy_line" ]
  [ -n "$prepare_line" ]
  [ "$healthy_line" -lt "$prepare_line" ]
}

@test "test-backend healthy Postgres reaches db:prepare and RSpec" {
  make_fake_docker healthy

  run env WTL_POSTGRES_READINESS_TIMEOUT=3 bash "$BATS_TEST_DIRNAME/../libexec/test-backend"
  [ "$status" -eq 0 ]
  grep -q '^inspect:healthy$' "$EVENTS_FILE"
  grep -q '^db:prepare$' "$EVENTS_FILE"
  grep -q '^rspec$' "$EVENTS_FILE"

  healthy_line="$(grep -n '^inspect:healthy$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  prepare_line="$(grep -n '^db:prepare$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  rspec_line="$(grep -n '^rspec$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  [ "$healthy_line" -lt "$prepare_line" ]
  [ "$prepare_line" -lt "$rspec_line" ]
}

@test "test-backend shared mode checks the shared Postgres project before db:prepare" {
  printf 'LOCALS_INFRA_MODE=shared\n' >> worktree.config
  make_fake_docker healthy

  run env WTL_POSTGRES_READINESS_TIMEOUT=3 bash "$BATS_TEST_DIRNAME/../libexec/test-backend"
  [ "$status" -eq 0 ]
  [ "$(grep -c '^compose-ps:locals-shared-infra:postgres$' "$EVENTS_FILE")" -ge 2 ]

  healthy_line="$(grep -n '^inspect:healthy$' "$EVENTS_FILE" | tail -1 | cut -d: -f1 || true)"
  prepare_line="$(grep -n '^db:prepare$' "$EVENTS_FILE" | head -1 | cut -d: -f1 || true)"
  [ "$healthy_line" -lt "$prepare_line" ]
}

@test "test-backend readiness timeout names Postgres service and prints diagnostics" {
  make_fake_docker unhealthy

  run env WTL_POSTGRES_READINESS_TIMEOUT=2 bash "$BATS_TEST_DIRNAME/../libexec/test-backend"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Postgres readiness gate timed out after 2s"* ]]
  [[ "$output" == *"service 'postgres'"* ]]
  [[ "$output" == *"Recent logs for service 'postgres'"* ]]
  [[ "$output" == *"fake postgres diagnostics"* ]]
  ! grep -q '^db:prepare$' "$EVENTS_FILE"
}
