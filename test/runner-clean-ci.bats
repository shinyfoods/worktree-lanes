#!/usr/bin/env bats
# The janitor's age predicate: the floor below which nothing is touched, and the
# ceiling above which a leaked lane is reaped whatever it has running.
#
# Every case here stubs `docker` through PATH, so no case needs a daemon and none
# can reach one. The stub is what makes the load-bearing case reachable at all:
# the defect the floor exists for is a compose project observed in the moment
# between `Created` and `Started`, which cannot be produced on demand against a
# real daemon.
#
# THE STUB EMITS DOCKER'S REAL TIMESTAMP FORMAT, abbreviation included. It did
# not, once, and that omission cost more than the code it tested was worth: Go's
# `{{.CreatedAt}}` layout is `2006-01-02 15:04:05 -0700 MST`, GNU date rejects
# the whole string on that trailing `MST`, and so every age check on the Linux
# runner answered "no" for months while six green cases said otherwise. A stub
# that is easier to parse than the interface it stands for is not a stub.

load helper

setup() {
  WTL_TEST_TMP="$(mktemp -d)"
  STUB_BIN="$WTL_TEST_TMP/bin"
  mkdir -p "$STUB_BIN"
  cp "$BATS_TEST_DIRNAME/fixtures/huddle.worktree.config" "$WTL_TEST_TMP/worktree.config" 2>/dev/null || \
    printf 'WTL_PROJECT=huddle\nWTL_ENV_PREFIX=HUDDLE\n' > "$WTL_TEST_TMP/worktree.config"
  printf 'services:\n  backend: {}\n' > "$WTL_TEST_TMP/docker-compose.yml"
}

teardown() {
  rm -rf "$WTL_TEST_TMP"
}

# $1 = seconds ago the container was created, $2 = how many are RUNNING,
# $3 = extra compose projects on the host, space separated (default none).
write_docker_stub() {
  local age_seconds="$1" running="$2" others="${3:-}"
  cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
# Docker's own layout, which is what the janitor has to survive: date, time,
# numeric offset, THEN a zone abbreviation.
created="\$(date -u -d "@\$(( \$(date +%s) - $age_seconds ))" '+%Y-%m-%d %H:%M:%S +0000 UTC' 2>/dev/null || date -u -r \$(( \$(date +%s) - $age_seconds )) '+%Y-%m-%d %H:%M:%S +0000 UTC')"
case "\$*" in
  *"ps -a"*"{{.CreatedAt}}"*) echo "\$created" ;;
  *"ps -a"*"-q"*)             echo "container-1" ;;
  *"ps --filter"*"-q"*)       [ "$running" -gt 0 ] && echo "container-1" || true ;;
  *"ps -a --format"*)         echo "huddle-ci-abc123"; for p in $others; do echo "\$p"; done ;;
  *"volume ls"*)              true ;;
  *"network ls"*)             true ;;
  *"compose"*)                echo "CLEANED-BY-STUB" ;;
  *) true ;;
esac
STUB
  chmod +x "$STUB_BIN/docker"
}

# A host whose containers report a timestamp the janitor cannot read at all.
write_unparseable_docker_stub() {
  cat > "$STUB_BIN/docker" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  *"ps -a"*"{{.CreatedAt}}"*) echo "not-a-timestamp" ;;
  *"ps -a"*"-q"*)             echo "container-1" ;;
  *"ps --filter"*"-q"*)       echo "container-1" ;;
  *"ps -a --format"*)         echo "huddle-ci-abc123" ;;
  *"volume ls"*)              true ;;
  *"network ls"*)             true ;;
  *"compose"*)                echo "CLEANED-BY-STUB" ;;
  *) true ;;
esac
STUB
  chmod +x "$STUB_BIN/docker"
}

run_janitor() {
  cd "$WTL_TEST_TMP" || return 1
  # WTL_FAKE_MAIN_REPO skips `git worktree list`, so no case needs a git
  # repository — the same escape hatch db-lifecycle.bats uses.
  PATH="$STUB_BIN:$PATH" WTL_FAKE_MAIN_REPO="$WTL_TEST_TMP" \
    run "$BATS_TEST_DIRNAME/../libexec/runner-clean-ci" "$@"
}

@test "a seconds-old project with nothing running is left alone" {
  # THE case. A `compose run` lane holds one container, and it reports as not
  # running for the moment between Created and Started. Before the floor, a
  # sibling job's sweep deleted its network right there.
  write_docker_stub 5 0
  run_janitor --apply --max-age=30
  [ "$status" -eq 0 ]
  [[ "$output" == *"YOUNG"* ]]
  [[ "$output" != *"CLEAN huddle-ci-abc123"* ]]
}

