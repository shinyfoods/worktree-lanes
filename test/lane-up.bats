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

# The shapes below were captured by running `docker compose port` against a compose project
# built to reproduce each case -- one published service and one exposed-only service.
# They are VERSION-DEPENDENT, so the version is recorded with them; two earlier rounds of
# this check shipped inverted because each encoded a guessed shape and the tests agreed
# with the guess, so every mutant died correctly while the check could never fire.
#
# Docker Compose v5.3.1:
#
#   published                 rc 0  "0.0.0.0:55000"
#   running, NOT published    rc 0  "invalid IP:0"        <-- the defect this check exists for
#   port not declared         rc 1  "no port 8025/tcp for container <name>: 1025/tcp, 1025/tcp"
#   stopped/unknown service   rc 1  "service \"unpub\" is not running"
#
# An earlier capture recorded `unpublished: exit 1, "no public port '3000' published"`. No
# compose version available here produces that for an unpublished binding; the predicate
# still treats it as a negative so an older runner stays covered.
#
# The predicate is therefore a positive shape test -- is the output a host:port with a
# non-zero port -- not a list of failure strings. Assert against BOTH shapes below.

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

# --- shapes measured on Docker Compose v5.3.1 (see the table above) ---

@test "compose_service_published reports NOT published for an exposed-but-unpublished port" {
  eval "$(extract_published_helpers)"
  # The defect shape: docker EXITS 0 and prints a non-empty string. Two prior versions of
  # this check treated exit-0-with-output as proof of publication and could never fire.
  docker() { printf 'invalid IP:0\n'; return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -ne 0 ]
}

@test "compose_service_published reports NOT published on a zero host port" {
  eval "$(extract_published_helpers)"
  docker() { printf '0.0.0.0:0\n'; return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -ne 0 ]
}

@test "compose_service_published reports NOT published on an unrecognised success shape" {
  eval "$(extract_published_helpers)"
  # An unparseable success is not evidence of a binding. Failing toward detection here is
  # what keeps the next unmodelled output shape from silently disabling the check.
  docker() { printf 'something we have never seen\n'; return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -ne 0 ]
}

@test "compose_service_published reports NOT published on a prose line ending in a port" {
  eval "$(extract_published_helpers)"
  # Guards the no-whitespace half of the shape test independently of the non-zero-port
  # half; without it, only the port clause is actually exercised.
  docker() { printf 'invalid IP:8025\n'; return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -ne 0 ]
}

@test "compose_service_published reports published for an IPv6 mapping" {
  eval "$(extract_published_helpers)"
  docker() { printf '[::]:55000\n'; return 0; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -eq 0 ]
}

@test "compose_service_published reports NOT published when the port is not declared" {
  eval "$(extract_published_helpers)"
  docker() { echo "no port 8025/tcp for container portprobe-pub-1: 1025/tcp, 1025/tcp"; return 1; }
  export -f docker 2>/dev/null || true
  COMPOSE_PROJECT_NAME=p COMPOSE_FILE=f run compose_service_published mailhog
  [ "$status" -ne 0 ]
}

# The forensics dump exists to make an intermittent defect self-documenting. Its whole value
# is that it runs unattended on a lane nobody is watching, so a probe that fails silently
# would leave a gap indistinguishable from "nothing to report".

extract_probe() {  # sources the probe helper alone
  local src="$BATS_TEST_DIRNAME/../libexec/lane-up"
  awk '/^  probe\(\) \{/,/^  \}/' "$src" | sed 's/^  //'
}

@test "probe labels a missing command as unavailable rather than printing nothing" {
  eval "$(extract_probe)"
  run probe "ephemeral range" definitely-not-a-real-command --flag
  [ "$status" -eq 0 ]
  [[ "$output" == *"ephemeral range: unavailable"* ]]
  [[ "$output" == *"not on PATH"* ]]
}

@test "probe labels a failing command as unavailable and keeps going" {
  eval "$(extract_probe)"
  run probe "dockerd bind errors" sh -c 'echo "permission denied"; exit 1'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dockerd bind errors: unavailable"* ]]
  [[ "$output" == *"permission denied"* ]]
}

@test "probe distinguishes an empty result from an unavailable one" {
  eval "$(extract_probe)"
  run probe "open sockets" sh -c 'true'
  [ "$status" -eq 0 ]
  [[ "$output" == *"open sockets: (empty)"* ]]
  [[ "$output" != *"unavailable"* ]]
}

@test "probe collapses a multi-line value onto one labelled line" {
  eval "$(extract_probe)"
  # journalctl's tail is genuinely multi-line; without the collapse its later lines appear
  # unlabelled in the dump and read as separate probes.
  run probe "dockerd bind errors" sh -c 'printf "line one\nline two\nline three\n"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"dockerd bind errors: line one line two line three"* ]]
  [ "$(printf '%s' "$output" | grep -c .)" -eq 1 ]
}

@test "the forensics dump is wired to the binding diagnosis only" {
  src="$BATS_TEST_DIRNAME/../libexec/lane-up"
  # Guarded by unpublished_service, so a plain timeout or a dead container does not emit
  # forensics for a binding that was never the problem.
  run grep -A2 'if \[ -n "$unpublished_service" \]; then' "$src"
  [ "$status" -eq 0 ]
  [[ "$output" == *"dump_binding_forensics"* ]]
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
