# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Self-service web portal that replaces the email-based GA (General Availability) release handover process for Aptean's Foodware 365 BC apps. Dev teams submit a release request through a form; the GA team reviews on a dashboard and triggers automation that bumps versions, updates `app.json`/`appsourcecop.json`/test apps, creates ADO PRs (with reviewers), and creates GA-Release tasks under the requesting Epic.

The tool has grown beyond the original "submit + approve" flow described in `README.md` into a multi-tab GA operations console (rebase scanning, batch branch create/delete, closure-task management, live-tag/AppSource status checks, cutoff-override approval flow).

## Stack

- **Frontend**: vanilla HTML/CSS/JS — no build step, no framework. MSAL.js for Azure AD SSO.
- **Backend**: PowerShell Azure Functions (`FUNCTIONS_WORKER_RUNTIME=powershell`), managed dependency `Az.Storage`.
- **Storage**: Azure Table Storage — tables `GAReleaseRequests` and `GAOverrideRequests` (created on demand by the helpers).
- **External**: Azure DevOps REST API (PAT auth), Power Automate webhook (outbound email), Microsoft Teams incoming webhook (cutoff-override Adaptive Cards).
- **Hosting**: Azure Static Web Apps (Standard SKU — needed for AAD identity provider). A separate GitHub Actions workflow (`.github/workflows/deploy-pages.yml`) publishes **only the frontend** to GitHub Pages on push to `master` — that target has no API and is for static-only previews.

## Common commands

Run from repo root unless noted.

```bash
# Local dev — runs frontend + Functions + reverse proxy on http://localhost:4280
swa start frontend --api-location api

# Local Table Storage (required by Save-RequestToStorage etc.)
# Either use Azurite (a `.azurite/` folder is gitignored, suggesting it's been used) or
# Azure Storage Emulator. STORAGE_CONNECTION_STRING=UseDevelopmentStorage=true picks it up.
azurite --silent --location .azurite

# Deploy infra (ARM template; one-time per environment)
az deployment group create -g <rg> --template-file infra/main.json \
  --parameters adoPatSecretValue=<pat> aadClientId=<id> aadClientSecret=<secret>

# Deploy app to SWA (after CI builds aren't configured here)
swa deploy --deployment-token <token>
```

There is no test suite, linter, or build step. PowerShell modules are auto-installed on cold start via `api/requirements.psd1` and `host.json`'s `managedDependency`.

## Architecture

### Single shared module pattern

Every Azure Function thinly wraps logic in `api/Shared/AdoHelpers.psm1` — that file is ~1850 lines and contains *all* meaningful backend logic (ADO REST calls, Table Storage CRUD, version bumping, PR creation, task creation, HMAC signing, email/Teams notifications, the orchestrator `Invoke-GAInitialProcess`, rebase scanning, branch management, closure tasks, live-status checks). Each function does little more than parse input, call into the module, and shape the response. **When adding behavior, add the helper here** rather than duplicating across function folders.

Every function starts with:
```powershell
Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force
```

### Function endpoints

Submission/approval flow: `SubmitRequest`, `GetRequests`, `ApproveRequest`, `PreviewGA`, `InitiateGA`.
Lookup: `GetRepos`, `GetBranches`, `GetEpics`, `GetTeams`, `SearchUsers`.
Cutoff override: `DecideOverride` (HMAC-token deep link from Teams card), `GetOverrideStatus`.
GA operations console: `ScanRebase`, `RebaseRepos`, `ManageBranch`, `GetClosureTasks`, `CloseWorkItems`, `CheckLiveStatus`, `CreateLiveTag`.

All function bindings use `authLevel: anonymous` — **auth is enforced upstream by SWA's `staticwebapp.config.json`**, which redirects 401 to `/.auth/login/aad`. Don't try to add per-function auth.

### Frontend structure

`frontend/index.html` + `app.js` + `auth.js` + `styles.css` is the entire app. `app.js` (~2400 lines) holds all logic: views (`Submit`, `Dashboard`, `GA-Initial` with subtabs), state (`allRequests`, `epicBlocks`, `cachedRepos`, `cachedEpics`, `branchCache`), and direct `fetch('/api/...')` calls. There are no modules — functions are global. New views attach via `showView(name)`.

Two access-control lists live in JS:
- `GA_ADMINS` (in `app.js`) — gates the Dashboard tab.
- `RELEASE_SCHEDULE` (in `app.js`) — hardcoded yearly cutoff/release-date pattern; `getNextRelease()` rolls forward through it. **When the calendar changes, this array must be edited.**

