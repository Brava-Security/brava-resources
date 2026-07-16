#!/bin/bash

set -euo pipefail

# ---------------------------------------------------------------------------
# Brava Attack Simulation — Azure Footprint (Azure CLI, no Terraform)
#
# Creates the Entra ID app registration the Brava runner authenticates AS to
# execute attack simulations and collect telemetry in a subscription. This is
# the exact same footprint produced by runner_footprint_role_azure.tf, built
# with plain `az` commands for environments that don't use Terraform.
#
# It creates (or reuses, if already present):
#   * an Entra ID app registration + service principal
#   * either a federated identity credential trusting Brava's AWS Cognito
#     (Workload Identity Federation — the default, no secret leaves your
#     tenant) OR a client secret you hand to Brava (fallback)
#   * four subscription-scoped role assignments: Contributor, Role Based
#     Access Control Administrator, Security Reader, Monitoring Reader
#
# The script is idempotent — re-running it reuses the existing app, service
# principal, federated credential, and role assignments rather than
# duplicating them. One exception: in --auth-mode secret each run rotates the
# client secret (az ad app credential reset), invalidating the previous one —
# re-register the new secret in Brava after a re-run.
#
# When it finishes it prints the three (or four) values you submit to Brava:
#   Tenant ID, Client ID, Subscription ID [, Client Secret in --auth-mode secret]
#
# Register them in Brava: Detections -> Settings -> Runners -> Add Azure
# Footprint.
#
# Usage:
#   ./runner_footprint_role_azure.sh \
#       --subscription <subscription-name-or-id> \
#       --cognito-pool-id <from Brava> \
#       --cognito-identity-id <from Brava>
#
# Client-secret fallback (no federation):
#   ./runner_footprint_role_azure.sh \
#       --subscription <subscription-name-or-id> \
#       --auth-mode secret
#
# Prerequisites:
#   * Azure CLI (`az`) installed and logged in (`az login`).
#   * Permission in the tenant to create app registrations and, on the target
#     subscription, to assign roles (Owner or User Access Administrator).
# ---------------------------------------------------------------------------

# ── Defaults ────────────────────────────────────────────────────────────────
APPLICATION_NAME="brava-attack-simulation-footprint"
AUTH_MODE="wif"                 # wif | secret
FIC_NAME="brava-aws-cognito-oidc"
COGNITO_ISSUER="https://cognito-identity.amazonaws.com"
SECRET_EXPIRY_YEARS="1"
SUBSCRIPTION=""                 # name or id (resolved to id below)
TENANT_ID=""                    # optional; derived from the resolved subscription
COGNITO_POOL_ID=""
COGNITO_IDENTITY_ID=""
VERBOSE="false"

# The four subscription-scoped roles the footprint needs — write access to run
# simulations, RBAC admin for identity-tactic steps, and read access for
# telemetry collection. Kept in lock-step with runner_footprint_role_azure.tf.
FOOTPRINT_ROLES=(
    "Contributor"
    "Role Based Access Control Administrator"
    "Security Reader"
    "Monitoring Reader"
)

usage() {
    cat <<EOF
Usage: $0 --subscription <name-or-id> [options]

Creates the Brava attack-simulation footprint app in your Entra tenant and
grants it the roles needed to run simulations and collect telemetry in the
target subscription. Safe to re-run (idempotent).

Required:
  --subscription <name-or-id>   Target subscription (accepts the display name
                                or the subscription ID).

Required in WIF mode (the default — see --auth-mode):
  --cognito-pool-id <id>        Brava Cognito Identity Pool ID (from Brava).
  --cognito-identity-id <id>    Brava Cognito Identity ID (from Brava).
                                Find both in Detections -> Settings -> Runners.

Optional:
  --auth-mode <wif|secret>      wif (default): trust Brava via Workload Identity
                                Federation, no secret. secret: generate a client
                                secret to hand to Brava instead.
  --tenant-id <id>              Entra tenant ID. Defaults to the target
                                subscription's tenant.
  --application-name <name>     App registration display name
                                (default: "$APPLICATION_NAME").
  --secret-expiry-years <n>     Client secret lifetime in years, secret mode
                                only (default: $SECRET_EXPIRY_YEARS).
  --verbose                     Print each az command as it runs.
  -h, --help                    Show this help and exit.

Examples:
  # Workload Identity Federation (recommended, no secret)
  $0 --subscription "Production" \\
     --cognito-pool-id us-east-1:aaaa-bbbb \\
     --cognito-identity-id us-east-1:cccc-dddd

  # Client-secret fallback
  $0 --subscription 00000000-0000-0000-0000-000000000000 --auth-mode secret
EOF
}

