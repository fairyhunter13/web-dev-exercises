#!/usr/bin/env bash
#
# Capture everything that dies with the AWS account, encrypted, into one file.
#
# The account is on the Free plan and closes on 2027-02-12, after which AWS
# deletes the resources itself. What it does not preserve is the record: the
# Terraform state, the outputs, and an inventory of what existed. State lives in
# a bucket that dies with the account, so without this there is no copy at all.
#
# Encrypted with `age` to a public recipient key committed alongside this
# script. That asymmetry is the point: writing an archive needs no secret at
# all, so the recipient key is safe to publish and a machine that can produce
# an archive still cannot read one back. Only the private key can.
#
#   ./archive.sh                 write to ~/backups/chat-demo/
#   ./archive.sh --out DIR       write somewhere else
#   ./archive.sh --verify FILE   check an existing archive and exit
#   ./archive.sh --records-only  skip the build artifacts (~12 KB, not ~8.9 MB)
#   ./archive.sh --self-test     exercise the G1/G3 gates, no AWS needed
#
# Deliberately not archived: the `messages` DynamoDB table, which holds whatever
# anyone typed into a public demo including reviewers - other people's text,
# better deleted than kept; and the CloudWatch log groups, which expire on their
# own 7-day retention.
set -euo pipefail
# Explicit, not assumed. This runs unattended into a world-readable Actions log,
# and xtrace there would echo every expanded command line - bucket names, user
# names, ARNs - past any log filter.
set +x

cd "$(dirname "$0")"

RECIPIENT_FILE="archive-recipient.pub"
OUT_DIR="${HOME}/backups/chat-demo"
# Matches var.name_prefix. Every resource this stack owns starts with it, so the
# inventory sweep filters on it rather than on a hardcoded list of names.
NAME_PREFIX="${NAME_PREFIX:-chat}"
VERIFY_ONLY=""
RECORDS_ONLY=""
SELF_TEST=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --out) OUT_DIR="$2"; shift 2 ;;
    --verify) VERIFY_ONLY="$2"; shift 2 ;;
    --records-only) RECORDS_ONLY=1; shift ;;
    --self-test) SELF_TEST=1; shift ;;
    *) echo "unknown argument: $1" >&2; exit 2 ;;
  esac
done

REGION="${AWS_REGION:-ap-southeast-1}"

# Same trap as check-expiry.sh: the S3 backend block names no profile (CI has
# none), so with AWS_PROFILE unset `terraform state pull` falls through to this
# machine's stale [default] credentials and fails ExpiredToken (verified: exit
# 1). `set -e` does abort the run there, so unlike check-expiry.sh this is not a
# silent-failure bug -- it is a local ergonomics fix, so a hand-run archive
# works without remembering the profile.
if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  export AWS_PROFILE=chat-demo
fi

# `aws` takes --profile locally and must not take it in CI, where the OIDC
# credentials arrive in the environment and no profile exists to name.
aws_() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    aws --profile "$AWS_PROFILE" "$@"
  else
    aws "$@"
  fi
}

# The archive is only a backup if it can be read back. Decrypt it, confirm the
# state parses as JSON, and confirm it holds as many resources as Terraform
# currently reports. A truncated or empty archive passes a file-exists check and
# fails this one.
verify_archive() {
  local archive="$1" expected="${2:-}"
  local key="${AGE_KEY_FILE:-$HOME/.config/chat-demo/archive-key.txt}"

  [[ -s "$archive" ]] || { echo "FAIL: archive missing or empty: $archive" >&2; return 1; }

  if [[ ! -r "$key" ]]; then
    # No path interpolation in either line: CI holds no private key, so this
    # branch runs on every scheduled run and its output is world-readable.
    echo "note: no private key available, verifying structure only"
    age --decrypt --identity /dev/null "$archive" >/dev/null 2>&1 && \
      { echo "FAIL: archive decrypted without a key" >&2; return 1; }
    echo "ok: archive is encrypted ($(stat -c%s "$archive") bytes)"
    return 0
  fi

  local tmp; tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' RETURN
  age --decrypt --identity "$key" "$archive" | tar -xzf - -C "$tmp" ||
    { echo "FAIL: archive does not decrypt and extract" >&2; return 1; }

  jq -e '.version and .resources' "$tmp/terraform.tfstate" >/dev/null ||
    { echo "FAIL: terraform.tfstate is not a valid state file" >&2; return 1; }

  local got; got="$(wc -l < "$tmp/state-list.txt")"
  if [[ -n "$expected" && "$got" != "$expected" ]]; then
    echo "FAIL: archive holds $got resources, Terraform reports $expected" >&2
    return 1
  fi

  echo "ok: $archive decrypts, state parses, $got resources"
}

