#!/usr/bin/env bash
# 로컬 Postgres(16)에 스텁 + 마이그레이션을 올리고 테스트를 돌린다.
# 사용법: DATABASE_URL=postgres://postgres@localhost:5432/postgres supabase/tests/run_local.sh
set -euo pipefail
cd "$(dirname "$0")/../.."

DB_URL="${DATABASE_URL:-postgres://postgres@localhost:5432/postgres}"
TEST_DB="badminton_test_$$"

psql "$DB_URL" -q -c "drop database if exists ${TEST_DB}" -c "create database ${TEST_DB}"
TEST_URL="${DB_URL%/*}/${TEST_DB}"
trap 'psql "$DB_URL" -q -c "drop database if exists ${TEST_DB}" >/dev/null 2>&1 || true' EXIT

psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f supabase/tests/local_stub.sql
for f in supabase/migrations/*.sql; do
  psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$f"
done
# m1, m2, … m10 순서 (이름순이면 m10이 m1보다 먼저 돈다)
for t in $(ls supabase/tests/m*_test.sql | sort -V); do
  echo "== $t"
  psql "$TEST_URL" -q -v ON_ERROR_STOP=1 -f "$t"
done
