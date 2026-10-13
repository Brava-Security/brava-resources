# Detections as code

Validate Google SecOps detection rules from your Git pipeline with the [Brava CLI](https://docs.brava.security/cli/).
Every rule change gets the same evidence a Brava Hygiene sweep and a synthetic-telemetry test produce in the
console, as a check on the pull request, a nightly regression, or a post-deploy verification.

Three modes, one command surface:

| Mode | What Brava does | Writes to the SIEM | Where to run it |
|---|---|---|---|
| `test` | Hygiene checks Q1 routing, Q2 extraction, Q3 normalization, Q6 delivery, then injects a few `SIMULATION`-labelled events and runs Q4: did the rule fire | Yes, 1 to 3 events (never more than 20), kept out of cases, SOAR and dashboards by SecOps itself | Dev SIEM with the injection grant |
| `dry-run` | The same checks, no injection (`brava run test --dry-run`) | No | Any SIEM |
| `sweep` | Every check a full Brava sweep runs for that one rule, plus log-type and feed warnings, then refreshes the rule's row in the Brava console | No | Any SIEM, including read-only production |

## Prerequisites

1. A Google SecOps instance connected to Brava Hygiene. For `test`, the optional detection telemetry testing
   grant on the dev instance (see [Detection telemetry testing](https://docs.brava.security/hygiene/detection-testing/#prerequisites-and-setup)).
2. A Brava API key with scopes `hygiene:read` and `hygiene:detections:test`, created in Settings → API Keys
   from a dedicated integration user (keys stop working if their creator is removed from the tenant).
3. Rules stored as YARA-L files. Brava looks up the live rule by its display name, which is the YARA-L `rule <name>`,
   so your pipeline must deploy a changed rule to the SIEM before validating it.

Check the key once from a terminal:

```bash
pip install brava-cli
export BRAVA_API_TOKEN=brava_…  BRAVA_URL=https://console.brava.security
brava doctor
brava siems list
```

## Layout

| Path | What it is |
|---|---|
| [`github/action/`](github/action/) | A composite GitHub Action: installs the CLI, validates a list of rules, writes a job summary, annotations and a results directory, and fails when a rule fails. Reference it as `Brava-Security/brava-resources/detections-as-code/github/action@main`. |
| [`github/examples/pr-gate.yml`](github/examples/pr-gate.yml) | Changed rules must fire in dev before merge. Sticky PR comment with one row per rule. |
| [`github/examples/nightly-regression.yml`](github/examples/nightly-regression.yml) | Scheduled re-test of a curated list, with a tracking issue on failure. Catches silent field or value drift. |
| [`github/examples/post-deploy-prod-sweep.yml`](github/examples/post-deploy-prod-sweep.yml) | After a merge deploys to production, sweep each changed rule on every production SIEM in parallel. |
| [`github/examples/on-demand.yml`](github/examples/on-demand.yml) | Run any mode on any rules against any SIEM from the Actions tab. |
| [`github/examples/all-in-one.yml`](github/examples/all-in-one.yml) | PR gate, nightly and on-demand in one standalone file without the composite action. |
| [`github/regression-rules.example.txt`](github/regression-rules.example.txt) | Template for the nightly list. Copy to `.brava/regression-rules.txt`. |

## Adopting an example

1. Copy the example into `.github/workflows/` of your detections repo.
2. Add the repo secret `BRAVA_API_TOKEN` and the variables the example names (`BRAVA_SIEM_DEV`, or
   `BRAVA_SIEMS_PROD` as a JSON array). SIEM names must match `brava siems list` exactly.
3. Replace the `Deploy` step with your content-sync command and point `rules-dir` at your rules if they are not under `rules/`.
4. Pin the action to a tag or commit (`...@<sha>`) once you adopt it; `@main` tracks this repo.
5. Optional: branch protection that requires the PR gate check.

## Reading results

Every run produces a job summary with one row per rule, annotations on the rule file for failures and warnings,
and a results directory with the full JSON per rule.

| Result | Meaning |
|---|---|
| pass | Checks passed and the rule fired (`test`), or no finding at or above `fail-on` |
| fail | A check failed, the rule did not fire (`NOT_FIRED`), or a finding at or above the threshold. The annotation carries the suggested fix. |
| no answer | Inconclusive, for example `NOT_TELEMETRY_DRIVEN`, or `BLOCKED_UPSTREAM` because no data for that log type reaches the SIEM. Warning only, unless `strict: "true"`. |
| timed out | The watcher gave up; the run continues server-side and the annotation shows the resume command. |

The underlying CLI exit codes are `0` pass, `1` request or auth error, `2` gate failed, `3` local timeout, `4` no answer.
Verdicts are documented at [Detection telemetry testing → Verdict states](https://docs.brava.security/hygiene/detection-testing/#verdict-states).

## Good to know

- Brava runs one sweep and one test at a time per SIEM. The examples queue runs with a concurrency group and the
  CLI retries while the slot is busy, up to 45 minutes by default.
- A `test` can take from under a minute to about 45 minutes, mostly waiting for injected events to become searchable.
  Injected events persist for the SIEM's retention period and count toward ingestion quota.
- A sweep's log-type and feed warnings never fail the run. If a full Brava sweep is running at the time, the console
  is not refreshed and the row says so; run the sweep again later.
- Rules that read only reference lists or entity graphs settle as `NOT_TELEMETRY_DRIVEN` and are reported as warnings.
- Google SecOps only. Other SIEMs connected to Brava Hygiene can be tested from the console.
