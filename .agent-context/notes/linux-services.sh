#!/usr/bin/env bash
# Brings the cloud Linux container back to a testable state after a
# restart (processes are lost, files under /opt survive). First-time setup
# is described in memory/stdlib-batteries-direction.md (2026-09-26).
set -u
[ -x /opt/crystal-boot/crystal-1.21.0-1/bin/crystal ] || {
  mkdir -p /opt/crystal-boot && cd /opt/crystal-boot &&
  curl -sSL -o c.tar.gz https://github.com/crystal-lang/crystal/releases/download/1.21.0/crystal-1.21.0-1-linux-x86_64.tar.gz &&
  tar xzf c.tar.gz; }
[ -e /usr/lib/x86_64-linux-gnu/libgmp.so ] || ln -sf libgmp.so.10 /usr/lib/x86_64-linux-gnu/libgmp.so
id postgres >/dev/null 2>&1 || useradd -r postgres
if [ -d /opt/pgdata ]; then
  chown -R postgres /opt/pgdata /opt/pgsock
  su postgres -s /bin/sh -c "/usr/lib/postgresql/16/bin/pg_ctl -D /opt/pgdata -l /opt/pgdata/log.txt start" >/dev/null
fi
# Streaming standby on 5433 (for target_session_attrs specs), if created:
#   pg_basebackup -h 127.0.0.1 -U postgres -D /opt/pgstandby -R -X stream; port = 5433 in its conf
if [ -d /opt/pgstandby ]; then
  chown -R postgres /opt/pgstandby
  su postgres -s /bin/sh -c "/usr/lib/postgresql/16/bin/pg_ctl -D /opt/pgstandby -l /opt/pgstandby/log.txt start" >/dev/null
fi
redis-cli ping >/dev/null 2>&1 || redis-server --port 6379 --save "" --appendonly no --daemonize yes >/dev/null
sleep 2
redis-cli ping
psql -h 127.0.0.1 -U postgres -d crystal_test -Atc "select 'postgres ok'"
cat <<'ENV'
export PATH=/opt/crystal-boot/crystal-1.21.0-1/bin:$PATH
export POSTGRES_URL="postgres://postgres@127.0.0.1:5432/crystal_test?sslmode=disable"
export POSTGRES_MD5_URL="postgres://crystal_md5:md5pass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_CLEARTEXT_URL="postgres://crystal_clear:clearpass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_SCRAM_URL="postgres://crystal_scram:scrampass@127.0.0.1/crystal_test?sslmode=disable"
export POSTGRES_SSL_URL="postgres://crystal_ssl:sslpass@127.0.0.1/crystal_test"
export POSTGRES_STANDBY_URL="postgres://postgres@127.0.0.1:5433/crystal_test?sslmode=disable"
ENV
