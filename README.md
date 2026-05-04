# GA Release Portal

**Self-service web portal for Aptean GA release handovers** — replaces the manual email process where Dev teams send release details to the GA team.

## What This Does

| Before (Email) | After (Portal) |
|---|---|
| Dev team sends email with release details | Dev team fills out a web form |
| GA manually reads email, copies details | Portal validates and stores the request |
| GA manually creates ADO tasks | Auto-creates tasks under monthly release work item |
| GA manually updates versions | Auto-bumps version based on release type |
| GA manually creates PR | Auto-creates PR with reviewers assigned |

## Architecture

```
┌─────────────────────────────┐
│   AppCentral (iframe)       │
│  ┌───────────────────────┐  │
│  │  Static Web App       │  │
│  │  (HTML/CSS/JS)        │  │
│  │  ┌─────────────────┐  │  │
│  │  │ Submit Form     │  │  │
│  │  │ Dashboard       │  │  │
│  │  └────────┬────────┘  │  │
│  └───────────┼───────────┘  │
└──────────────┼──────────────┘
               │ /api/*
   ┌───────────▼───────────┐
   │  Azure Functions      │
   │  (PowerShell)         │
   │  ├─ SubmitRequest     │
   │  ├─ GetRequests       │
   │  └─ ApproveRequest    │
   └───────┬───────┬───────┘
           │       │
    ┌──────▼──┐ ┌──▼──────────┐
    │ Azure   │ │ Azure DevOps│
    │ Table   │ │ REST API    │
    │ Storage │ │ (ADO)       │
    └─────────┘ └─────────────┘
```

## Project Structure

```
ga-release-portal/
├── frontend/               # Static Web App frontend
│   ├── index.html          # Main page (form + dashboard)
│   ├── styles.css          # Fluent Design-inspired styles
│   ├── app.js              # Application logic
│   └── auth.js             # Azure AD SSO (MSAL.js)
├── api/                    # Azure Functions (PowerShell)
│   ├── host.json
│   ├── local.settings.json # Local dev config (gitignored)
│   ├── requirements.psd1   # PowerShell dependencies
│   ├── Shared/
│   │   └── AdoHelpers.psm1 # ADO API + Storage helpers
│   ├── SubmitRequest/      # POST /api/SubmitRequest
│   ├── GetRequests/        # GET  /api/GetRequests
│   └── ApproveRequest/     # POST /api/ApproveRequest
├── infra/
│   └── main.json           # ARM template for deployment
├── staticwebapp.config.json
└── .gitignore
```

## Setup Instructions

### Prerequisites

- Azure subscription
- Azure DevOps PAT token with **Code (Read/Write)**, **Work Items (Read/Write)**, **Build (Read)** scopes
- Azure AD App Registration (for SSO)
- [Azure Static Web Apps CLI](https://github.com/Azure/static-web-apps-cli) (`npm install -g @azure/static-web-apps-cli`)
- [Azure Functions Core Tools v4](https://learn.microsoft.com/en-us/azure/azure-functions/functions-run-local)

### Step 1: Azure AD App Registration

1. Go to **Azure Portal → Azure Active Directory → App registrations → New registration**
2. Name: `GA Release Portal`
3. Redirect URI: `https://<your-swa-hostname>/.auth/login/aad/callback`
4. After creation, note the **Client ID** and **Tenant ID**
5. Under **Certificates & secrets**, create a new client secret — note the value
6. Under **API permissions**, add `User.Read` (Microsoft Graph)

### Step 2: Configure Local Development

1. Copy `api/local.settings.json` and fill in:
   - `ADO_PAT`: Your Azure DevOps PAT
   - Other values as needed

2. Update `frontend/auth.js`:
   - Replace `<YOUR-CLIENT-ID>` with your Azure AD Client ID
   - Replace `<YOUR-TENANT-ID>` with your Azure AD Tenant ID

### Step 3: Run Locally

```bash
# Install SWA CLI if not already installed
npm install -g @azure/static-web-apps-cli

# Start the app (frontend + API)
swa start frontend --api-location api
```

The portal will be available at `http://localhost:4280`

### Step 4: Deploy to Azure

```bash
# Login to Azure
az login

# Create resource group
az group create --name rg-ga-release-portal --location eastus

# Deploy infrastructure
az deployment group create \
    --resource-group rg-ga-release-portal \
    --template-file infra/main.json \
    --parameters \
        adoPatSecretValue="<your-ado-pat>" \
        aadClientId="<your-client-id>" \
        aadClientSecret="<your-client-secret>"

# Deploy the app
swa deploy --deployment-token <token-from-portal>
```

### Step 5: Embed in AppCentral

Once deployed, embed the portal in AppCentral using an iframe:

```html
<iframe
    src="https://<your-swa-hostname>"
    width="100%"
    height="100%"
    style="border: none;"
    title="GA Release Portal">
</iframe>
```

## GA Workflow (What Happens On Approval)

1. **Dev team submits** request via the portal form
2. **GA team reviews** on the Dashboard → clicks **Approve**
3. **Automation triggers** (integrates with your existing GA agents):
   - Clone repo with the specified branch
   - Calculate new version:
     - **Feature/Major**: `2601.2.0.0` → `2602.0.0.0`
     - **Stability/Minor**: `2601.2.0.0` → `2601.3.0.0`
   - Update `app.json` (main app, test app, integrated test app)
   - Update `appsourcecop.json` version
   - Update permission sets (if new objects detected)
   - Create PR with reviewers: krishna.s, kapilkumar, subhavarman.rs
   - Create ADO task under monthly release work item
   - Link Dev team epics under the Related section

## API Reference

| Endpoint | Method | Description |
|---|---|---|
| `/api/SubmitRequest` | POST | Submit a new GA release request |
| `/api/GetRequests` | GET | List requests (optional: `?status=pending&team=Core`) |
| `/api/ApproveRequest` | POST | Approve or reject a request |

## Team / Reviewers

| Role | Email |
|---|---|
| GA Lead (PR Creator) | krishna.s@aptean.com |
| GA Reviewer | kapilkumar@aptean.com |
| GA Reviewer | subhavarman.rs@aptean.com |