@test "an old project with nothing running is still cleaned" {
  # The floor must not turn the janitor off. Leaked projects are what it is for.
  write_docker_stub 3600 0
  run_janitor --apply --max-age=30
  [ "$status" -eq 0 ]
  [[ "$output" == *"CLEAN huddle-ci-abc123"* ]]
  [[ "$output" != *"YOUNG"* ]]
}

@test "a young project is left alone even when something IS running" {
  write_docker_stub 5 1
  run_janitor --apply --max-age=1
  [ "$status" -eq 0 ]
  [[ "$output" == *"YOUNG"* ]]
}

@test "an explicit --include-running overrides the floor, because it is deliberate" {
  write_docker_stub 5 1
  run_janitor --apply --include-running
  [ "$status" -eq 0 ]
  [[ "$output" != *"YOUNG"* ]]
}

@test "--min-age=0 disables the floor" {
  write_docker_stub 5 0
  run_janitor --apply --min-age=0
  [ "$status" -eq 0 ]
  [[ "$output" != *"YOUNG"* ]]
}

@test "the dry run says what it would skip rather than staying silent" {
  write_docker_stub 5 0
  run_janitor
  [ "$status" -eq 0 ]
  [[ "$output" == *"YOUNG"* ]]
  [[ "$output" == *"skipped_young"* ]]
}

# --- the ceiling: a lane stranded by a job that never reached its teardown ----

@test "a lane older than --max-age is reaped even with containers running" {
  # The leak this ticket is about: six running containers, hours old, and a
  # 30-minute threshold that skipped them on every sweep for 22 hours because
  # the age could not be parsed. `running` is 1 here, which is what makes the
  # case mean anything — the old code took that branch and printed SKIP.
  write_docker_stub 21600 1
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE huddle-ci-abc123"* ]]
  [[ "$output" == *"CLEAN huddle-ci-abc123"* ]]
  [[ "$output" != *"SKIP"* ]]
}

@test "a live lane inside --max-age with containers running is skipped" {
  # The other direction, and the reason --max-age must sit above the longest
  # legitimate job: a running lane ten minutes into its work is not garbage.
  write_docker_stub 600 1
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  huddle-ci-abc123"* ]]
  [[ "$output" != *"CLEAN"* ]]
}

@test "a foreign project on the same host is never a candidate" {
  # This runner is shared with an unrelated homelab. The prefix filter is the
  # only thing standing between a sweep and someone else's media server.
  write_docker_stub 21600 1 "homelab-jellyfin"
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" != *"homelab-jellyfin"* ]]
  [[ "$output" == *"projects_found: 1"* ]]
}

@test "an unreadable container age is reported and fails the run, never reaped" {
  # A janitor that cannot measure age is broken, and the old code expressed that
  # as "not stale, not young" — a verdict. The daily health check reads this
  # exit status through ${PIPESTATUS[0]}.
  write_unparseable_docker_stub
  run_janitor --apply --max-age=120
  [ "$status" -ne 0 ]
  [[ "$output" == *"AGE?"* ]]
  [[ "$output" == *"undetermined:    1"* ]]
  [[ "$output" != *"CLEAN"* ]]
}

# --- newest, not oldest: the one number both age questions are asked about -----

# $1 = seconds ago for the OLDEST container, $2 = for the NEWEST, $3 = how many
# are RUNNING. Every other stub here emits exactly one container, which makes
# "newest" and "oldest" the same value and the choice between them untestable.
#
# The stamps are real wall clock IN the zone they are labelled with, which is why
# they go through TZ rather than `date -u` with a hard-coded offset: a UTC clock
# printed under a `-0700` label puts every container seven hours in the FUTURE,
# and a suite built on that reads YOUNG everywhere and passes vacuously. The zone
# is also deliberately not UTC, so the abbreviation this parser had to be fixed
# for is exercised on a UTC runner too.
write_two_container_docker_stub() {
  local oldest_seconds="$1" newest_seconds="$2" running="$3"
  cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
stamp() {
  TZ=America/Los_Angeles date -d "@\$1" '+%Y-%m-%d %H:%M:%S %z %Z' 2>/dev/null || \\
    TZ=America/Los_Angeles date -r "\$1" '+%Y-%m-%d %H:%M:%S %z %Z'
}
now=\$(date +%s)
case "\$*" in
  *"ps -a"*"{{.CreatedAt}}"*) stamp \$(( now - $oldest_seconds )); stamp \$(( now - $newest_seconds )) ;;
  *"ps -a"*"-q"*)             echo "container-1"; echo "container-2" ;;
  *"ps --filter"*"-q"*)       [ "$running" -gt 0 ] && echo "container-1" || true ;;
  *"ps -a --format"*)         echo "huddle-ci-abc123" ;;
  *"volume ls"*)              true ;;
  *"network ls"*)             true ;;
  *"compose"*)                echo "CLEANED-BY-STUB" ;;
  *) true ;;
