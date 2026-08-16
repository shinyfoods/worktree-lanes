#!/usr/bin/env bats
# shellcheck shell=bash
load helper

setup() {
  export WTL_ROOT="$BATS_TEST_DIRNAME/.."
  FAKE_BIN="$(mktemp -d)"
  export FAKE_BIN
  export PATH="$FAKE_BIN:$BATS_TEST_DIRNAME/../bin:$PATH"
  cat > "$FAKE_BIN/worktree" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[ "${1:-}" = env ] && [ "${2:-}" = --shell ] || {
  echo "unexpected worktree invocation: $*" >&2
  exit 99
}
if [ -n "${WTL_ENV_STDOUT:-}" ]; then
  printf '%s\n' "$WTL_ENV_STDOUT"
fi
if [ -n "${WTL_ENV_STDERR:-}" ]; then
  printf '%s\n' "$WTL_ENV_STDERR" >&2
fi
exit "${WTL_ENV_STATUS:-0}"
EOF
  chmod +x "$FAKE_BIN/worktree"
}

teardown() {
  rm -rf "$FAKE_BIN"
}

assert_failure_contract() {
  local loader="$1"
  local output status
  if output="$(env WTL_ENV_STATUS=17 WTL_ENV_STDERR='raw dump failed' \
    bash -c 'set -euo pipefail; . "$1"; wtl_load_env; printf "downstream reached\\n"' \
    bash "$loader" 2>&1)"; then
    status=0
  else
    status=$?
  fi

  if [ "$status" -ne 17 ]; then
    echo "named assertion failed: env loader preserves child status (got $status)"
    return 1
  fi
  case "$output" in
    *"worktree env --shell failed (status 17)"*) ;;
    *) echo "named assertion failed: env loader reports the child status"; return 1 ;;
  esac
  case "$output" in
    *"raw dump failed"*) ;;
    *) echo "named assertion failed: env loader preserves child stderr"; return 1 ;;
  esac
  case "$output" in
    *"downstream reached"*) echo "named assertion failed: downstream command ran"; return 1 ;;
  esac
}

@test "red-before: raw eval hides a failed env dump behind an unbound variable" {
  run env WTL_ENV_STATUS=17 WTL_ENV_STDERR='raw dump failed' \
    bash -c 'set -euo pipefail; eval "$(worktree env --shell)"; printf "%s\\n" "$WTL_FIXTURE_VALUE"'
  [ "$status" -ne 0 ]
  [[ "$output" == *"raw dump failed"* ]]
  [[ "$output" == *"unbound variable"* ]]
  [[ "$output" != *"worktree env --shell failed"* ]]
}

@test "a failing env dump preserves stderr, child status, and stops before downstream work" {
  run assert_failure_contract "$WTL_ROOT/lib/env.sh"
  [ "$status" -eq 0 ]
}

@test "an empty successful env dump fails before downstream work" {
  run env WTL_ENV_STATUS=0 WTL_ENV_STDERR='empty dump diagnostic' \
    bash -c 'set -euo pipefail; . "$1"; wtl_load_env; printf "downstream reached\\n"' \
    bash "$WTL_ROOT/lib/env.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"empty dump diagnostic"* ]]
  [[ "$output" == *"worktree env --shell returned an empty shell dump (status 0)"* ]]
  [[ "$output" != *"downstream reached"* ]]
}

@test "a non-empty successful env dump reaches the next command with exported values" {
  run env WTL_ENV_STDOUT='export WTL_FIXTURE_VALUE=ready' \
    bash -c 'set -euo pipefail; . "$1"; wtl_load_env; printf "downstream=%s\\n" "$WTL_FIXTURE_VALUE"' \
    bash "$WTL_ROOT/lib/env.sh"
  [ "$status" -eq 0 ]
  [ "$output" = "downstream=ready" ]
}

@test "removing both positive guards fails the named child-status assertion" {
  mutant="$BATS_TEST_TMPDIR/env-mutant.sh"
  awk '
    /^  if \[ "\$env_status" -ne 0 \]; then$/ { skipping = 1; print "  :"; next }
    /^  if \[ ! -s "\$env_dump" \]; then$/ { skipping = 1; print "  :"; next }
    skipping && /^  fi$/ { skipping = 0; next }
    !skipping { print }
  ' "$WTL_ROOT/lib/env.sh" > "$mutant"

  run assert_failure_contract "$mutant"
  [ "$status" -ne 0 ]
  [[ "$output" == *"named assertion failed: env loader preserves child status"* ]]
}
