#!/usr/bin/env bash
# Create Fly.io apps for Social Wire gateway, appview, Charybdis, operations, and Tap (dev + prod).
#
# Prereqs: flyctl installed and logged in (`fly auth login`), or `FLY_API_TOKEN` in CI.
# Optional: FLY_ORG=your-org-name (else uses flyctl default org).
#
# Usage:
#   bash scripts/fly-create-apps.sh
#   FLY_ORG=stygian-tech bash scripts/fly-create-apps.sh
#
# Deploy scripts call `scripts/fly-ensure-app.sh` per app, so CI also creates apps on first deploy.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

GATEWAY_DEV="${FLY_GATEWAY_APP_DEV:-the-social-wire-dev-gateway}"
GATEWAY_PROD="${FLY_GATEWAY_APP_PROD:-the-social-wire-prod-gateway}"
APPVIEW_DEV="${FLY_APPVIEW_APP_DEV:-the-social-wire-dev-appview}"
APPVIEW_PROD="${FLY_APPVIEW_APP_PROD:-the-social-wire-prod-appview}"
WORKER_DEV="${FLY_APPVIEW_WORKER_APP_DEV:-the-social-wire-dev-appview-worker}"
WORKER_PROD="${FLY_APPVIEW_WORKER_APP_PROD:-the-social-wire-prod-appview-worker}"
OPERATIONS_DEV="${FLY_OPERATIONS_APP_DEV:-the-social-wire-dev-operations}"
OPERATIONS_PROD="${FLY_OPERATIONS_APP_PROD:-the-social-wire-prod-operations}"
TAP_DEV="the-social-wire-dev-tap"
TAP_PROD="the-social-wire-prod-tap"

echo "==> Ensuring Fly apps exist"
bash "$ROOT/scripts/fly-ensure-app.sh" "$GATEWAY_DEV"
bash "$ROOT/scripts/fly-ensure-app.sh" "$GATEWAY_PROD"
bash "$ROOT/scripts/fly-ensure-app.sh" "$APPVIEW_DEV"
bash "$ROOT/scripts/fly-ensure-app.sh" "$APPVIEW_PROD"
bash "$ROOT/scripts/fly-ensure-app.sh" "$WORKER_DEV"
bash "$ROOT/scripts/fly-ensure-app.sh" "$WORKER_PROD"
bash "$ROOT/scripts/fly-ensure-app.sh" "$OPERATIONS_DEV"
bash "$ROOT/scripts/fly-ensure-app.sh" "$OPERATIONS_PROD"
bash "$ROOT/scripts/fly-ensure-app.sh" "$TAP_DEV"
bash "$ROOT/scripts/fly-ensure-app.sh" "$TAP_PROD"

echo ""
echo "==> Done."
echo "Next: set per-app runtime secrets: SUPABASE_DATABASE_URL where used; shared Gateway/AppView and Gateway/Operations HMAC secrets; Operations operator/webhook secrets; and environment-matched TAP_DATABASE_URL/TAP_ADMIN_PASSWORD."
echo "Deploy: CI on push, or run the gateway, appview, Charybdis (appview-worker), operations, and Tap deploy scripts for dev."
