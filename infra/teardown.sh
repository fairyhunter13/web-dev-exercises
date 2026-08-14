#!/usr/bin/env bash
#
# Archive, destroy, sweep, and remove the identities last.
#
# The ordering is not cosmetic. Four things in it exist because the obvious
# order is broken:
#
#   - The Lambda zip is built first. data.archive_file reads build/bootstrap,
#     which is gitignored, and a missing file fails during data-source
#     evaluation - before anything is destroyed, but also before anything is
#     diagnosable.
#   - The archive is a hard gate. If it cannot be written, decrypted and parsed,
#     nothing is destroyed.
#   - The OIDC provider and the CI roles are removed from state before the
#     destroy and deleted by CLI after the sweep. They are leaves with no
#     dependencies, so Terraform is free to delete them in the first parallel
#     wave; already-issued credentials survive that, but CloudFront takes 15-25
#     minutes and is the likeliest thing to time out, and a retry could not
#     authenticate at all with no provider left to trust.
#   - The hand-made deployer user is the break-glass identity, so it goes last
#     of all.
#
#   ./teardown.sh              destroy, for real
#   ./teardown.sh --dry-run    every check and a plan, no destroy
set -euo pipefail
# Explicit, not assumed. This runs unattended into a world-readable Actions log,
# and xtrace there would echo every expanded command line - bucket names, user
# names, ARNs - past any log filter.
set +x

cd "$(dirname "$0")"

MARKER=".teardown-complete"
STATE_BUCKET="chat-tfstate-e7ba8e48"
DEPLOYER_USER="chat-demo-deployer"
NAME_PREFIX="${NAME_PREFIX:-chat}"
REGION="${AWS_REGION:-ap-southeast-1}"
DRY_RUN=""

if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

aws_() {
  if [[ -n "${AWS_PROFILE:-}" ]]; then aws --profile "$AWS_PROFILE" "$@"; else aws "$@"; fi
}

step() { echo; echo "==> $*"; }

# ---------------------------------------------------------------- 0. precondition

step "0. Preconditions"

if [[ -f "$MARKER" ]]; then
  echo "already torn down on $(head -1 "$MARKER"); nothing to do"
  exit 0
fi

if [[ "${FAKE_BUILD_MISSING:-}" == "1" ]]; then
  # Proves the precondition catches a missing binary. It has to skip the build
  # *and* hide the file, or on a workstation where the binary already exists the
  # test passes without testing anything.
  echo "(test) hiding build/bootstrap"
  mv build/bootstrap "$(mktemp -d)/bootstrap"
elif [[ ! -f build/bootstrap ]]; then
  echo "building the Lambda binary, without which the destroy cannot even plan"
  mkdir -p build
  OUT="$(pwd)/build/bootstrap"
  (cd ../chat/backend && CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -tags lambda.norpc -trimpath -ldflags="-s -w" -o "$OUT" ./cmd/lambda)
fi
[[ -f build/bootstrap ]] || { echo "ERROR: build/bootstrap is missing; terraform cannot evaluate data.archive_file" >&2; exit 1; }
echo "build/bootstrap present"

terraform init -input=false >/dev/null
resources="$(terraform state list || true)"
if [[ -z "$resources" ]]; then
  echo "ERROR: Terraform state is empty and there is no $MARKER." >&2
  echo "A destroy here would delete nothing and exit 0, which would look like success." >&2
  exit 1
fi
COUNT="$(wc -l <<<"$resources")"
echo "state holds $COUNT resources"

# ---------------------------------------------------------------- 1. archive gate

step "1. Archive gate"
ARCHIVE_DIR="${ARCHIVE_DIR:-$HOME/backups/chat-demo}"
if [[ "${FAKE_ARCHIVE_MISSING:-}" == "1" ]]; then
  echo "ERROR: (test) archive was not produced; destroying nothing" >&2
  exit 1
