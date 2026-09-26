#!/usr/bin/env bash
# Workstation (macOS + Homebrew) equivalent of provision-linux.sh: a
# PostgreSQL 16 test cluster with the trust/cleartext/md5/SCRAM/TLS roles
# and a streaming standby, plus Valkey/Redis, all under $STATE (no root,
# nothing system-wide). Idempotent. Prints the spec environment as
# `export` lines; eval them:  eval "$(.agent-context/setup/provision-macos.sh)"
#
# Ports are configurable in case a Postgres already listens on 5432:
#   PG_PORT=55432 PG_STANDBY_PORT=55433 REDIS_PORT=6379 .agent-context/setup/provision-macos.sh
#
# NOTE: written 2026-09-26 in a Linux session from the same recipe as
# provision-linux.sh (which is verified); not yet run on macOS.
set -uo pipefail
log() { echo "[provision] $*" >&2; }

STATE=${STATE:-$HOME/.crystal-fork}
PG_PORT=${PG_PORT:-5432}
PG_STANDBY_PORT=${PG_STANDBY_PORT:-5433}
REDIS_PORT=${REDIS_PORT:-6379}
PGDATA=$STATE/pgdata
PGSTANDBY=$STATE/pgstandby
PGSOCK=$STATE/pgsock

command -v brew >/dev/null || { log "Homebrew is required"; exit 1; }
brew list postgresql@16 >/dev/null 2>&1 || { log "brew install postgresql@16"; brew install postgresql@16 >&2; }
if ! command -v valkey-server >/dev/null && ! command -v redis-server >/dev/null; then
  log "brew install valkey"; brew install valkey >&2
fi
PGBIN=$(brew --prefix postgresql@16)/bin
REDIS_SERVER=$(command -v valkey-server || command -v redis-server)
REDIS_CLI=$(command -v valkey-cli || command -v redis-cli)
mkdir -p "$STATE" "$PGSOCK"

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  log "creating the PostgreSQL cluster in $PGDATA"
  "$PGBIN/initdb" -D "$PGDATA" -U postgres --auth=trust -E UTF8 --locale=C >/dev/null
  (cd "$PGDATA" && openssl req -new -x509 -days 3650 -nodes -subj "/CN=localhost" \
    -out server.crt -keyout server.key 2>/dev/null && chmod 600 server.key)
  cat >> "$PGDATA/postgresql.conf" <<CONF
port = $PG_PORT
listen_addresses = '127.0.0.1'
unix_socket_directories = '$PGSOCK'
ssl = on
ssl_cert_file = 'server.crt'
ssl_key_file = 'server.key'
password_encryption = 'scram-sha-256'
max_connections = 200
fsync = off
wal_level = replica
CONF
  cat > "$PGDATA/pg_hba.conf" <<HBA
local replication postgres trust
host replication postgres 127.0.0.1/32 trust
local all postgres trust
local all all scram-sha-256
host all crystal_md5 127.0.0.1/32 md5
host all crystal_clear 127.0.0.1/32 password
host all crystal_scram 127.0.0.1/32 scram-sha-256
hostssl all crystal_ssl 127.0.0.1/32 scram-sha-256
host all all 127.0.0.1/32 trust
HBA
  NEW_CLUSTER=1
fi
"$PGBIN/pg_ctl" -D "$PGDATA" status >/dev/null 2>&1 ||
  { log "starting PostgreSQL on $PG_PORT"; "$PGBIN/pg_ctl" -D "$PGDATA" -l "$PGDATA/log.txt" -w start >/dev/null; }
if [ "${NEW_CLUSTER:-}" = 1 ]; then
  "$PGBIN/psql" -h "$PGSOCK" -p "$PG_PORT" -U postgres -qc "create database crystal_test" >/dev/null
  "$PGBIN/psql" -h "$PGSOCK" -p "$PG_PORT" -U postgres -q <<'SQL' >/dev/null
set password_encryption = 'md5';
create role crystal_md5 login password 'md5pass';
set password_encryption = 'scram-sha-256';
create role crystal_clear login password 'clearpass';
create role crystal_scram login password 'scrampass';
create role crystal_ssl login password 'sslpass';
grant all on database crystal_test to public;
alter database crystal_test owner to crystal_scram;
SQL
  "$PGBIN/psql" -h "$PGSOCK" -p "$PG_PORT" -U postgres -d crystal_test -qc "create extension if not exists hstore" >/dev/null
fi

if [ ! -f "$PGSTANDBY/PG_VERSION" ]; then
  log "creating the standby in $PGSTANDBY"
  "$PGBIN/pg_basebackup" -h 127.0.0.1 -p "$PG_PORT" -U postgres -D "$PGSTANDBY" -R -X stream &&
    printf "port = %s\nhot_standby = on\n" "$PG_STANDBY_PORT" >> "$PGSTANDBY/postgresql.conf" && chmod 700 "$PGSTANDBY"
fi
"$PGBIN/pg_ctl" -D "$PGSTANDBY" status >/dev/null 2>&1 ||
  { log "starting the standby on $PG_STANDBY_PORT"; "$PGBIN/pg_ctl" -D "$PGSTANDBY" -l "$PGSTANDBY/log.txt" -w start >/dev/null; }

"$REDIS_CLI" -p "$REDIS_PORT" ping >/dev/null 2>&1 ||
  { log "starting $(basename "$REDIS_SERVER") on $REDIS_PORT"; "$REDIS_SERVER" --port "$REDIS_PORT" --save "" --appendonly no --daemonize yes >/dev/null; }

"$PGBIN/psql" -h 127.0.0.1 -p "$PG_PORT" -U postgres -d crystal_test -Atc "select 'postgres ok'" >&2
"$PGBIN/psql" -h 127.0.0.1 -p "$PG_STANDBY_PORT" -U postgres -d crystal_test -Atc "select 'standby ok'" >&2
"$REDIS_CLI" -p "$REDIS_PORT" ping >&2
cat <<ENV
export REDIS_URL="redis://127.0.0.1:$REDIS_PORT"
export POSTGRES_URL="postgres://postgres@127.0.0.1:$PG_PORT/crystal_test?sslmode=disable"
export POSTGRES_MD5_URL="postgres://crystal_md5:md5pass@127.0.0.1:$PG_PORT/crystal_test?sslmode=disable"
export POSTGRES_CLEARTEXT_URL="postgres://crystal_clear:clearpass@127.0.0.1:$PG_PORT/crystal_test?sslmode=disable"
export POSTGRES_SCRAM_URL="postgres://crystal_scram:scrampass@127.0.0.1:$PG_PORT/crystal_test?sslmode=disable"
export POSTGRES_SSL_URL="postgres://crystal_ssl:sslpass@127.0.0.1:$PG_PORT/crystal_test"
export POSTGRES_STANDBY_URL="postgres://postgres@127.0.0.1:$PG_STANDBY_PORT/crystal_test?sslmode=disable"
ENV
