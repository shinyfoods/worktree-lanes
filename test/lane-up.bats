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

# A running container whose ports mapping was never applied reads as a slow one until
# the budget expires. These exercise the helper directly for the same reason as above —
# grepping lane-up for the message would pass on a version that never calls it.

extract_published_helpers() {  # sources container_port_for_service + compose_service_published
  local src="$BATS_TEST_DIRNAME/../libexec/lane-up"
  {
    awk '/^  container_port_for_service\(\) \{/,/^  \}/' "$src"
    awk '/^  compose_service_published\(\) \{/,/^  \}/' "$src"
  } | sed 's/^  //'
}

# The shapes below were captured from a real docker, not assumed. A previous version of
# this suite asserted that a missing binding shows up as "exit 0, empty output"; docker
# never produces that, so the check shipped inverted and the tests passed anyway.
#
#   published:   exit 0, "0.0.0.0:43073"
#   unpublished: exit 1, "no public port '3000' published for <container>"
#   not running: exit 1, "service \"sidekiq\" is not running"

@test "compose_service_published reports published when docker returns a mapping" {
  eval "$(extract_published_helpers)"
  docker() { printf '0.0.0.0:54594\n'; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published frontend
  [ "$status" -eq 0 ]
}

@test "compose_service_published reports NOT published on docker's real missing-binding output" {
  eval "$(extract_published_helpers)"
  docker() { echo "no public port '5173' published for huddle-ci-x-frontend-1"; return 1; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published frontend
  [ "$status" -ne 0 ]
}

@test "compose_service_published fails safe when the service is not running" {
  eval "$(extract_published_helpers)"
  docker() { echo 'service "frontend" is not running'; return 1; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published frontend
  [ "$status" -eq 0 ]          # liveness owns this case; do not double-report it
}

@test "compose_service_published fails safe when docker is unavailable" {
  eval "$(extract_published_helpers)"
  docker() { echo "Cannot connect to the Docker daemon"; return 1; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published frontend
  [ "$status" -eq 0 ]
}

@test "compose_service_published treats empty-on-success as missing, not published" {
  eval "$(extract_published_helpers)"
  docker() { return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published frontend
  [ "$status" -ne 0 ]
}

@test "compose_service_published skips a service with no known container port" {
  eval "$(extract_published_helpers)"
  docker() { return 0; }        # would report unpublished if the service were checked
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published sidekiq
  [ "$status" -eq 0 ]
}

@test "the readiness wait breaks on a missing binding and says so distinctly" {
  grep -q 'unpublished_service="\$probe_service"' "$BATS_TEST_DIRNAME/../libexec/lane-up"
  grep -q "has no published host port for container port" "$BATS_TEST_DIRNAME/../libexec/lane-up"
}

@test "liveness is checked before the binding, so a dead container is not misreported" {
  live=$(grep -n 'stopped_service="\$probe_service"' "$BATS_TEST_DIRNAME/../libexec/lane-up" | head -1 | cut -d: -f1)
  bind=$(grep -n 'unpublished_service="\$probe_service"' "$BATS_TEST_DIRNAME/../libexec/lane-up" | head -1 | cut -d: -f1)
  [ -n "$live" ] && [ -n "$bind" ] && [ "$live" -lt "$bind" ]
}