fi
ARCHIVE="$(./archive.sh --out "$ARCHIVE_DIR" | tail -1)"
if [[ "${FAKE_ARCHIVE_CORRUPT:-}" == "1" ]]; then
  echo "(test) corrupting the archive to prove the gate holds"
  : > "$ARCHIVE"
fi
if ! ./archive.sh --verify "$ARCHIVE"; then
  echo "ERROR: the archive did not verify. Destroying nothing." >&2
  exit 1
fi
echo "archive verified"

if [[ -n "$DRY_RUN" ]]; then
  step "dry run: plan only, from here on nothing is changed"
  terraform plan -destroy -input=false | tail -5
  echo
  echo "dry run complete; $COUNT resources would be destroyed"
  exit 0
fi

# ---------------------------------------------------------------- 2. detach identity

step "2. Removing our own credentials from Terraform's reach"
# `state rm` only forgets them; step 6 deletes them for real, once the sweep has
# confirmed everything else is gone and a retry is no longer needed.
for r in aws_iam_openid_connect_provider.github aws_iam_role.ci aws_iam_role_policy.ci \
         aws_iam_role.teardown aws_iam_role_policy.teardown; do
  terraform state rm "$r" 2>/dev/null || echo "  $r not in state, continuing"
done

# ---------------------------------------------------------------- 3. destroy

step "3. terraform destroy (CloudFront takes 15-25 minutes)"
# Output goes to a file, not to stdout. A destroy prints every resource address
# and a large share of attribute values, and this runs unattended into a
# world-readable Actions log. On failure only the tail is surfaced, which is
# enough to diagnose; the file itself is never uploaded.
if ! terraform destroy -auto-approve -input=false > destroy.log 2>&1; then
  echo "ERROR: destroy failed; last lines follow" >&2
  tail -5 destroy.log >&2
  exit 1
fi

# ---------------------------------------------------------------- 4. sweep

