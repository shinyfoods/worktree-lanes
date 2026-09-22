# worktree-lanes

Per-worktree/lane dev+test isolation CLI for multi-worktree development.

## Installation

`worktree` is a bash CLI, so it runs on macOS, Linux, and WSL (and Git Bash) — not native
Windows PowerShell/cmd.

**Any platform (no Homebrew needed):**

```bash
curl -fsSL https://raw.githubusercontent.com/shinypancake/worktree-lanes/main/install.sh | bash
```

This clones the repo to `~/.local/share/worktree-lanes` and symlinks the launcher into
`~/.local/bin` (add that to your `PATH` if it isn't already; the installer prints how). Pin a
version with `| bash -s -- --version v0.1.8`, or change the target dir with `--bin-dir`.

**macOS / Linux via Homebrew** (optional convenience):

```bash
brew install shinypancake/tap/worktree-lanes
```

**Update** (for the `curl` install): `worktree self-update`. For Homebrew: `brew upgrade
shinypancake/tap/worktree-lanes`.

Requires `git` (and `docker`/`docker compose` at runtime; `psql`/`dropdb` for the `db-*`
commands).

## Usage

```
worktree env [--shell|--json|--plain] [--check-ports] [--infra-mode=isolated|shared]
worktree <subcommand> [args]
```

## Configuration

Add a `worktree.config` file at your repo root:

```bash
WTL_PROJECT=myproject
WTL_ENV_PREFIX=MYPROJECT
WTL_MAIN_BACKEND_PORT=3000
WTL_MAIN_FRONTEND_PORT=5173
WTL_MAIN_POSTGRES_PORT=5432
WTL_MAIN_REDIS_PORT=6379
WTL_MAIN_MAILHOG_UI_PORT=8025
WTL_MAIN_MAILHOG_SMTP_PORT=1025
WTL_DB_USER=myproject
WTL_DB_PASSWORD=myproject_password
WTL_SERVICES="backend frontend postgres redis mailhog"
WTL_HAS_FRONTEND=1
WTL_HAS_SIDEKIQ=1
WTL_HAS_MAILHOG=1
WTL_HAS_WEBAUTHN=0
```

## Why

Multiple git worktrees (or CI lanes) that share one Postgres will **deadlock** if their
test suites run concurrently against the same database — concurrent transactions contend on
unique indexes (hard-coded fixture values like a Stripe id or email) and Postgres kills one
as a deadlock victim, surfacing as intermittent, seed-independent test "flakes". This CLI
gives each worktree a deterministic identity (`<id> = sha256(worktree-path)[0:8]`) and from
it derives an isolated test database (`<project>_test_<id>`), dev database, Redis logical
DBs, ports, and Docker Compose project — so worktrees never collide.

## Subcommands

| Command | Purpose |
|---|---|
| `worktree env [--shell\|--json\|--plain] [--check-ports] [--infra-mode=isolated\|shared]` | Emit this worktree's identity as env vars: both project-prefixed (`${PREFIX}_*`, for `docker-compose.yml`/CI) and neutral `WTL_*` (for the CLI's own scripts). |
| `worktree test-backend [rspec/test args]` | Run the backend suite in a container against this worktree's test DB. |
| `worktree lane-up [-d\|--detach\|-a\|--attach] [--build\|--no-build] [--no-sidekiq]` / `lane-down` / `lane-reset` / `lane-status` / `lane-logs` / `lane-ports` | Bring an isolated Compose lane (per-worktree containers) up/down and inspect it. `lane-up` streams logs when run from a terminal and comes up detached, with a bounded readiness wait, when it has none (a script, an agent, CI); `--attach` forces the stream. |
| `worktree up-/stop-/logs-/run-{backend,frontend,sidekiq}`, `status-frontend`, `up-frontend-container` | Per-service control within a lane. |
| `worktree shared-infra-{up,down,status}` | Optional shared-infra mode (one Postgres/Redis for all lanes). |
| `worktree bootstrap`, `worktree sync-gems` | Setup helpers. |
| `worktree validate-parallel` | Spin two throwaway worktrees and assert their databases/ports don't collide. |
| `worktree db-drop [--dev]` | Drop this worktree's test (and with `--dev`, dev) database. Run before removing a worktree. |
| `worktree db-prune [--apply] [--dev]` | Drop orphaned `<project>_test_<id>` databases with no live worktree (dry-run by default). |
| `worktree runner-clean-ci [--apply] [--include-running] [--max-age=MIN]` | Reap leaked CI/lane Compose **projects** (containers/volumes/networks) with no running containers (dry-run by default). |
| `worktree runner-reap [--apply] [--only=PHASE] [--max-age-hours=N] [--cache-age=DUR]` | Durable runner janitor for what `runner-clean-ci` can't reach: built `<project>-…-<hash>-<service>` **images** no container references and older than max-age, aged build cache, and lanes still running after their worktree was deleted. Prefix-scoped to `WTL_PROJECT`; dry-run by default. |
| `worktree self-update [--version <tag>]` | Update a `curl`-installed (git-based) checkout in place to the latest release tag (or a pinned one). |
| `worktree version` | Print the CLI version. |

`db-drop` / `db-prune` need the Postgres client tools (`psql`/`dropdb`) on PATH (`brew install libpq`).

## Consuming repos

This CLI is project-agnostic — each repo adds only a `worktree.config`. In use by
[shinypancake/locals](https://github.com/shinypancake/locals) and
[shinypancake/huddle](https://github.com/shinypancake/huddle).
