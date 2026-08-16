#!/usr/bin/env bash
# Bounded Postgres readiness checks for test-backend's Compose lane.
# shellcheck shell=bash

wtl_postgres_readiness_diagnostics() {
  local project="$1"
  local compose_file="$2"
  local service="$3"

  echo "Postgres readiness diagnostics for service '$service' (compose project '$project'):" >&2
  echo "Compose status for service '$service':" >&2
  docker compose -p "$project" -f "$compose_file" ps "$service" >&2 || true
  echo "Recent logs for service '$service':" >&2
  docker compose -p "$project" -f "$compose_file" logs --no-color --tail=100 "$service" >&2 || true
}

wtl_wait_for_postgres_ready() {
  local project="$1"
  local compose_file="$2"
  local service="${3:-postgres}"
  local timeout="${4:-${WTL_POSTGRES_READINESS_TIMEOUT:-90}}"
  local attempt cid status_line health_state container_state
  local last_health="missing" last_container_state="missing"

  case "$timeout" in
    ''|*[!0-9]*|0)
      echo "Postgres readiness gate: invalid timeout '$timeout' for service '$service' (expected a positive number of seconds)." >&2
      return 2
      ;;
  esac

  echo "Postgres readiness gate: waiting for service '$service' (timeout ${timeout}s)..." >&2
  for attempt in $(seq 1 "$timeout"); do
    cid="$(docker compose -p "$project" -f "$compose_file" ps -q "$service" 2>/dev/null || true)"
    if [ -n "$cid" ]; then
      status_line="$(docker inspect --format '{{if .Config.Healthcheck}}{{if .State.Health}}{{.State.Health.Status}}{{else}}healthcheck-pending{{end}}|{{.State.Status}}{{else}}no-healthcheck|{{.State.Status}}{{end}}' "$cid" 2>/dev/null || true)"
      if [[ "$status_line" == *"|"* ]]; then
        health_state="${status_line%%|*}"
        container_state="${status_line#*|}"
      else
        health_state="unknown"
        container_state="$status_line"
      fi
      [ -n "$health_state" ] || health_state="unknown"
      [ -n "$container_state" ] || container_state="unknown"
    else
      health_state="missing"
      container_state="missing"
    fi

    last_health="$health_state"
    last_container_state="$container_state"

    if [ "$container_state" = "running" ] && {
      [ "$health_state" = "healthy" ] || [ "$health_state" = "no-healthcheck" ];
    }; then
      echo "Postgres readiness gate: service '$service' is ready (${health_state})." >&2
      return 0
    fi

    if [ $((attempt % 5)) -eq 0 ] || [ "$attempt" -eq 1 ]; then
      echo "Postgres readiness gate: service '$service' is not ready (${attempt}/${timeout}, health=${health_state}, container=${container_state})." >&2
    fi
    [ "$attempt" -lt "$timeout" ] && sleep 1
  done

  echo "Postgres readiness gate timed out after ${timeout}s for service '$service' (last health=${last_health}, container=${last_container_state})." >&2
  wtl_postgres_readiness_diagnostics "$project" "$compose_file" "$service"
  return 1
}