esac
STUB
  chmod +x "$STUB_BIN/docker"
}

@test "a lane whose newest container is inside --max-age is kept, however old its oldest is" {
  # The shape a real lane has: a long-lived backend container plus a
  # `backend-run-*` one started minutes ago. Reading the OLDEST would call this
  # 22 h old and reap a job that is still working.
  write_two_container_docker_stub 79200 6600 1
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIP  huddle-ci-abc123"* ]]
  [[ "$output" != *"STALE"* ]]
  [[ "$output" != *"CLEAN"* ]]
}

@test "a lane whose newest container is past --max-age is reaped, oldest container and all" {
  # The other side of the same boundary, ten minutes further out. It is also what
  # makes the case above non-vacuous: if the `-0700 PDT` stamp were unreadable,
  # this one would report AGE? instead of STALE.
  write_two_container_docker_stub 79200 7800 1
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" == *"STALE huddle-ci-abc123"* ]]
  [[ "$output" == *"CLEAN huddle-ci-abc123"* ]]
  [[ "$output" != *"AGE?"* ]]
}

@test "a project that merely contains the prefix is not a candidate" {
  # `homelab-jellyfin` cannot tell an anchored match from a substring one, because
  # it holds no `huddle-ci-` anywhere. This one does, in the middle.
  write_docker_stub 21600 1 "foo-huddle-ci-x"
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" != *"foo-huddle-ci-x"* ]]
  [[ "$output" == *"projects_found: 1"* ]]
}

# --- when the teardown itself fails --------------------------------------------

# A host where `docker compose down` fails on a stale project. $1 = whether the
# labeled-resource fallback then succeeds. Containers, networks and volumes all
# exist, so all three fallback removals are actually reached.
write_failing_teardown_docker_stub() {
  local fallback_ok="$1"
  cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
created="\$(date -d "@\$(( \$(date +%s) - 21600 ))" '+%Y-%m-%d %H:%M:%S +0000 UTC' 2>/dev/null || date -r \$(( \$(date +%s) - 21600 )) '+%Y-%m-%d %H:%M:%S +0000 UTC')"
case "\$*" in
  *"ps -a"*"{{.CreatedAt}}"*) echo "\$created" ;;
  *"ps -a"*"-q"*)             echo "container-1" ;;
  *"ps --filter"*"-q"*)       echo "container-1" ;;
  *"ps -a --format"*)         echo "huddle-ci-abc123" ;;
  *"network ls"*"-q"*)        echo "network-1" ;;
  *"volume ls"*"-q"*)         echo "volume-1" ;;
  *"volume ls"*|*"network ls"*) true ;;
  *"compose"*)                exit 1 ;;
  "rm -f"*|"network rm"*|"volume rm"*) exit $fallback_ok ;;
  *) true ;;
esac
STUB
  chmod +x "$STUB_BIN/docker"
}

@test "a teardown that fails outright is counted and reddens the run" {
  # Both arms fail: compose cannot bring the project down and the labeled-resource
  # fallback cannot either. The lane is still on the host, so the run must say so
  # rather than report a clean sweep.
  write_failing_teardown_docker_stub 1
  run_janitor --apply --max-age=120
  [ "$status" -ne 0 ]
  [[ "$output" == *"WARN  compose down failed"* ]]
  [[ "$output" == *"FAIL  huddle-ci-abc123"* ]]
  [[ "$output" == *"failed:          1"* ]]
  [[ "$output" == *"cleaned:         0"* ]]
}

@test "a compose down that fails still counts as cleaned when the fallback works" {
  # Compose metadata drift is the ordinary reason `compose down` fails on a lane
  # whose containers are plainly still labelled. Removing them by label IS the
  # cleanup, and must not be reported as a failure.
  write_failing_teardown_docker_stub 0
  run_janitor --apply --max-age=120
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARN  compose down failed"* ]]
  [[ "$output" != *"FAIL"* ]]
  [[ "$output" == *"cleaned:         1"* ]]
  [[ "$output" == *"failed:          0"* ]]
}
