#!/usr/bin/env bash
#
# Decide whether it is time to tear the stack down. Runs daily from
# teardown.yml, and by hand.
#
# Two triggers, because the free plan ends on whichever arrives first:
#
#   1. the expiry date, 2027-02-12T03:12:01Z, minus 3 days
#   2. remaining credits at or below $20 of the original $200
#
# The second is not decoration. If anything burns credits - a loop, a script
# pointed at the public WebSocket - the account dies early, and a check that
# only knew the date would fire after everything was already gone.
#
# The condition is `>=`, never `==`. An equality test fires on exactly one
# scheduled run and never fires at all if that run is missed; a `>=` window
# stays true afterwards, so the next run catches it.
#
# FAIL-CLOSED is the property that matters here. A false positive destroys a
# live demo while it is still being reviewed. An API error, an unparseable date,
# an empty response, expired credentials - all of them mean "not yet", never
# "time to destroy". Only an explicitly parsed value that clearly satisfies a
# trigger may fire.
#
#   ./check-expiry.sh              check, and run teardown.sh if it is time
#   ./check-expiry.sh --dry-run    report the decision, take no action
#
# FAKE_PLAN_JSON overrides the API response, for testing the triggers without
# waiting six months or spending credits.
set -euo pipefail
# Explicit, not assumed. This runs unattended into a world-readable Actions log,
# and xtrace there would echo every expanded command line - bucket names, user
# names, ARNs - past any log filter.
set +x

cd "$(dirname "$0")"

MARKER=".teardown-complete"
CREDIT_FLOOR=20
DRY_RUN=""

# The S3 backend block in versions.tf deliberately names no profile, because CI
# has none to name - so with AWS_PROFILE unset it falls through to the default
# credential chain, and this machine's [default] section holds stale keys from
# another account. `terraform state list` then fails ExpiredToken, and the guard
# below swallows it via 2>/dev/null and carries on. That guard is the check
# against destroying nothing and reporting success, so it must not be silently
# disarmed. Default to the demo profile locally; in CI the OIDC credentials
# arrive as environment variables and no profile should be set at all.
if [[ -z "${AWS_PROFILE:-}" && -z "${CI:-}" && -z "${AWS_ACCESS_KEY_ID:-}" ]]; then
  export AWS_PROFILE=chat-demo
  echo "AWS_PROFILE was unset; defaulting to the demo profile"
fi

if [[ "${1:-}" == "--dry-run" ]]; then DRY_RUN=1; fi

now="$(date -u +%s)"

if [[ -f "$MARKER" ]]; then
  echo "already torn down on $(head -1 "$MARKER"), nothing to do"
  exit 0
fi

# Empty state is ambiguous, and the ambiguity is dangerous: `terraform destroy`
# against it deletes nothing and exits 0, so a run that mistook it for "already
# done" would write the marker and report success having destroyed nothing.
# Without the marker to confirm it, empty state is a hard error.
if [[ -f versions.tf ]] && terraform init -input=false -upgrade=false >/dev/null 2>&1; then
  if [[ -z "$(terraform state list 2>/dev/null)" ]]; then
    echo "ERROR: Terraform state is empty and there is no $MARKER." >&2
    echo "Either the state was lost, or the backend is misconfigured. Not proceeding." >&2
    exit 1
  fi
fi

if [[ -n "${FAKE_PLAN_JSON+x}" ]]; then
  plan="$FAKE_PLAN_JSON"
else
  plan="$(aws ${AWS_PROFILE:+--profile "$AWS_PROFILE"} freetier get-account-plan-state \
    --region us-east-1 --output json 2>/dev/null)" || plan=""
fi

if [[ -z "$plan" ]]; then
  echo "could not read the account plan state; treating as not-yet and exiting cleanly"
  exit 0
fi

expiry_raw="$(jq -r '.accountPlanExpirationDate // empty' <<<"$plan" 2>/dev/null || true)"
credits="$(jq -r '.accountPlanRemainingCredits.amount // empty' <<<"$plan" 2>/dev/null || true)"

trigger=""

if [[ -n "$expiry_raw" ]]; then
  if expiry="$(date -u -d "$expiry_raw" +%s 2>/dev/null)"; then
    # Three days, not one. The window used to be 24h, which gave the final
    # archive exactly one unattended attempt with no retry - for a job whose
    # CloudFront destroy alone takes 15-25 minutes, on a schedule GitHub
    # documents as delayable and droppable under load. Three days gives three
    # daily attempts. The cost is three days of demo uptime, well after the
    # review closes; the upper edge still holds, so a window that opened too
    # early cannot destroy a live demo mid-review.
    window_opens=$((expiry - 3 * 86400))
    days_left=$(( (expiry - now) / 86400 ))
    echo "expiry $expiry_raw, $days_left days away; teardown window opens $(date -u -d "@$window_opens" +%FT%TZ)"
    if [[ "$now" -ge "$window_opens" ]]; then trigger="the expiry window is open"; fi
  else
    echo "could not parse the expiry date '$expiry_raw'; treating as not-yet"
  fi
else
  echo "no expiry date in the response; treating as not-yet"
fi

if [[ -n "$credits" ]]; then
  echo "remaining credits: \$$credits"
  # bash cannot compare the decimal AWS returns, so awk does it, and only an
  # unambiguous 1 counts as below the floor.
  if [[ "$(awk -v c="$credits" -v f="$CREDIT_FLOOR" 'BEGIN{print (c+0 <= f) ? 1 : 0}')" == "1" ]]; then
    trigger="${trigger:-credits are down to \$$credits}"
  fi
else
  echo "no credit figure in the response; treating as not-yet"
fi

if [[ -z "$trigger" ]]; then
  echo "no trigger met, nothing to do"
  exit 0
fi

echo "TRIGGER: $trigger"

if [[ -n "$DRY_RUN" ]]; then
  echo "(dry run) would run ./teardown.sh"
  exit 0
fi

exec ./teardown.sh
