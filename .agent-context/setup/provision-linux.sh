#!/usr/bin/env bash
# Provisions a Debian/Ubuntu host (the Claude Code cloud container, or a
# Linux workstation run as root) for this fork: the Crystal bootstrap
# compiler, the GMP dev link, a PostgreSQL 16 test cluster (trust,
# cleartext, md5, SCRAM and TLS roles, a streaming standby on 5433) and
# redis-server. Idempotent: skips what exists, (re)starts what is down.
# Prints the environment the specs need as `export` lines on stdout;
# progress goes to stderr.
set -uo pipefail

log() { echo "[provision] $*" >&2; }

CRYSTAL_VERSION=1.21.0
CRYSTAL_DIR=/opt/crystal-boot/crystal-${CRYSTAL_VERSION}-1
PGBIN=/usr/lib/postgresql/16/bin
PGDATA=/opt/pgdata
PGSTANDBY=/opt/pgstandby
PGSOCK=/opt/pgsock

# --- packages -------------------------------------------------------------
missing=()
[ -x "$PGBIN/postgres" ] || missing+=(postgresql-16 postgresql-client-16)
command -v redis-server >/dev/null || missing+=(redis-server)
command -v llvm-config >/dev/null || missing+=(llvm-18)
[ -e /usr/include/gc.h ] || [ -e /usr/lib/x86_64-linux-gnu/libgc.so.1 ] || missing+=(libgc-dev)
if [ ${#missing[@]} -gt 0 ]; then
  log "installing ${missing[*]}"
  (apt-get update -qq && DEBIAN_FRONTEND=noninteractive apt-get install -y -qq "${missing[@]}") >&2 ||
    log "apt-get failed; install ${missing[*]} by hand"
fi

# --- Crystal bootstrap compiler (bin/crystal falls back to it) --------------
if [ ! -x "$CRYSTAL_DIR/bin/crystal" ]; then
  log "downloading Crystal $CRYSTAL_VERSION"
  mkdir -p /opt/crystal-boot
  curl -sSL -o /opt/crystal-boot/c.tar.gz \
    "https://github.com/crystal-lang/crystal/releases/download/${CRYSTAL_VERSION}/crystal-${CRYSTAL_VERSION}-1-linux-x86_64.tar.gz" &&
    tar xzf /opt/crystal-boot/c.tar.gz -C /opt/crystal-boot && rm -f /opt/crystal-boot/c.tar.gz
fi

# `require "big"` (Postgres NUMERIC) links -lgmp; Ubuntu ships only .so.10.
for dir in /usr/lib/x86_64-linux-gnu /usr/lib/aarch64-linux-gnu; do
  if [ -e "$dir/libgmp.so.10" ] && [ ! -e "$dir/libgmp.so" ]; then ln -sf libgmp.so.10 "$dir/libgmp.so"; fi
done

# --- PostgreSQL primary -----------------------------------------------------
id postgres >/dev/null 2>&1 || useradd -r postgres
mkdir -p "$PGSOCK" && chown postgres "$PGSOCK"
as_pg() { su postgres -s /bin/sh -c "$*"; }

if [ ! -f "$PGDATA/PG_VERSION" ]; then
  log "creating the PostgreSQL cluster in $PGDATA"
  rm -rf "$PGDATA" && mkdir -p "$PGDATA" && chown postgres "$PGDATA"
  as_pg "$PGBIN/initdb -D $PGDATA -U postgres --auth=trust -E UTF8 --locale=C.UTF-8" >/dev/null
  (cd "$PGDATA" && openssl req -new -x509 -days 3650 -nodes -subj "/CN=localhost" \
    -out server.crt -keyout server.key 2>/dev/null && chown postgres server.* && chmod 600 server.key)
  cat >> "$PGDATA/postgresql.conf" <<CONF
port = 5432
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
chown -R postgres "$PGDATA"
if ! as_pg "$PGBIN/pg_ctl -D $PGDATA status" >/dev/null 2>&1; then
  log "starting PostgreSQL on 5432"
  as_pg "$PGBIN/pg_ctl -D $PGDATA -l $PGDATA/log.txt -w start" >/dev/null
fi
if [ "${NEW_CLUSTER:-}" = 1 ]; then
  psql -h "$PGSOCK" -U postgres -qc "create database crystal_test" >/dev/null
  psql -h "$PGSOCK" -U postgres -q <<'SQL' >/dev/null
set password_encryption = 'md5';
create role crystal_md5 login password 'md5pass';
set password_encryption = 'scram-sha-256';
create role crystal_clear login password 'clearpass';
create role crystal_scram login password 'scrampass';
create role crystal_ssl login password 'sslpass';
grant all on database crystal_test to public;
alter database crystal_test owner to crystal_scram;
SQL
  psql -h "$PGSOCK" -U postgres -d crystal_test -qc "create extension if not exists hstore" >/dev/null
fi

# --- streaming standby on 5433 (target_session_attrs specs) ------------------
if [ ! -f "$PGSTANDBY/PG_VERSION" ]; then
  log "creating the standby in $PGSTANDBY"
  rm -rf "$PGSTANDBY" && mkdir -p "$PGSTANDBY" && chown postgres "$PGSTANDBY" && chmod 700 "$PGSTANDBY"
  as_pg "$PGBIN/pg_basebackup -h 127.0.0.1 -p 5432 -U postgres -D $PGSTANDBY -R -X stream" &&
    printf "port = 5433\nhot_standby = on\n" >> "$PGSTANDBY/postgresql.conf"
fi
chown -R postgres "$PGSTANDBY" 2>/dev/null
if [ -f "$PGSTANDBY/PG_VERSION" ] && ! as_pg "$PGBIN/pg_ctl -D $PGSTANDBY status" >/dev/null 2>&1; then
  log "starting the standby on 5433"
  as_pg "$PGBIN/pg_ctl -D $PGSTANDBY -l $PGSTANDBY/log.txt -w start" >/dev/null
fi

# --- Redis --------------------------------------------------------------------
if ! redis-cli ping >/dev/null 2>&1; then
  log "starting redis-server on 6379"
  redis-server --port 6379 --save "" --appendonly no --daemonize yes >/dev/null
fi

# --- report + environment -------------------------------------------------------
psql -h 127.0.0.1 -U postgres -d crystal_test -Atc "select 'postgres ok'" >&2 || log "postgres NOT reachable"
psql -h 127.0.0.1 -p 5433 -U postgres -d crystal_test -Atc "select 'standby ok (recovery=' || pg_is_in_recovery() || ')'" >&2 || log "standby NOT reachable"
redis-cli ping >&2 || log "redis NOT reachable"
cat <<ENV
export PATH=$CRYSTAL_DIR/bin:\$PATH
export POSTGRES_URL="postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable"
export POSTGRES_MD5_URL="postgres://crystal_md5:md5pass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_CLEARTEXT_URL="postgres://crystal_clear:clearpass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_SCRAM_URL="postgres://crystal_scram:scrampass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_SSL_URL="postgres://crystal_ssl:sslpass@127.0.0.1/crystal_test"
export POSTGRES_STANDBY_URL="postgres://postgres@127.0.0.1:5433/crystal_test?sslmode=disable"
ENV