# ── Small helpers ─────────────────────────────────────────────────────────────

# Emit only when --verbose is set.
vlog() {
    [ "$VERBOSE" = "true" ] && echo "  + $*" >&2 || true
}

# Run an az command, echoing it first in verbose mode. Keeps az output quiet
# unless there's an error so the final summary stays readable.
az_run() {
    vlog "az $*"
    az "$@" --only-show-errors
}

# Ensures an option that expects a value actually received one, and that the
# value isn't another flag — guards against typos and swapped argument order.
require_value() {
    # $1 = option name, $2 = remaining arg count ($#), $3 = candidate value
    local opt="$1" remaining="$2" value="${3:-}"
    if [ "$remaining" -lt 2 ]; then
        echo "Error: option $opt requires a value." >&2
        usage
        exit 1
    fi
    case "$value" in
        -*)
            echo "Error: option $opt requires a value, but got '$value' (which looks like another option)." >&2
            usage
            exit 1 ;;
    esac
}

# ── Parse named arguments ─────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --subscription)
            require_value "$1" "$#" "${2:-}"; SUBSCRIPTION="$2"; shift 2 ;;
        --tenant-id)
            require_value "$1" "$#" "${2:-}"; TENANT_ID="$2"; shift 2 ;;
        --auth-mode)
            require_value "$1" "$#" "${2:-}"; AUTH_MODE="$2"; shift 2 ;;
        --application-name)
            require_value "$1" "$#" "${2:-}"; APPLICATION_NAME="$2"; shift 2 ;;
        --cognito-pool-id)
            require_value "$1" "$#" "${2:-}"; COGNITO_POOL_ID="$2"; shift 2 ;;
        --cognito-identity-id)
            require_value "$1" "$#" "${2:-}"; COGNITO_IDENTITY_ID="$2"; shift 2 ;;
        --secret-expiry-years)
            require_value "$1" "$#" "${2:-}"; SECRET_EXPIRY_YEARS="$2"; shift 2 ;;
        --verbose)
            VERBOSE="true"; shift ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

# ── Validate arguments ────────────────────────────────────────────────────────
case "$AUTH_MODE" in
    wif|secret) ;;
    *)
        echo "Error: --auth-mode must be 'wif' or 'secret', got '$AUTH_MODE'." >&2
        exit 1 ;;
esac

MISSING=""
[ -z "$SUBSCRIPTION" ] && MISSING="$MISSING --subscription"
if [ "$AUTH_MODE" = "wif" ]; then
    [ -z "$COGNITO_POOL_ID" ] && MISSING="$MISSING --cognito-pool-id"
    [ -z "$COGNITO_IDENTITY_ID" ] && MISSING="$MISSING --cognito-identity-id"
fi

if [ -n "$MISSING" ]; then
    echo "Error: missing required argument(s):$MISSING" >&2
    if [ "$AUTH_MODE" = "wif" ]; then
        echo "(--cognito-pool-id / --cognito-identity-id are required in WIF mode; use --auth-mode secret to skip them.)" >&2
    fi
    echo >&2
    usage
    exit 1
fi

case "$SECRET_EXPIRY_YEARS" in
    ''|*[!0-9]*)
        echo "Error: --secret-expiry-years must be a whole number, got '$SECRET_EXPIRY_YEARS'." >&2
        exit 1 ;;
esac

