#!/usr/bin/env bats
# The janitor's age floor.
#
# Every case here stubs `docker` through PATH, so no case needs a daemon and none
# can reach one. The stub is what makes the load-bearing case reachable at all:
# the defect this floor exists for is a compose project observed in the moment
# between `Created` and `Started`, which cannot be produced on demand against a
# real daemon.

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

# $1 = seconds ago the container was created, $2 = how many are RUNNING
write_docker_stub() {
  local age_seconds="$1" running="$2"
  cat > "$STUB_BIN/docker" <<STUB
#!/usr/bin/env bash
created="\$(date -u -d "@\$(( \$(date +%s) - $age_seconds ))" '+%Y-%m-%d %H:%M:%S +0000' 2>/dev/null || date -u -r \$(( \$(date +%s) - $age_seconds )) '+%Y-%m-%d %H:%M:%S +0000')"
case "\$*" in
  *"ps -a"*"{{.CreatedAt}}"*) echo "\$created" ;;
  *"ps -a"*"-q"*)             echo "container-1" ;;
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