# G3 -- recipient shape. The archive's plaintext cannot be sanitised: the AWS
# account ID appears 203 times across four of the five records, structurally
# (every ARN embeds it), and an archive with zero twelve-digit numbers would
# mean the AWS calls returned nothing. So for a ciphertext that is published
# publicly and permanently, the encryption is the whole of the protection.
#
# age has two modes and only one is safe here. `--recipients-file` with age1…
# X25519 recipients gives an attacker nothing to grind. A passphrase recipient
# would silently convert every published archive into an offline-crackable one,
# retroactively and permanently, since published ciphertext can never be
# recalled. Assert the shape rather than trusting the file to stay as it is.
check_recipients() {
  local file="$1" line found=0
  while read -r line || [[ -n "$line" ]]; do
    [[ -z "$line" || "$line" == \#* ]] && continue
    if [[ ! "$line" =~ ^age1[0-9a-z]{58}$ ]]; then
      # No interpolation of the offending line: this runs into a world-readable
      # log, and the failure is about the key's shape, not its value.
      echo "FAIL: $file holds a non-X25519 recipient; refusing to encrypt" >&2
      return 1
    fi
    found=$((found + 1))
  done < "$file"
  # An empty recipients file makes age encrypt to nobody. Failing closed here
  # matters more than usual: the result would still look like a valid archive.
  [[ "$found" -gt 0 ]] || { echo "FAIL: $file names no recipients" >&2; return 1; }
  echo "ok: $found X25519 recipient(s)"
}

# G1 -- staged manifest. A shape gate, not a content scan: see G3 for why a
# content scan is impossible here. This asserts only that no *unexpected* file
# joined the set, so a later step that stages a credential, a tfvars or a raw
# log cannot have it swept into the tarball unnoticed. The five records are
# required; the two build artifacts are permitted only outside --records-only,
# and are optional even there because either source may legitimately be absent.
check_staged_set() {
  local stage="$1" records_only="$2" want got
  local expected="account-plan.json inventory.txt outputs.json state-list.txt terraform.tfstate"
  local allowed="$expected"
  [[ -z "$records_only" ]] && allowed="$allowed bootstrap frontend-dist.tar.gz"

  for want in $expected; do
    [[ -f "$stage/$want" ]] || { echo "FAIL: staged set is missing $want" >&2; return 1; }
  done
  while IFS= read -r got; do
    case " $allowed " in
      *" $got "*) ;;
      *) echo "FAIL: unexpected file in the staged set: $got" >&2; return 1 ;;
    esac
  done < <(find "$stage" -mindepth 1 -printf '%P\n')
  echo "ok: staged set is exactly the expected files"
}

# Exercises both gates against synthetic inputs, so they can be proven to fail
# when they should without an AWS account or a real archive. A gate that has
# only ever been observed passing has not been tested.
if [[ -n "$SELF_TEST" ]]; then
  t="$(mktemp -d)"; trap 'rm -rf "$t"' EXIT
  rc=0
  ok() { echo "ok    $1"; }
  bad() { echo "FAIL  $1"; rc=1; }

  printf 'age1%058d\n' 0 | tr '0' 'q' > "$t/good.pub"
  check_recipients "$t/good.pub" >/dev/null && ok "valid X25519 recipient accepted" \
    || bad "valid X25519 recipient rejected"

  : > "$t/empty.pub"
  check_recipients "$t/empty.pub" >/dev/null 2>&1 && bad "empty recipients file accepted" \
    || ok "empty recipients file rejected"

  echo "not-an-age-key" > "$t/bad.pub"
  check_recipients "$t/bad.pub" >/dev/null 2>&1 && bad "non-X25519 recipient accepted" \
    || ok "non-X25519 recipient rejected"

  # The real file must pass, or the gate is wrong rather than the key.
  if [[ -r "$RECIPIENT_FILE" ]]; then
    check_recipients "$RECIPIENT_FILE" >/dev/null && ok "committed recipient file passes" \
      || bad "committed recipient file fails its own gate"
  fi

  mkdir -p "$t/stage"
  for f in account-plan.json inventory.txt outputs.json state-list.txt terraform.tfstate; do
    : > "$t/stage/$f"
  done
  check_staged_set "$t/stage" 1 >/dev/null && ok "exactly the five records accepted" \
    || bad "five records rejected"

  : > "$t/stage/terraform.tfvars"
  check_staged_set "$t/stage" 1 >/dev/null 2>&1 && bad "unexpected staged file accepted" \
    || ok "unexpected staged file rejected"
  rm "$t/stage/terraform.tfvars"

  : > "$t/stage/bootstrap"
  check_staged_set "$t/stage" 1 >/dev/null 2>&1 && bad "bootstrap accepted in --records-only" \
    || ok "bootstrap rejected in --records-only"
  check_staged_set "$t/stage" "" >/dev/null && ok "bootstrap accepted in a full archive" \
    || bad "bootstrap rejected in a full archive"
  rm "$t/stage/bootstrap"

  rm "$t/stage/outputs.json"
  check_staged_set "$t/stage" 1 >/dev/null 2>&1 && bad "missing record accepted" \
    || ok "missing record rejected"

  exit "$rc"
fi

if [[ -n "$VERIFY_ONLY" ]]; then
  verify_archive "$VERIFY_ONLY"
  exit $?
fi

