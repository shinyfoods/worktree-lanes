#!/usr/bin/env bats
# shellcheck shell=bash
#
# lane-up without a terminal must never attach. An attached `docker compose up` streams
# logs until Ctrl-C, and a script or agent that ran lane-up expecting it to return waited
# on an exit that could not come. These cases stop the bring-up at the first compose `up`,
# by making the fake docker exit with a distinct status for each mode, so the mode that
# was chosen is read from the status and no readiness wait is exercised.

setup() {
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  FAKE_BIN="$(mktemp -d)"
  export FAKE_BIN
  export PATH="$FAKE_BIN:$PATH"
  unset GITHUB_ACTIONS

  cat > "$FAKE_BIN/worktree" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  env)
    if [ "${2:-}" = --shell ]; then
      printf 'export %s\n' \
        COMPOSE_PROJECT_NAME=lane-up-test COMPOSE_FILE=/dev/null WTL_PROJECT=test \
        WTL_FRONTEND_URL=http://localhost:1 WTL_API_BASE_URL=http://localhost:2/api \
        WTL_MAILHOG_UI_PORT=3 WTL_MAILHOG_API_URL=http://localhost:3/api
    fi
    ;;
  sync-gems) ;;
  *) echo "unexpected worktree invocation: $*" >&2; exit 99 ;;
esac
STUB
  cat > "$FAKE_BIN/docker" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
# `docker compose <opts> <verb> ...`: find the verb after the project/file options.
args=("$@"); verb=""; i=1
while [ "$i" -lt "${#args[@]}" ]; do
  case "${args[$i]}" in
    -p|-f) i=$((i+2)); continue ;;
    *) verb="${args[$i]}"; break ;;
  esac
done
rest=("${args[@]:$((i+1))}")
case "$verb" in
  ps) echo "a-container" ;;
  version) echo "0.0-test" ;;
  up)
    printf '%s\n' "${rest[@]}" > "$FAKE_BIN/up.args"
    case " ${rest[*]} " in
      *" -d "*) exit 42 ;;
      *) exit 43 ;;
    esac
    ;;
esac
STUB
  chmod +x "$FAKE_BIN/worktree" "$FAKE_BIN/docker"
}

teardown() {
  rm -rf "$FAKE_BIN"
}

@test "without a terminal, lane-up brings the lane up detached and says so" {
  run bash "$WTL_ROOT/libexec/lane-up" < /dev/null
  [ "$status" -eq 42 ]
  [[ "$output" == *"no terminal on stdin and stdout"* ]]
  grep -qx -- "-d" "$FAKE_BIN/up.args"
}

@test "--attach forces the log stream even without a terminal" {
  run bash "$WTL_ROOT/libexec/lane-up" --attach < /dev/null
  [ "$status" -eq 43 ]
  [[ "$output" != *"no terminal"* ]]
  ! grep -qx -- "-d" "$FAKE_BIN/up.args"
}

@test "--detach is unchanged: detached, without the no-terminal notice" {
  run bash "$WTL_ROOT/libexec/lane-up" --detach < /dev/null
  [ "$status" -eq 42 ]
  [[ "$output" != *"no terminal"* ]]
}