# ── Preflight: az present and logged in ───────────────────────────────────────
if ! command -v az >/dev/null 2>&1; then
    echo "Error: the Azure CLI ('az') is not installed or not on PATH." >&2
    echo "Install it: https://learn.microsoft.com/cli/azure/install-azure-cli" >&2
    exit 1
fi

if ! az account show >/dev/null 2>&1; then
    echo "Error: you are not logged in to Azure. Run 'az login' first." >&2
    exit 1
fi

# ── Resolve the subscription (name or id) to its ID and tenant ────────────────
echo "Resolving subscription '$SUBSCRIPTION'..."
if ! az account show --subscription "$SUBSCRIPTION" -o none --only-show-errors 2>/dev/null; then
    echo "Error: could not find subscription '$SUBSCRIPTION'." >&2
    echo "Check the name/ID and that your account has access ('az account list -o table')." >&2
    exit 1
fi

SUBSCRIPTION_ID=$(az account show --subscription "$SUBSCRIPTION" --query id -o tsv --only-show-errors)
SUBSCRIPTION_DISPLAY=$(az account show --subscription "$SUBSCRIPTION" --query name -o tsv --only-show-errors)
RESOLVED_TENANT_ID=$(az account show --subscription "$SUBSCRIPTION" --query tenantId -o tsv --only-show-errors)

# If the caller pinned a tenant, make sure it matches the subscription's tenant.
if [ -n "$TENANT_ID" ] && [ "$TENANT_ID" != "$RESOLVED_TENANT_ID" ]; then
    echo "Error: --tenant-id ($TENANT_ID) does not match subscription '$SUBSCRIPTION_DISPLAY' tenant ($RESOLVED_TENANT_ID)." >&2
    exit 1
fi
TENANT_ID="$RESOLVED_TENANT_ID"
ROLE_SCOPE="/subscriptions/${SUBSCRIPTION_ID}"

# Pin the CLI context to the target subscription. `az ad` (Microsoft Graph)
# operates against the tenant of the *active* subscription — not against
# --subscription — so without this the app + service principal could be created
# in the wrong tenant when the operator's default subscription lives elsewhere
# (multi-tenant / CSP / guest-access setups). Setting it here keeps both Graph
# and ARM (role assignments) targeting this subscription's tenant.
az_run account set --subscription "$SUBSCRIPTION_ID"

echo "  Subscription : $SUBSCRIPTION_DISPLAY ($SUBSCRIPTION_ID)"
echo "  Tenant       : $TENANT_ID"
echo "  Auth mode    : $AUTH_MODE"
echo

# ── App registration + service principal (find-or-create) ─────────────────────
echo "Ensuring app registration '$APPLICATION_NAME'..."
APP_ID=$(az ad app list --display-name "$APPLICATION_NAME" --query "[0].appId" -o tsv --only-show-errors)

if [ -z "$APP_ID" ]; then
    APP_ID=$(az_run ad app create --display-name "$APPLICATION_NAME" --query appId -o tsv)
    echo "  Created app registration ($APP_ID)."
else
    echo "  Reusing existing app registration ($APP_ID)."
fi

# Service principal for the app (find-or-create). A just-created app can take a
# moment to replicate, so `sp create` may briefly fail with "does not reference
# a valid application object" — retry to ride out that propagation delay.
SP_OBJECT_ID=$(az ad sp list --filter "appId eq '$APP_ID'" --query "[0].id" -o tsv --only-show-errors)
if [ -z "$SP_OBJECT_ID" ]; then
    attempt=1 max_attempts=6
    while :; do
        if SP_OBJECT_ID=$(az_run ad sp create --id "$APP_ID" --query id -o tsv 2>/dev/null) \
            && [ -n "$SP_OBJECT_ID" ]; then
            break
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "Error: failed to create service principal for app $APP_ID after $attempt attempts." >&2
            exit 1
        fi
        vlog "service principal not created yet (attempt $attempt/$max_attempts); waiting for app propagation..."
        sleep 10
        attempt=$((attempt + 1))
    done
    echo "  Created service principal ($SP_OBJECT_ID)."
else
    echo "  Reusing existing service principal ($SP_OBJECT_ID)."
fi
echo