[[ -r "$RECIPIENT_FILE" ]] || { echo "no recipient key at infra/$RECIPIENT_FILE" >&2; exit 1; }

STAMP="$(date -u +%Y-%m-%d)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
STAGE="$WORK/$STAMP"
mkdir -p "$STAGE"

echo "==> Terraform state and outputs"
terraform init -input=false -upgrade=false >/dev/null
terraform state pull > "$STAGE/terraform.tfstate"
terraform state list > "$STAGE/state-list.txt"
# Allowlisted by key, not copied wholesale. `terraform output -json` returns
# whatever outputs.tf happens to declare, so a later output would land in the
# archive without anyone deciding it should. Naming the seven keys makes the
# archive's shape a decision rather than a side effect; an output added and not
# listed here is dropped, which is the safe direction to fail.
terraform output -json 2>/dev/null \
  | jq '{wss_url, site_url, site_bucket, ci_role_arn, teardown_role_arn,
         lambda_function_name, distribution_id}' \
  > "$STAGE/outputs.json" 2>/dev/null || echo '{}' > "$STAGE/outputs.json"
RESOURCE_COUNT="$(wc -l < "$STAGE/state-list.txt")"

# A tag sweep alone would record 8 of 25 resource blocks: 13 state instances
# carry no tags at all, and IAM and Budgets are not covered by the Resource
# Groups Tagging API in the first place. So the inventory is per-service.
echo "==> Resource inventory"
{
  echo "# generated $(date -u +%FT%TZ)"
  echo "## iam roles"
  aws_ iam list-roles --query "Roles[?starts_with(RoleName, \`${NAME_PREFIX}-\`)].[RoleName,Arn]" --output text
  echo "## iam oidc providers"
  aws_ iam list-open-id-connect-providers --output text
  echo "## iam users"
  aws_ iam list-users --query 'Users[].[UserName,Arn]' --output text
  echo "## budgets"
  aws_ budgets describe-budgets --region us-east-1 \
    --account-id "$(aws_ sts get-caller-identity --query Account --output text)" \
    --query 'Budgets[].BudgetName' --output text 2>/dev/null || echo "(none)"
  echo "## cloudfront"
  aws_ cloudfront list-distributions --query 'DistributionList.Items[].[Id,DomainName,Status]' --output text 2>/dev/null || echo "(none)"
  echo "## apigatewayv2"
  aws_ apigatewayv2 get-apis --region "$REGION" --query 'Items[].[ApiId,Name,ProtocolType]' --output text
  echo "## tagged resources, $REGION"
  aws_ resourcegroupstaggingapi get-resources --region "$REGION" \
    --tag-filters Key=Project,Values=web-dev-exercises --query 'ResourceTagMappingList[].ResourceARN' --output text
  echo "## tagged resources, us-east-1"
  aws_ resourcegroupstaggingapi get-resources --region us-east-1 \
    --tag-filters Key=Project,Values=web-dev-exercises --query 'ResourceTagMappingList[].ResourceARN' --output text
} > "$STAGE/inventory.txt" 2>&1

echo "==> Account plan state"
aws_ freetier get-account-plan-state --region us-east-1 --output json > "$STAGE/account-plan.json"

# --records-only drops the build artifacts, which are the only large things
# here: a full archive is 8.9 MB of which 8.7 MB is the Go binary, while the
# five records alone compress to about 12 KB. The binary is rebuildable from
# the pinned commit and the records are not, so the scheduled run takes records
# only and the binary is captured once, at teardown.
#
# The records-only archive IS committed, to infra/archives/, by the weekly CI
# job. That reverses this script's original "nothing produced here is committed"
# stance, knowingly: an encrypted blob in a public repository is still a
# published artifact whose name, size and cadence are readable forever, and the
# PushEvent announcing each one is mirrored off-GitHub within the hour. That
# cost buys the only off-laptop copy of the records, which is the trade taken.
# It is survivable only because the encryption is to an X25519 recipient with no
# passphrase to grind -- see the recipient-shape gate below, which exists to keep
# that true.
if [[ -n "$RECORDS_ONLY" ]]; then
  echo "==> Build artifacts (skipped, --records-only)"
else
  echo "==> Build artifacts"
  if [[ -f build/bootstrap ]]; then
    cp build/bootstrap "$STAGE/bootstrap"
  fi
  if [[ -d ../chat/frontend/dist ]]; then
    tar -czf "$STAGE/frontend-dist.tar.gz" -C ../chat/frontend dist
  fi
fi

check_recipients "$RECIPIENT_FILE"
check_staged_set "$STAGE" "$RECORDS_ONLY"

mkdir -p "$OUT_DIR"
ARCHIVE="$OUT_DIR/$STAMP.age"
# Flat, so an extraction lands the files themselves rather than a dated
# directory the verifier would then have to guess the name of.
tar -czf - -C "$STAGE" . | age --encrypt --recipients-file "$RECIPIENT_FILE" > "$ARCHIVE"

verify_archive "$ARCHIVE" "$RESOURCE_COUNT"
echo "$ARCHIVE"
