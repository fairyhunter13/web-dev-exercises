#!/usr/bin/env bash
#
# The document promises the code runs "directly after copy pasted to any online
# js playground". This script keeps that promise honest: it pulls every fenced
# js and go block out of ANSWERS.md, runs each one on its own, and where the
# document shows a captured output block underneath, diffs against it.
#
# Every block is run. Nothing is skipped and nothing continues past an error.
#
# The one block that needs help is the delay(3000) call, which is the question's
# own, alert() included. A browser has alert() and Node does not, so each js
# block is prefixed with the same console.log substitution js/src/delay.js uses.
# It only defines alert when there is none, so it changes nothing in any other
# block, and the document's code itself is untouched.

set -euo pipefail

# Same reason as the infra scripts: this runs unattended into a world-readable
# Actions log, and xtrace there would echo every expanded command line.
set +x

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
doc="$root/ANSWERS.md"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Split the document into one file per fenced block, plus a manifest of
# "startline endline lang filename". Bare ``` blocks become .txt, and are the
# captured output a code block is checked against.
awk -v out="$work" '
  /^```/ {
    if (!inblock) {
      inblock = 1; start = NR
      lang = substr($0, 4)
      ext = (lang == "js" ? "js" : (lang == "go" ? "go" : (lang == "" ? "txt" : "")))
      if (ext != "") file = sprintf("%s/%05d.%s", out, start, ext)
      next
    }
    inblock = 0
    if (ext != "") print start, NR, (lang == "" ? "out" : lang), file
    ext = ""; file = ""
    next
  }
  inblock && ext != "" { print > file }
' "$doc" > "$work/manifest"

pass=0 fail=0

while read -r start end lang file; do
  [ "$lang" = "out" ] && continue

  label="ANSWERS.md:$start ($lang)"

  got="$work/$start.got"
  if [ "$lang" = "js" ]; then
    run="$work/run-$start.js"
    printf 'globalThis.alert ??= (m) => console.log(m);\n' > "$run"
    cat "$file" >> "$run"
    ok=0; node "$run" > "$got" 2>&1 || ok=$?
  else
    ok=0; (cd "$work" && GOTOOLCHAIN=local go run "$file") > "$got" 2>&1 || ok=$?
  fi

  if [ "$ok" -ne 0 ]; then
    echo "FAIL  $label - exited $ok"
    sed 's/^/        /' "$got"
    fail=$((fail + 1))
    continue
  fi

  # A captured output block, if the document has one within a few lines.
  expected=""
  while read -r s e l f; do
    if [ "$l" = "out" ] && [ "$s" -gt "$end" ] && [ "$s" -le "$((end + 6))" ]; then
      expected="$f"
      break
    fi
  done < "$work/manifest"

  if [ -n "$expected" ]; then
    if ! diff -u "$expected" "$got"; then
      echo "FAIL  $label - output differs from the block at ANSWERS.md"
      fail=$((fail + 1))
      continue
    fi
    echo "ok    $label - ran, output matches the captured block"
  else
    echo "ok    $label - ran"
  fi
  pass=$((pass + 1))
done < "$work/manifest"

echo
echo "$pass ran, $fail failed"
[ "$fail" -eq 0 ]