### State / data flow

1. `SubmitRequest` writes to Table `GAReleaseRequests` (PartitionKey = `targetMonth`, RowKey = `GA-yyyyMMdd-NNN`). Epic list is stringified JSON in a single `epics` column; `Get-RequestsFromStorage` parses it back.
2. Cutoff overrides go to Table `GAOverrideRequests`. The submission posts an Adaptive Card to a Teams webhook with two action URLs (`/api/DecideOverride?id=...&decision=approve|reject&token=...`); `token` is HMAC-SHA256 of `id|decision` keyed on `OVERRIDE_SIGNING_SECRET`. `Test-OverrideHmacToken` does constant-time comparison. **Never log or expose this secret.**
3. `Invoke-GAInitialProcess` is the orchestrator per (repo, branch). It: reads `app.json` from `main` (falls back to source branch), computes the new version via `New-VersionBump` (or accepts an override), updates main+test+integrated-test app.json files and `appsourcecop.json` (latest stable-tag version), pushes a multi-file commit via `Push-MultiFileChanges`, opens a PR with `New-AdoPullRequest` (resolves reviewer identities through `vssps.dev.azure.com`, **excludes the initiator**), and creates a child Task under the Epic with custom fields `Custom.AppName`, `Custom.TeamName`, `Custom.Version`, `Custom.ReleaseType`.

### Versioning convention

Format: `YYMM.minor.build.revision` (BC monthly cadence).
- `feature` → bump YYMM to next target month, reset minor/build/rev.
- `stability` / `minor` / `hotfix` → minor++, reset build/rev.

`New-VersionBump` accepts `TargetMonth` like `JUN-2026` to derive the YYMM directly; without it, YYMM increments by one month.

`Get-StableTagVersion` reads tags matching `(Stable|stable)[-_]?\d+\.\d+\.\d+\.\d+` and returns the highest version — used to set `appsourcecop.json` version.

## Important gotchas

- **Auth is bypassed in `frontend/auth.js`** via `const AUTH_DISABLED = true` (and a hardcoded `DEV_USER`). This was added while waiting on `User.Read.All` admin consent. Re-enable before shipping anywhere users other than the dev should reach.
- **`api/local.settings.json` is gitignored but currently committed-tracking-locally with a real PAT.** Treat it as a secret. The `.gitignore` covers it; do not add it to a commit.
- **`GA_REVIEWERS` env var name mismatch**: ARM template emits `GA_REVIEWERS`, but `local.settings.json` and `New-AdoPullRequest` read `GA_REVIEWER_MAP` / `GA_DEFAULT_REVIEWER` / `GA_SECONDARY_REVIEWER`. The ARM template is out of sync with the runtime — fix the ARM template (or rename in code) before redeploying infra.
- **GitHub Actions deploys frontend-only to GitHub Pages** — that path has no API. The real product runs on Azure Static Web Apps; don't assume Pages is the prod URL.
- **`epics` is a JSON-stringified column** in Table Storage. When reading, `Get-RequestsFromStorage` parses it; when writing in `SubmitRequest`, it's `ConvertTo-Json -Depth 5 -Compress`. If you add nested fields, mind the depth.
- **PR reviewer resolution** uses `https://vssps.dev.azure.com/<orgName>/_apis/identities` (different host than other ADO calls). The org name is parsed from `ADO_ORG_URL` supporting both `dev.azure.com/<org>` and `<org>.visualstudio.com` formats.
- **PowerShell Functions cold start**: `profile.ps1` only `Connect-AzAccount -Identity` when `MSI_SECRET` is set. Locally, `Az.Storage` cmdlets work against Azurite via `New-AzStorageContext -Local` (handled in `Get-StorageContext`).

## Key environment variables (Function App settings)

`ADO_ORG_URL`, `ADO_PROJECT`, `ADO_PAT`, `STORAGE_CONNECTION_STRING`, `GA_REVIEWER_MAP`, `GA_DEFAULT_REVIEWER`, `GA_SECONDARY_REVIEWER`, `ADO_GA_STATUS_FIELD` (default `Custom.FactoryStatus`), `ADO_GA_STATUS_VALUE` (default `70 GA Validation`), `POWER_AUTOMATE_WEBHOOK_URL` (email), `TEAMS_CUTOFF_WEBHOOK_URL` (override card), `OVERRIDE_SIGNING_SECRET`, `PORTAL_BASE_URL`, `AAD_CLIENT_ID`, `AAD_CLIENT_SECRET`.
