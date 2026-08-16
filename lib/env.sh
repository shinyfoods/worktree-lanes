# shellcheck shell=bash

# Load the generated shell environment without allowing a failed or empty
# command substitution to look like a successful `eval ""`.
wtl_load_env() {
  local env_dump env_stderr env_status eval_status

  if ! env_dump="$(mktemp "${TMPDIR:-/tmp}/worktree-env.XXXXXX")"; then
    printf 'worktree env --shell could not allocate a stdout capture file\n' >&2
    return 1
  fi
  if ! env_stderr="$(mktemp "${TMPDIR:-/tmp}/worktree-env-stderr.XXXXXX")"; then
    rm -f "$env_dump"
    printf 'worktree env --shell could not allocate a stderr capture file\n' >&2
    return 1
  fi

  if worktree env --shell "$@" >"$env_dump" 2>"$env_stderr"; then
    env_status=0
  else
    env_status=$?
  fi

  if [ -s "$env_stderr" ]; then
    cat "$env_stderr" >&2
  fi

  if [ "$env_status" -ne 0 ]; then
    rm -f "$env_dump" "$env_stderr"
    printf 'worktree env --shell failed (status %s)\n' "$env_status" >&2
    return "$env_status"
  fi

  if [ ! -s "$env_dump" ]; then
    rm -f "$env_dump" "$env_stderr"
    printf 'worktree env --shell returned an empty shell dump (status 0)\n' >&2
    return 1
  fi

  # This is the guarded execution point for the generated dump. Nothing is
  # evaluated until the child status and non-empty-output assertions pass.
  if eval "$(<"$env_dump")"; then
    eval_status=0
  else
    eval_status=$?
  fi

  rm -f "$env_dump" "$env_stderr"
  return "$eval_status"
}
