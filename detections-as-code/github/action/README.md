# Brava detection validation action

Composite GitHub Action that installs the Brava CLI, validates a list of Google SecOps rules in one mode,
and fails the step when any rule fails. Writes a job summary (one row per rule), annotations on the rule
files, and a results directory with the full JSON per rule.

```yaml
- uses: Brava-Security/brava-resources/detections-as-code/github/action@main
  with:
    api-token: ${{ secrets.BRAVA_API_TOKEN }}
    siem: SecOps Dev
    rules: suspicious_powershell_encoded_command rare_rdp_logon_from_new_source
    mode: test            # test | dry-run | sweep
```

Pin to a tag or commit (`@<sha>`) once adopted. Needs `jq` and Python 3.10+ on the runner; `ubuntu-latest` has both.

## Inputs

| Input | Required | Default | Meaning |
|---|---|---|---|
| `api-token` | yes | | Brava API key with scopes `hygiene:read` and `hygiene:detections:test` |
| `siem` | yes | | SIEM name or id, exactly as `brava siems list` prints it |
| `rules` | yes | | Rule names (the YARA-L `rule <name>`), separated by spaces or newlines |
| `mode` | no | `test` | `test` (checks + synthetic telemetry, dev only), `dry-run` (checks only), `sweep` (full one-rule sweep, refreshes the console) |
| `fail-on` | no | `high` | Lowest finding severity that fails: `critical`, `high`, `medium`, `low`, `none` |
| `strict` | no | `"false"` | `"true"` also fails on no answer (inconclusive or not telemetry-driven) |
| `url` | no | `https://console.brava.security` | Brava console URL |
| `rules-dir` | no | `rules` | Directory searched for each rule's file so annotations land on the right file |
| `results-dir` | no | `brava-results` | Where `summary.md` and `<mode>-<rule>.json` are written |
| `cli-version` | no | latest | Pin `brava-cli`, for example `0.3.0` |
| `python-version` | no | `3.12` | Python for the CLI, 3.10 or later |

## Outputs

| Output | Meaning |
|---|---|
| `failed` | `1` when at least one rule failed, otherwise `0` |
| `summary` | Path to the Markdown summary, for a PR comment or a notification |

The step exits non-zero when `failed` is `1`, so later steps that read the results need `if: always()`.

## Per-rule result

| Result | CLI exit | Meaning |
|---|---|---|
| pass | 0 | Checks passed; the rule fired (`test`) or no finding at or above `fail-on` |
| fail | 2 | A check failed, the rule did not fire, or a finding at or above `fail-on` |
| no answer | 4 | Inconclusive or not telemetry-driven; warning unless `strict` |
| timed out | 3 | Local watcher timeout; the run continues server-side |
| could not start / error | 1 | Unknown rule or SIEM, missing scope, or the SIEM stayed busy past the create timeout |
