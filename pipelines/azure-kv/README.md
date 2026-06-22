# Azure Key Vault — Stream diagnostic logs to Event Hub

`azure-keyvault-diagnostics-to-eventhub.sh` enables Azure Monitor diagnostic
settings on **every Key Vault in a region** and streams their logs to an Event
Hub that Brava reads from. It automates [Step 1 of the Azure Key Vault source
setup](https://docs.brava.security/sources/azure-key-vault/) (the per-vault
"Stream to an event hub" diagnostic setting) across all vaults at once instead
of clicking through the Azure Portal one vault at a time.

The Event Hub lives in **your** Azure environment; Brava consumes events from
it. Diagnostic settings are scoped per Key Vault and per subscription, so run
this once for each subscription/region combination that contains Key Vaults.

## Inputs you provide

| Argument | Required | What it is |
|---|---|---|
| `--region` | Yes | Azure region to target, e.g. `northcentralus`. Only Key Vaults in this region are configured. |
| `--event-hub-rule` | Yes | Resource ID of the Event Hub **namespace authorization rule** with Send permission (e.g. `.../namespaces/<ns>/authorizationRules/RootManageSharedAccessKey`). |
| `--event-hub` | Yes | Event Hub (instance) name within that namespace. |
| `--name` | No | Diagnostic setting name. Default: `lkv-logs-to-brava-eventhub`. |

## Run

```bash
# 1. Authenticate and select the subscription that holds your Key Vaults
az login
az account set --subscription "<SUBSCRIPTION_ID>"

# 2. Make the script executable (release assets download without the +x bit)
chmod +x azure-keyvault-diagnostics-to-eventhub.sh

# 3. Apply diagnostic settings to all Key Vaults in the region
./azure-keyvault-diagnostics-to-eventhub.sh \
  --region "<REGION>" \
  --event-hub-rule "<EVENT_HUB_AUTHORIZATION_RULE_ID>" \
  --event-hub "<EVENT_HUB_NAME>"
```

The script is idempotent: re-running it updates the existing diagnostic setting
of the same `--name` rather than creating duplicates. It exits non-zero if any
vault fails to configure, after attempting all of them.

## Notes

- **All log categories** are enabled (`categoryGroup: allLogs`) plus
  `AllMetrics`. To capture only audit events, edit the `--logs` array in the
  script to `[{"category": "AuditEvent", "enabled": true}]`.
- **Per region** — run once per region that contains Key Vaults. Vaults outside
  `--region` are skipped.
- **Per subscription** — `az keyvault list` only sees the active subscription.
  Re-run with a different `az account set --subscription` to cover more.

## Minimum permissions for the user running the script

- `Microsoft.Insights/diagnosticSettings/write` on each target Key Vault
  (covered by **Monitoring Contributor** or **Contributor** at the
  subscription, resource group, or Key Vault scope).
- `Microsoft.KeyVault/vaults/read` to list the vaults (covered by **Reader**).
- Send/Manage rights on the Event Hub authorization rule referenced by
  `--event-hub-rule`.
