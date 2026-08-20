#!/usr/bin/env bats
# shellcheck shell=bash
load helper

@test "lane-up --detach sources the shared CI retry helper" {
  run bash -n "$BATS_TEST_DIRNAME/../libexec/lane-up"
  [ "$status" -eq 0 ]
  grep -q "ci_compose_retry.sh" "$BATS_TEST_DIRNAME/../libexec/lane-up"
  grep -q "wtl_compose_up_with_ci_retry" "$BATS_TEST_DIRNAME/../libexec/lane-up"
}

# The readiness probe used to poll a URL for its whole budget regardless of whether the
# container behind it still existed, so a crashed service and a slow one produced the
# same "Timed out waiting" output. These exercise the two helpers directly — grepping
# lane-up for the strings would pass on a version that never calls them.

extract_helpers() {            # sources the two probe helpers out of libexec/lane-up
  local src="$BATS_TEST_DIRNAME/../libexec/lane-up"
  awk '/^  compose_service_running\(\) \{/,/^  \}/' "$src" | sed 's/^  //'
}

@test "compose_service_running reports running when the service is in the listing" {
  eval "$(extract_helpers)"
  docker() { printf 'backend\nfrontend\nmailhog\n'; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_running mailhog
  [ "$status" -eq 0 ]
}

@test "compose_service_running reports NOT running when the service is absent" {
  eval "$(extract_helpers)"
  docker() { printf 'backend\nfrontend\n'; }
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_running mailhog
  [ "$status" -ne 0 ]
}

@test "compose_service_running fails safe when the listing is empty" {
  eval "$(extract_helpers)"
  docker() { printf ''; }
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_running mailhog
  [ "$status" -eq 0 ]
}

@test "compose_service_running fails safe when docker errors" {
  eval "$(extract_helpers)"
  docker() { return 1; }
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_running mailhog
  [ "$status" -eq 0 ]
}

@test "lane-up aborts the readiness wait instead of reporting a timeout" {
  grep -q 'stopped_service="\$probe_service"' "$BATS_TEST_DIRNAME/../libexec/lane-up"
  grep -q "is not running — it exited or never started" "$BATS_TEST_DIRNAME/../libexec/lane-up"
}
