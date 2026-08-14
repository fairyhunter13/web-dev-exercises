#!/usr/bin/env bash
#
# Build, apply, upload, invalidate. The ordering is not obvious: the frontend
# cannot be built until Terraform has produced the WebSocket URL, and Terraform
# cannot create the Lambda until the Go binary exists.
#
#   ./deploy.sh          full deploy
#   ./deploy.sh plan     plan only, changes nothing
#
set -euo pipefail

# Explicit, not assumed. This runs unattended into a world-readable Actions log,
# and xtrace there would echo every expanded command line - bucket names, user
# names, ARNs - past any log filter.
set +x

cd "$(dirname "$0")"

BACKEND=../chat/backend
FRONTEND=../chat/frontend

echo "==> Building the Lambda binary (linux/arm64)"
mkdir -p build
# CGO off so the binary is static: the provided.al2023 image is minimal and a
# dynamically linked binary fails at startup with a missing-loader error that
# surfaces only as a Runtime.InvalidEntrypoint in CloudWatch.
OUT="$(pwd)/build/bootstrap"
(
  cd "$BACKEND"
  CGO_ENABLED=0 GOOS=linux GOARCH=arm64 \
    go build -tags lambda.norpc -trimpath -ldflags="-s -w" -o "$OUT" ./cmd/lambda
)

if [[ "${1:-}" == "plan" ]]; then
  terraform init -input=false
  terraform plan
  exit 0
fi

echo "==> Applying infrastructure"
terraform init -input=false
terraform apply -auto-approve

WSS_URL=$(terraform output -raw wss_url)
BUCKET=$(terraform output -raw site_bucket)
DIST=$(terraform output -raw distribution_id)
# Matches terraform.tfvars.example. Must not be "default".
PROFILE=${AWS_PROFILE:-chat-demo}

echo "==> Building the frontend against ${WSS_URL}"
# The WebSocket URL is baked in at build time: Vite inlines import.meta.env at
# compile time, so this cannot be a runtime environment variable.
VITE_WS_URL="$WSS_URL" npm --prefix "$FRONTEND" run build

echo "==> Uploading to s3://${BUCKET}"
# Hashed assets are immutable and cached for a year; index.html is not hashed,
# so it must never be cached at the edge or a deploy would be invisible to
# anyone with a warm cache.
aws --profile "$PROFILE" s3 sync "$FRONTEND/dist" "s3://$BUCKET" \
  --delete --exclude index.html --cache-control "public,max-age=31536000,immutable"
aws --profile "$PROFILE" s3 cp "$FRONTEND/dist/index.html" "s3://$BUCKET/index.html" \
  --cache-control "no-cache"

echo "==> Invalidating the edge cache"
aws --profile "$PROFILE" cloudfront create-invalidation \
  --distribution-id "$DIST" --paths "/index.html" >/dev/null

echo
echo "Site: $(terraform output -raw site_url)"
echo "WSS:  ${WSS_URL}"
