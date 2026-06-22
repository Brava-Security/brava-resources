#!/bin/bash

set -euo pipefail

# Applies an Azure Monitor diagnostic setting to every Key Vault in a given
# region, streaming logs to an Event Hub that Brava reads from.
#
# Run it once per region that contains Key Vaults. Set the target subscription
# first with `az account set --subscription <id>`.
#
# Usage:
#   ./azure-keyvault-diagnostics-to-eventhub.sh \
#       --region <region> \
#       --event-hub-rule <event-hub-authorization-rule-id> \
#       --event-hub <event-hub-name> \
#       [--name <diagnostic-setting-name>]
#
# Example:
#   ./azure-keyvault-diagnostics-to-eventhub.sh \
#       --region northcentralus \
#       --event-hub-rule "/subscriptions/.../authorizationRules/RootManageSharedAccessKey" \
#       --event-hub "brava-keyvault-eventhub" \
#       --name "KeyVault-Logs-to-EventHub"

# Defaults
DIAG_NAME="lkv-logs-to-brava-eventhub"
REGION=""
EVENT_HUB_RULE_ID=""
EVENT_HUB_NAME=""

usage() {
    cat <<EOF
Usage: $0 --region <region> --event-hub-rule <rule-id> --event-hub <name> [--name <diagnostic-setting-name>]

Required:
  --region          Azure region to target (e.g. northcentralus)
  --event-hub-rule  Event Hub authorization rule ID
  --event-hub       Event Hub name

Optional:
  --name            Diagnostic setting name (default: "$DIAG_NAME")
  -h, --help        Show this help and exit
EOF
}

# Ensures an option that expects a value actually received one, and that the
# value is not another flag — guards against typos and swapped argument order
# (e.g. "--event-hub-rule --event-hub" would otherwise store "--event-hub" as
# the rule ID, pass the emptiness checks below, and call az with garbage).
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

# Parse named arguments
while [ $# -gt 0 ]; do
    case "$1" in
        --region)
            require_value "$1" "$#" "${2:-}"; REGION="$2"; shift 2 ;;
        --event-hub-rule)
            require_value "$1" "$#" "${2:-}"; EVENT_HUB_RULE_ID="$2"; shift 2 ;;
        --event-hub)
            require_value "$1" "$#" "${2:-}"; EVENT_HUB_NAME="$2"; shift 2 ;;
        --name)
            require_value "$1" "$#" "${2:-}"; DIAG_NAME="$2"; shift 2 ;;
        -h|--help)
            usage; exit 0 ;;
        *)
            echo "Unknown argument: $1" >&2
            usage
            exit 1 ;;
    esac
done

# Validate required arguments
MISSING=""
[ -z "$REGION" ] && MISSING="$MISSING --region"
[ -z "$EVENT_HUB_RULE_ID" ] && MISSING="$MISSING --event-hub-rule"
[ -z "$EVENT_HUB_NAME" ] && MISSING="$MISSING --event-hub"

if [ -n "$MISSING" ]; then
    echo "Error: missing required argument(s):$MISSING" >&2
    echo >&2
    usage
    exit 1
fi

# Get a list of Key Vault IDs strictly located in the target region
echo "Fetching Key Vaults in $REGION..."
KV_IDS=$(az keyvault list --query "[?location=='$REGION'].id" -o tsv)

if [ -z "$KV_IDS" ]; then
    echo "No Key Vaults found in the '$REGION' region for this subscription."
    exit 1
fi

# Loop through the target region's Key Vaults and apply the settings
EXIT_CODE=0
for KV_ID in $KV_IDS; do
    KV_NAME=$(echo "$KV_ID" | awk -F'/' '{print $NF}')

    echo "--------------------------------------------------------"
    echo "Applying diagnostic settings to Key Vault: $KV_NAME ($REGION)"
    echo "--------------------------------------------------------"

    if az monitor diagnostic-settings create \
        --name "$DIAG_NAME" \
        --resource "$KV_ID" \
        --event-hub-rule "$EVENT_HUB_RULE_ID" \
        --event-hub "$EVENT_HUB_NAME" \
        --logs '[{"categoryGroup": "allLogs", "enabled": true}]' \
        --metrics '[{"category": "AllMetrics", "enabled": true}]'; then
        echo "Successfully configured logging for $KV_NAME"
    else
        echo "Failed to configure logging for $KV_NAME."
        EXIT_CODE=1
    fi
done

echo "--------------------------------------------------------"
echo "Execution completed for $REGION resources."
exit $EXIT_CODE
