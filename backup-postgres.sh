#!/usr/bin/env bash
#
# Back up Postgres databases running in a Docker container, keeping the newest
# N backups per database.
#
# Usage: backup-postgres.sh [path/to/backup-config.json]
#   (defaults to backup-config.json next to this script)
#
# Each database gets its own folder: <target_dir>/<database>/<database>_<UTC timestamp>.dump
# Dumps use pg_dump's custom format (-Fc): compressed, restore with pg_restore.
#
# Old backups are only pruned after a new backup has succeeded and been verified,
# so a failing backup never eats into the ones you already have.

set -euo pipefail

# cron runs with a minimal PATH; make sure docker/jq/flock are findable.
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:${PATH:-}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="${1:-$SCRIPT_DIR/backup-config.json}"

log() {
  printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "$2"
}

fail() {
  log ERROR "$1" >&2
  exit 1
}

require_commands() {
  local cmd
  for cmd in docker jq flock; do
    command -v "$cmd" >/dev/null 2>&1 || fail "required command not found: $cmd"
  done
}

read_config() {
  [[ -r "$CONFIG_FILE" ]] || fail "config file not readable: $CONFIG_FILE"
  jq -e . "$CONFIG_FILE" >/dev/null 2>&1 || fail "config file is not valid JSON: $CONFIG_FILE"

  CONTAINER="$(jq -r '.container // empty' "$CONFIG_FILE")"
  DB_USER="$(jq -r '.db_user // "postgres"' "$CONFIG_FILE")"
  TARGET_DIR="$(jq -r '.target_dir // empty' "$CONFIG_FILE")"
  RETAIN="$(jq -r '.retain // 3' "$CONFIG_FILE")"
  mapfile -t DATABASES < <(jq -r '.databases // [] | .[]' "$CONFIG_FILE")

  [[ -n "$CONTAINER" ]] || fail "config: 'container' is required"
  [[ -n "$TARGET_DIR" ]] || fail "config: 'target_dir' is required"
  [[ "$RETAIN" =~ ^[1-9][0-9]*$ ]] || fail "config: 'retain' must be a positive integer (got '$RETAIN')"
  (( ${#DATABASES[@]} > 0 )) || fail "config: 'databases' must list at least one database"

  local db
  for db in "${DATABASES[@]}"; do
    # The name becomes a folder and file name, so keep it to safe characters.
    [[ "$db" =~ ^[A-Za-z0-9_.-]+$ ]] || fail "config: unsupported database name '$db'"
  done
}

check_container() {
  local running
  running="$(docker inspect -f '{{.State.Running}}' "$CONTAINER" 2>/dev/null)" \
    || fail "container not found: $CONTAINER"
  [[ "$running" == "true" ]] || fail "container is not running: $CONTAINER"
}

acquire_lock() {
  mkdir -p "$TARGET_DIR"
  exec 9>"$TARGET_DIR/.backup.lock"
  flock -n 9 || fail "another backup is already running against $TARGET_DIR"
}

# Dump one database to a .partial file, verify it, then move it into place.
backup_database() {
  local db="$1"
  local db_dir="$TARGET_DIR/$db"
  local stamp final partial

  stamp="$(date -u '+%Y%m%dT%H%M%SZ')"
  final="$db_dir/${db}_${stamp}.dump"
  partial="$final.partial"

  mkdir -p "$db_dir"
  log INFO "backing up '$db' -> $final"

  if ! docker exec "$CONTAINER" pg_dump -U "$DB_USER" -Fc "$db" >"$partial"; then
    rm -f "$partial"
    log ERROR "pg_dump failed for '$db'" >&2
    return 1
  fi

  # Ask pg_restore to read the archive's table of contents; a truncated or
  # corrupt dump fails here instead of silently replacing a good backup.
  if ! docker exec -i "$CONTAINER" pg_restore --list <"$partial" >/dev/null; then
    rm -f "$partial"
    log ERROR "dump for '$db' failed verification" >&2
    return 1
  fi

  mv "$partial" "$final"
  log INFO "backed up '$db' ($(du -h "$final" | cut -f1))"
}

# Keep the newest $RETAIN backups for a database; delete the rest.
prune_backups() {
  local db="$1"
  local db_dir="$TARGET_DIR/$db"
  local old

  # Timestamps are fixed-width UTC, so a reverse name sort is newest first.
  find "$db_dir" -maxdepth 1 -type f -name "${db}_*.dump" -printf '%f\n' \
    | sort -r \
    | tail -n +"$((RETAIN + 1))" \
    | while IFS= read -r old; do
        log INFO "pruning old backup $db_dir/$old"
        rm -f -- "$db_dir/$old"
      done
}

main() {
  require_commands
  read_config
  check_container
  acquire_lock

  log INFO "starting backup of ${#DATABASES[@]} database(s) from '$CONTAINER' (retain $RETAIN)"

  local db failed=()
  for db in "${DATABASES[@]}"; do
    if backup_database "$db"; then
      prune_backups "$db"
    else
      failed+=("$db")
    fi
  done

  if (( ${#failed[@]} > 0 )); then
    fail "backup failed for: ${failed[*]}"
  fi
  log INFO "all backups completed"
}

main
