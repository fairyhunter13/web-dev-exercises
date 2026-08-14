#!/usr/bin/env bash
#
# Run a Go module's tests and fail if any package covers less than 80% of its
# statements. Packages named after the module are reported but not gated.
#
#   scripts/check-go-coverage.sh chat/backend cmd/lambda cmd/localserver
#
# The gate is a floor, not the goal. If a package cannot honestly reach 80%,
# the right move is to add it to the ungated list here with a reason, not to
# lower the threshold for everything.

set -euo pipefail

# Same reason as the infra scripts: this runs unattended into a world-readable
# Actions log, and xtrace there would echo every expanded command line.
set +x

threshold=80

module="${1:?usage: check-go-coverage.sh <module-dir> [ungated-pkg-suffix...]}"
shift
ungated=("$@")

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$root/$module"

export GOTOOLCHAIN=local
out="$(go test -race -cover ./... 2>&1)" || { echo "$out"; exit 1; }
echo "$out"
echo

fail=0
while read -r line; do
  # go test prints one line per package. A package with tests reports
  # "ok <pkg> 0.1s coverage: 88.0% of statements"; one without prints the
  # same coverage suffix with no "ok", or "? <pkg> [no test files]". A
  # package with no tests is 0%, and must not slip through unnoticed.
  case "$line" in
    *'coverage:'*) pct="$(sed -E 's/.*coverage: ([0-9.]+)% of statements.*/\1/' <<<"$line")" ;;
    *'[no test files]'*) pct="0.0" ;;
    *) continue ;;
  esac
  pkg="$(tr -s ' \t' '\n' <<<"$line" | grep -m1 "$(head -1 go.mod | awk '{print $2}')" || true)"
  [ -n "$pkg" ] || continue

  skip=""
  for u in ${ungated[@]+"${ungated[@]}"}; do
    case "$pkg" in */"$u") skip=1 ;; esac
  done

  if [ -n "$skip" ]; then
    printf 'not gated  %6s%%  %s\n' "$pct" "$pkg"
    continue
  fi

  if awk -v p="$pct" -v t="$threshold" 'BEGIN { exit !(p + 0 < t) }'; then
    printf 'UNDER %d%%  %6s%%  %s\n' "$threshold" "$pct" "$pkg"
    fail=1
  else
    printf 'ok         %6s%%  %s\n' "$pct" "$pkg"
  fi
done <<<"$out"

exit "$fail"
