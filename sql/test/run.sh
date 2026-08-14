#!/usr/bin/env bash
#
# Runs each answer query against the synthetic fixtures and diffs the result
# against the checked-in expected output. Exits non-zero on any mismatch.
#
#   ./run.sh
#
set -euo pipefail

cd "$(dirname "$0")"

SQL_DIR=..
FAIL=0

for level in 1 2 3; do
  answer=$(ls "$SQL_DIR"/level${level}_*.sql)
  actual=$(sqlite3 -header -list -separator '|' ":memory:" \
    ".read schema.sql" ".read seed.sql" ".read $answer")
  expected=$(cat "expected/level${level}.txt")

  if [[ "$actual" != "$expected" ]]; then
    echo "level${level}: MISMATCH"
    diff <(echo "$expected") <(echo "$actual") || true
    FAIL=1
  else
    echo "level${level}: ok"
  fi
done

exit $FAIL