# ── Credential: WIF federated credential OR client secret ─────────────────────
CLIENT_SECRET=""
if [ "$AUTH_MODE" = "wif" ]; then
    echo "Configuring Workload Identity Federation (no secret)..."
    EXISTING_FIC=$(az ad app federated-credential list --id "$APP_ID" \
        --query "[?name=='$FIC_NAME'].id" -o tsv --only-show-errors)

    FIC_PARAMS=$(cat <<JSON
{
  "name": "$FIC_NAME",
  "issuer": "$COGNITO_ISSUER",
  "subject": "$COGNITO_IDENTITY_ID",
  "audiences": ["$COGNITO_POOL_ID"],
  "description": "Trusts the Brava attack-simulation runner via AWS Cognito Workload Identity Federation."
}
JSON
)

    if [ -z "$EXISTING_FIC" ]; then
        az_run ad app federated-credential create --id "$APP_ID" --parameters "$FIC_PARAMS" >/dev/null
        echo "  Created federated identity credential '$FIC_NAME'."
    else
        # Update in place so a re-run with new Cognito values corrects the trust.
        az_run ad app federated-credential update --id "$APP_ID" \
            --federated-credential-id "$FIC_NAME" --parameters "$FIC_PARAMS" >/dev/null
        echo "  Updated existing federated identity credential '$FIC_NAME'."
    fi
else
    echo "Generating client secret (valid $SECRET_EXPIRY_YEARS year(s))..."
    CLIENT_SECRET=$(az_run ad app credential reset --id "$APP_ID" \
        --display-name "brava-attack-simulation" \
        --years "$SECRET_EXPIRY_YEARS" \
        --query password -o tsv)
    echo "  Generated a new client secret."
fi
echo

# ── Subscription RBAC (idempotent, with propagation retry) ────────────────────
echo "Assigning subscription roles..."

assign_role() {
    local role="$1"
    # az role assignment create is idempotent — it no-ops if the assignment
    # already exists. Retry to ride out service-principal propagation delay.
    local attempt=1 max_attempts=6
    while :; do
        if az_run role assignment create \
            --assignee-object-id "$SP_OBJECT_ID" \
            --assignee-principal-type ServicePrincipal \
            --role "$role" \
            --scope "$ROLE_SCOPE" >/dev/null 2>&1; then
            echo "  [ok] $role"
            return 0
        fi
        if [ "$attempt" -ge "$max_attempts" ]; then
            echo "  [FAILED] $role (after $attempt attempts)" >&2
            return 1
        fi
        vlog "role '$role' not assigned yet (attempt $attempt/$max_attempts); waiting for SP propagation..."
        sleep 10
        attempt=$((attempt + 1))
    done
}

RBAC_FAILED=0
for ROLE in "${FOOTPRINT_ROLES[@]}"; do
    assign_role "$ROLE" || RBAC_FAILED=1
done
echo

if [ "$RBAC_FAILED" -ne 0 ]; then
    echo "Error: one or more role assignments failed. You likely lack permission to" >&2
    echo "assign roles on this subscription (need Owner or User Access Administrator)." >&2
    echo "The app and credential were created — re-run once permissions are granted." >&2
    exit 1
fi

# ── Summary — submit these to Brava ───────────────────────────────────────────
echo "========================================================"
echo "Footprint ready. Register it in Brava:"
echo "  Detections -> Settings -> Runners -> Add Azure Footprint"
echo "--------------------------------------------------------"
echo "  Tenant ID        : $TENANT_ID"
echo "  Client ID        : $APP_ID"
echo "  Subscription ID  : $SUBSCRIPTION_ID"
if [ "$AUTH_MODE" = "secret" ]; then
    echo "  Client Secret    : $CLIENT_SECRET"
    echo
    echo "  Store the client secret now — Azure will not show it again."
    echo "  Note: re-running this script in secret mode rotates the secret and"
    echo "  invalidates this one — re-register the new value in Brava if you do."
else
    echo "  Client Secret    : (none — Workload Identity Federation; leave blank in Brava)"
fi
echo "========================================================"
