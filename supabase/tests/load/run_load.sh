#!/usr/bin/env bash
# 동시 신청 부하 테스트 (로컬 Postgres + pgbench)
# 사용법: DATABASE_URL=postgres://postgres@localhost:5432/postgres supabase/tests/load/run_load.sh
# max_connections가 150 이상이어야 한다.
set -euo pipefail
cd "$(dirname "$0")/../../.."
DB_URL="${DATABASE_URL:-postgres://postgres@localhost:5432/postgres}"
TEST_DB="badminton_load_$$"
LOAD=supabase/tests/load
LOGDIR=$(mktemp -d)

psql "$DB_URL" -q -c "create database ${TEST_DB}"
TEST_URL="${DB_URL%/*}/${TEST_DB}"
trap 'psql "$DB_URL" -q -c "drop database if exists ${TEST_DB}" >/dev/null 2>&1 || true; rm -rf "$LOGDIR"' EXIT

psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f supabase/tests/local_stub.sql
for f in supabase/migrations/*.sql; do psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$f"; done
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$LOAD/setup.sql"

p95() { # pgbench -l 로그의 3번째 열 = 트랜잭션 지연(us)
  awk '{print $3}' "$@" | sort -n | awk '{a[NR]=$1} END {i=int(NR*0.95); if(i<1)i=1; printf "n=%d p50=%.1fms p95=%.1fms max=%.1fms\n", NR, a[int(NR*0.5)]/1000, a[i]/1000, a[NR]/1000}'
}

echo "== S1: 서로 다른 회원 100명 동시 신청 (정원 30)"
(cd "$LOGDIR" && pgbench -n -c 100 -j 16 -t 1 -l --log-prefix=s1 -f "$OLDPWD/$LOAD/register_s1.sql" "$TEST_URL" >/dev/null)
p95 "$LOGDIR"/s1*

echo "== S2: 회원 50명이 각각 2번씩 동시 신청"
(cd "$LOGDIR" && pgbench -n -c 100 -j 16 -t 1 -l --log-prefix=s2 -f "$OLDPWD/$LOAD/register_s2_dup.sql" "$TEST_URL" >/dev/null)
p95 "$LOGDIR"/s2*

echo "== S3: 확정자 20명 취소 + 새 회원 40명 신청 동시 진행"
(cd "$LOGDIR" && pgbench -n -c 20 -j 8 -t 1 -l --log-prefix=s3c -f "$OLDPWD/$LOAD/cancel_s3.sql" "$TEST_URL" >/dev/null) &
(cd "$LOGDIR" && pgbench -n -c 40 -j 8 -t 1 -l --log-prefix=s3r -f "$OLDPWD/$LOAD/register_s3.sql" "$TEST_URL" >/dev/null) &
wait
p95 "$LOGDIR"/s3*

echo "== 검증"
psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$LOAD/verify.sql"
