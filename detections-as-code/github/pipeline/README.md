# Detection-as-code pipeline (Google SecOps)

The GitHub Actions workflows from the [Detection-as-Code Pipeline](https://docs.brava.security/hygiene/detection-as-code/)
guide, as files you can copy. The guide explains each stage, the prerequisites in Brava and Google Cloud, and the
settings to change before you use them.

| File | What it is |
|---|---|
| [`detections-pr.yml`](detections-pr.yml) | Stage 1: on pull requests, check every new or changed rule file with Brava. Nothing is uploaded to the SIEM. |
| [`detections-deploy.yml`](detections-deploy.yml) | Stages 2 to 4: on merge, deploy changed rules to Dev with Google's SecOps CLI, test them with Brava's injected telemetry, then deploy them to Prod. |
| [`detections-test.yml`](detections-test.yml) | If you already have a deploy workflow and can't change it: test the rules it deployed after it finishes. Reports only; it can't hold back Prod. |
| [`snippets/brava-test-job.yml`](snippets/brava-test-job.yml) | If you already have a deploy workflow: a `brava-test` job to add between your Dev and Prod jobs. Not a complete workflow. |
| [`snippets/dev-cleanup-after-test.sh`](snippets/dev-cleanup-after-test.sh) | Optional: delete each rule from Dev right after its test. Paste into the `dev` job's loop in `detections-deploy.yml`. |
| [`snippets/dev-cleanup-job.yml`](snippets/dev-cleanup-job.yml) | Optional: delete the tested rules from Dev once they are in Prod. Add under `jobs:` in `detections-deploy.yml`. |

## Using them

1. Copy the workflows you need into your repository's `.github/workflows/` folder.
2. Change what the guide lists under
   [Complete GitHub Actions example](https://docs.brava.security/hygiene/detection-as-code/#complete-github-actions-example):
   the SIEM name (`SecOps Dev` is an example), the rule folder (`rules/`), the branch, and the settings.
3. Add the secrets and variables listed under
   [Store the settings in GitHub](https://docs.brava.security/hygiene/detection-as-code/#store-the-settings-in-github).

The guide is the reference: if a file here and the guide differ, follow the guide.