step "4. Sweep"
# A tag sweep alone would pass while most of the stack was still standing: 13 of
# the state instances carry no tags, and IAM and Budgets are not covered by the
# tagging API at all. So each service is asked directly.
fail=0
check() { # name, command output
  local name="$1" out="$2"
  if [[ -z "${out// /}" || "$out" == "None" ]]; then
    echo "  clean: $name"
  else
    # Count, not contents: on failure "$out" is a list of live resource names
    # and ARNs, and this runs into a world-readable log. The full list is in
    # the archive, and the operator can re-run the sweep locally.
    echo "  STILL PRESENT: $name ($(printf '%s' "$out" | wc -w) item(s))"
    fail=1
  fi
}
ACCOUNT="$(aws_ sts get-caller-identity --query Account --output text)"
check "terraform state"  "$(terraform state list || true)"
check "iam roles"        "$(aws_ iam list-roles --query "Roles[?starts_with(RoleName, \`${NAME_PREFIX}-\`)].RoleName" --output text)"
check "budgets"          "$(aws_ budgets describe-budgets --region us-east-1 --account-id "$ACCOUNT" --query 'Budgets[].BudgetName' --output text 2>/dev/null || true)"
check "cloudfront"       "$(aws_ cloudfront list-distributions --query 'DistributionList.Items[].Id' --output text 2>/dev/null || true)"
check "apigatewayv2"     "$(aws_ apigatewayv2 get-apis --region "$REGION" --query 'Items[].ApiId' --output text)"
check "tags $REGION"     "$(aws_ resourcegroupstaggingapi get-resources --region "$REGION" --tag-filters Key=Project,Values=web-dev-exercises --query 'ResourceTagMappingList[].ResourceARN' --output text)"
check "tags us-east-1"   "$(aws_ resourcegroupstaggingapi get-resources --region us-east-1 --tag-filters Key=Project,Values=web-dev-exercises --query 'ResourceTagMappingList[].ResourceARN' --output text)"

if [[ "$fail" != "0" ]]; then
  echo "ERROR: the sweep found survivors. Identities are left in place so this can be retried." >&2
  exit 1
fi

# ---------------------------------------------------------------- 5. cost record

step "5. Cost record"
# The only Cost Explorer call this stack ever makes. $0.01, once, for the record
# that it cost nothing.
aws_ ce get-cost-and-usage --region us-east-1 \
  --time-period Start="$(date -u -d '6 months ago' +%F)",End="$(date -u +%F)" \
  --granularity MONTHLY --metrics UnblendedCost \
  --query 'ResultsByTime[].{month:TimePeriod.Start,cost:Total.UnblendedCost.Amount}' \
  --output table | tee cost-record.txt

# ---------------------------------------------------------------- 6. identities last

step "6. Deleting the identities, break-glass last"
# No "$*" in the failure message. The commands below carry bucket names, user
# names and ARNs as arguments, and this branch fires exactly when teardown
# half-fails unattended into a world-readable log. The step banner above says
# which section failed, which is as much as the log needs.
del() { "$@" 2>/dev/null || echo "  already gone or not deletable"; }

for role in "$NAME_PREFIX-ci-deploy" "$NAME_PREFIX-teardown"; do
  del aws_ iam delete-role-policy --role-name "$role" --policy-name "$role"
  del aws_ iam delete-role --role-name "$role"
done
del aws_ iam delete-open-id-connect-provider \
  --open-id-connect-provider-arn "arn:aws:iam::${ACCOUNT}:oidc-provider/token.actions.githubusercontent.com"

echo "  emptying and deleting the state bucket, which nothing else will remove"
# `[Versions, DeleteMarkers][]` and not `([].Versions[], [].DeleteMarkers[])[]`.
# The second is not valid JMESPath and awscli rejects it at parse time with
# ParamValidation - which `del` below would have swallowed, leaving the bucket
# non-empty, the delete-bucket that follows failing too, and the run reporting
# success with the state bucket still standing. Verified against the live
# bucket before being written here.
#
# Both lists, not just Versions: versioning is on, so every overwrite left a
# delete marker, and a bucket holding only delete markers is still not empty.
# The empty guard matters as well - `delete-objects` rejects an empty Objects
# list, and an already-empty bucket is a success, not a failure.
VERSIONS="$(aws_ s3api list-object-versions --bucket "$STATE_BUCKET" --output json \
  --query '{Objects: [Versions, DeleteMarkers][].{Key:Key,VersionId:VersionId}}' 2>/dev/null || echo '{"Objects":null}')"
if [[ "$(jq -r '.Objects | length // 0' <<<"$VERSIONS")" -gt 0 ]]; then
  del aws_ s3api delete-objects --bucket "$STATE_BUCKET" --delete "$VERSIONS"
else
  echo "  state bucket already empty"
fi
del aws_ s3api delete-bucket --bucket "$STATE_BUCKET" --region "$REGION"

for key in $(aws_ iam list-access-keys --user-name "$DEPLOYER_USER" \
             --query 'AccessKeyMetadata[].AccessKeyId' --output text 2>/dev/null || true); do
  del aws_ iam delete-access-key --user-name "$DEPLOYER_USER" --access-key-id "$key"
done
del aws_ iam delete-user --user-name "$DEPLOYER_USER"

# ---------------------------------------------------------------- 7. finalise

step "7. Done"
# Written, not committed. The marker, destroy.log and cost-record.txt are all
# gitignored: the repository is public and none of them has a reader other than
# the operator, so there is no version of this that is worth a commit.
{
  date -u +%FT%TZ
  echo "archive: $ARCHIVE"
  echo "resources destroyed: $COUNT"
} > "$MARKER"
# Only the first line is echoed. The second is a filesystem path, and this runs
# into a world-readable log; the file itself has the whole record.
echo "  torn down $(head -1 "$MARKER"), $COUNT resources, record in infra/$MARKER"
