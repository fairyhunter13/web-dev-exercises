#!/usr/bin/env bash
#
# Fail if a tracked file or a commit message contains an address, a host or an
# account number that has not been vouched for.
#
#   scripts/policy-check.sh              scan the repository
#   scripts/policy-check.sh --self-test  prove each rule can fail, then scan
#
# Three rules, all allowlists:
#
#   1  an RFC-shaped email address that is not one of the two the repo uses
#   2  a URL host that is not one of the documentation sites the repo links,
#      Hafiz's own demo, or a machine-assigned AWS hostname
#   3  any twelve-digit run, which is the shape of an AWS account ID
#
# Allowlists, not denylists, and the direction matters. A denylist would have to
# spell out the string it is protecting - the file would become the leak it
# exists to prevent, committed and public. An allowlist names only things that
# are already meant to be here, so every byte of this script is publishable.
# It also fails in the safe direction: something unanticipated is a failure,
# rather than passing because nobody thought to add it.
#
# The report is deliberately thin. It gives a path, a line and a rule number,
# and never the text that matched: this runs in a public Actions log, so a gate
# that echoed its finding would publish exactly what it caught.
#
# Lockfiles are skipped. package-lock.json alone carries 296 registry hosts and
# a maintainer's address, none of it written here and none of it under this
# repository's control; allowlisting upstream's contents would say nothing
# about whether this repository leaks.
#
# What it does not see: Actions logs, run and job names, artifact contents,
# Terraform error text, and anything a fresh clone pushes without running it.
# It is one layer, not the control.

set -euo pipefail
set +x

cd "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

RE_EMAIL='[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}'
RE_HOST='https?://[A-Za-z0-9._-]+'
RE_ACCOUNT='(^|[^0-9])[0-9]{12}([^0-9]|$)'

allow_email() {
  case "$1" in
    hafizputraludyanto@gmail.com) return 0 ;;
    you@example.com) return 0 ;;  # terraform.tfvars.example
  esac
  return 1
}

allow_host() {
  # Suffix entries cover the two hostnames AWS assigns rather than we choose.
  # They are random by construction and change on every replacement, so pinning
  # them exactly would make a redeploy fail this gate for no gain in safety.
  case "${1#*//}" in
    localhost|example.com|github.com|token.actions.githubusercontent.com) return 0 ;;
    go.dev|goplay.tools|dotnetfiddle.net|web.dev|developer.mozilla.org|www.w3schools.com) return 0 ;;
    docs.aws.amazon.com|pages.nist.gov|owasp.org|cheatsheetseries.owasp.org) return 0 ;;
    vuejs.org|pinia.vuejs.org|vueuse.org) return 0 ;;
    *.cloudfront.net) return 0 ;;
    *.execute-api.*.amazonaws.com) return 0 ;;
  esac
  return 1
}

# Rule 3 has no allowlist. There is no twelve-digit number this repository has
# any reason to contain, so the rule is the allowlist: the empty set.
allow_account() { return 1; }

fail=0

# Every match is tested individually rather than the line as a whole, so a line
# holding one vouched-for host and one unknown one still fails.
scan_files() { # rule, regex, allow-function, file...
  local rule="$1" re="$2" allow="$3"; shift 3
  local line path lineno text m
  while IFS= read -r line; do
    path="${line%%:*}"; line="${line#*:}"
    lineno="${line%%:*}"; text="${line#*:}"
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      "$allow" "$m" || { echo "$path:$lineno: rule $rule"; fail=1; }
    done < <(grep -oE "$re" <<<"$text" || true)
    # -H because grep omits the filename when given exactly one file, and the
    # parse above would then read the line number as the path and cut the text
    # at the first colon - which silently loses every URL.
  done < <(grep -HInE "$re" -- "$@" || true)
}

scan_messages() { # rule, regex, allow-function
  local rule="$1" re="$2" allow="$3"
  local sha body m
  while IFS= read -r sha; do
    body="$(git log -1 --format='%B' "$sha")"
    while IFS= read -r m; do
      [ -n "$m" ] || continue
      "$allow" "$m" || { echo "commit $sha: rule $rule"; fail=1; }
    done < <(grep -oE "$re" <<<"$body" || true)
  done < <(git rev-list --all)
}

self_test() {
  # A gate nobody has seen fail is a gate nobody knows works. Each rule is given
  # something it must reject, in a scratch directory outside the repository.
  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  # Assembled from halves rather than written out, because this file is itself
  # a tracked file that the scan below reads. A literal fixture here would make
  # the checker fail on its own source - which is a fair result, and the wrong
  # one. Neither half matches any rule on its own.
  local bad_host="not-allowed" bad_tld="invalid" bad_acct
  bad_acct="$(printf '%s%s' 123456 789012)"
  printf 'contact someone@%s.%s\n' "$bad_host" "$bad_tld" > "$tmp/a"
  printf 'see https://%s.%s/x\n'   "$bad_host" "$bad_tld" > "$tmp/b"
  printf 'account %s\n'            "$bad_acct"            > "$tmp/c"

  local before="$fail" out
  out="$(
    fail=0
    scan_files 1 "$RE_EMAIL"   allow_email   "$tmp/a"
    scan_files 2 "$RE_HOST"    allow_host    "$tmp/b"
    scan_files 3 "$RE_ACCOUNT" allow_account "$tmp/c"
  )"
  fail="$before"

  local n; n="$(grep -c 'rule' <<<"$out" || true)"
  if [ "$n" != "3" ]; then
    echo "SELF-TEST FAILED: expected 3 findings, got $n" >&2
    exit 1
  fi
  # And the report must not carry the thing it found.
  if grep -qE "$bad_host|$bad_acct" <<<"$out"; then
    echo "SELF-TEST FAILED: the report echoed the match" >&2
    exit 1
  fi
  echo "self-test: 3 rules reject, none echo the match"
}

if [ "${1:-}" = "--self-test" ]; then self_test; shift; fi
[ $# -eq 0 ] || { echo "usage: policy-check.sh [--self-test]" >&2; exit 2; }

mapfile -t FILES < <(git ls-files -- . \
  ':!*package-lock.json' ':!*go.sum' ':!*.terraform.lock.hcl')
[ "${#FILES[@]}" -gt 0 ] || { echo "no tracked files to scan; refusing to pass" >&2; exit 1; }

scan_files 1 "$RE_EMAIL"   allow_email   "${FILES[@]}"
scan_files 2 "$RE_HOST"    allow_host    "${FILES[@]}"
scan_files 3 "$RE_ACCOUNT" allow_account "${FILES[@]}"

scan_messages 1 "$RE_EMAIL"   allow_email
scan_messages 3 "$RE_ACCOUNT" allow_account

if [ "$fail" != "0" ]; then
  echo "policy-check: findings above. Run the same rule locally to see the text." >&2
  exit 1
fi

echo "policy-check: ${#FILES[@]} files and $(git rev-list --all --count) messages, no findings"
