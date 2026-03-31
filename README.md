# Azure Cost Center Migration Scripts

This repository contains PowerShell scripts for automating the creation of Azure Invoice Sections, Azure Subscriptions, and GitHub Cost Centers based on 6. Generates summary report

### Ensure-GitHubCostCenters.ps1

1. Loads configuration from `.env`
2. Imports and validates `mapping.csv`
3. Extracts unique `cost_center_name` values
4. Retrieves existing GitHub Cost Centers via API
5. For each missing Cost Center:
   - **DRY_RUN=true**: Logs what would be created
   - **DRY_RUN=false**: Creates the Cost Center via GitHub API
6. Generates summary report
7. **Never logs or echoes the GitHub PAT token**

## Log Files

All scripts generate timestamped log files in the script directory:

- `Create-InvoiceSections_20251215_143210.log`
- `Create-AzureSubscriptions_20251215_143215.log`
- `Ensure-GitHubCostCenters_20251215_150412.log`g CSV file.

## Overview

The migration process consists of three scripts that work together:

1. **Create-InvoiceSections.ps1** - Creates Azure Invoice Sections
2. **Create-AzureSubscriptions.ps1** - Creates Azure Subscriptions under their respective Invoice Sections
3. **Ensure-GitHubCostCenters.ps1** - Creates GitHub Cost Centers

All scripts:
- Are fully idempotent (safe to run multiple times)
- Support dry-run mode for testing
- Load all configuration from a `.env` file
- Generate timestamped log files
- Use structured logging (INFO, WARN, ERROR, DEBUG)

## Prerequisites

- PowerShell 5.1 or later (PowerShell 7+ recommended)
- Azure PowerShell modules:
  - `Az.Accounts`
  - `Az.Billing`
  - `Az.Subscription`
- Active Azure session (`Connect-AzAccount`)
- Appropriate permissions to create Invoice Sections and Subscriptions

## Setup

### 1. Configure Environment Variables

Copy `.env.example` to `.env` and update with your actual values:

```bash
cp .env.example .env
```

Edit `.env`:

```bash
# For Invoice Sections and Subscriptions Scripts
TENANT_ID=12345678-1234-1234-1234-123456789abc
BILLING_ACCOUNT_ID=your-billing-account-id
BILLING_PROFILE_ID=your-billing-profile-id

# Execution Control
DRY_RUN=true

# CSV File Configuration
CSV_FILE_PATH=mapping.csv
```

### 2. Prepare Mapping CSV

Ensure your `mapping.csv` file contains the required columns:

```csv
github_org_name,invoice_section_name,subscription_name,cost_center_name
TEST-BenW,TEST BenW,TEST BenW - GitHub Copilot usage,TEST BenW
```

**Required columns:**
- `invoice_section_name` - Name of the Invoice Section to create
- `subscription_name` - Name of the Subscription to create
- `cost_center_name` - Name of the GitHub Cost Center to create

### 3. Create GitHub Personal Access Token (PAT)

For the GitHub Cost Centers script, you'll need a PAT with appropriate permissions:

1. Go to GitHub Settings → Developer settings → Personal access tokens → Tokens (classic)
2. Generate a new token with the following scopes:
   - `admin:org` - Full control of orgs and teams
   - `read:org` - Read org and team membership
3. Copy the token and add it to your `.env` file as `GITHUB_PAT`

### 4. Login to Azure

```powershell
Connect-AzAccount
```

If you have multiple tenants, specify the tenant:

```powershell
Connect-AzAccount -Tenant "your-tenant-id"
```

## Usage

### Step 1: Create Invoice Sections

First, create the Invoice Sections (or test with dry-run):

```powershell
# Dry-run mode (set DRY_RUN=true in .env)
.\Create-InvoiceSections.ps1

# Live mode (set DRY_RUN=false in .env)
.\Create-InvoiceSections.ps1
```

**Output:**
- Console: Color-coded progress and results
- Log file: `Create-InvoiceSections_YYYYMMDD_HHmmss.log`

### Step 2: Create Subscriptions

After Invoice Sections exist, create the Subscriptions:

```powershell
# Dry-run mode (set DRY_RUN=true in .env)
.\Create-AzureSubscriptions.ps1

# Live mode (set DRY_RUN=false in .env)
.\Create-AzureSubscriptions.ps1
```

**Output:**
- Console: Color-coded progress and results
- Log file: `Create-AzureSubscriptions_YYYYMMDD_HHmmss.log`

### Step 3: Create GitHub Cost Centers

Finally, create the GitHub Cost Centers:

```powershell
# Dry-run mode (set DRY_RUN=true in .env)
.\Ensure-GitHubCostCenters.ps1

# Live mode (set DRY_RUN=false in .env)
.\Ensure-GitHubCostCenters.ps1
```

**Output:**
- Console: Color-coded progress and results
- Log file: `Ensure-GitHubCostCenters_YYYYMMDD_HHmmss.log`

## Dry-Run Mode

Dry-run mode allows you to test the scripts without making any changes:

1. Set `DRY_RUN=true` in `.env`
2. Run the script
3. Review the log file to see what would be created
4. Set `DRY_RUN=false` when ready to execute

### Dry-Run Output Example

```
=== Processing Invoice Sections ===

Processing: TEST BenW
  [DRY-RUN] Would create Invoice Section: TEST BenW

=== Summary ===
Mode: DRY-RUN
Total Invoice Sections processed: 1
Already existing (skipped): 0
Would create (dry-run): 1
Errors: 0
```

## Script Behavior

### Create-InvoiceSections.ps1

1. Loads configuration from `.env`
2. Imports and validates `mapping.csv`
3. Extracts unique `invoice_section_name` values
4. Checks which Invoice Sections already exist
5. For each missing Invoice Section:
   - **DRY_RUN=true**: Logs what would be created
   - **DRY_RUN=false**: Creates the Invoice Section
6. Generates summary report

### Create-AzureSubscriptions.ps1

1. Loads configuration from `.env`
2. Imports and validates `mapping.csv`
3. Extracts unique `subscription_name` values with their `invoice_section_name`
4. Verifies each target Invoice Section exists
5. Checks which Subscriptions already exist
6. For each missing Subscription:
   - **DRY_RUN=true**: Logs what would be created
   - **DRY_RUN=false**: Creates the Subscription under correct Invoice Section
7. Generates summary report

## Log Files

Both scripts generate timestamped log files in the script directory:

- `Create-InvoiceSections_20251215_143210.log`
- `Create-AzureSubscriptions_20251215_143215.log`

**Log levels:**
- **DEBUG**: Configuration loading details
- **INFO**: Normal operations and progress
- **WARN**: Non-critical issues
- **ERROR**: Failures and errors

**Log format:**
```
[2025-12-15 14:32:10] [INFO] Azure Invoice Section Provisioning Script Started
[2025-12-15 14:32:11] [DEBUG] Loaded: BILLING_ACCOUNT_NAME
[2025-12-15 14:32:12] [INFO] Processing: TEST BenW
[2025-12-15 14:32:13] [INFO] ✓ Created successfully
```

## Error Handling

All scripts:
- Validate all required configuration keys
- Check for file existence before processing
- Verify prerequisites (modules, authentication, API access)
- Continue processing on individual errors (doesn't stop entire batch)
- Log detailed error information
- Protect sensitive data (GitHub PAT is never logged)
- Exit with code 1 if any errors occurred

## API Requirements

### GitHub API

The GitHub Cost Centers script requires:
- GitHub Enterprise Cloud organization
- Personal Access Token (PAT) with `admin:org` scope
- Access to the Cost Centers API endpoint

**Note:** The Cost Centers feature may not be available in all GitHub plans. Check your organization's GitHub plan and API access.

## Finding Your Configuration Values

### Billing Account ID

```powershell
# Get all billing accounts with their IDs
Get-AzBillingAccount | Select-Object Name, DisplayName, Type

# The 'Name' property is the Billing Account ID
```

### Billing Profile ID

```powershell
# Use the Billing Account ID (not display name) from above
$billingAccountId = "your-billing-account-id"
Get-AzBillingProfile -BillingAccountName $billingAccountId | Select-Object Name, DisplayName

# The 'Name' property is the Billing Profile ID
```

### Tenant ID

```powershell
Get-AzContext | Select-Object Tenant
```

### GitHub Organization

Your GitHub organization name (e.g., `my-company` from `https://github.com/my-company`)

### GitHub Personal Access Token

See setup instructions in section 3 above.

## Troubleshooting

### "Module not found"

The scripts will automatically install missing modules. If this fails:

```powershell
Install-Module -Name Az.Billing -Scope CurrentUser -Force
Install-Module -Name Az.Subscription -Scope CurrentUser -Force
Install-Module -Name Az.Accounts -Scope CurrentUser -Force
```

### "Not logged in to Azure"

```powershell
Connect-AzAccount
```

### "Invoice Section not found"

Ensure you run `Create-InvoiceSections.ps1` before `Create-AzureSubscriptions.ps1`.

### "Permission denied"

Verify you have the required RBAC permissions:
- Billing Account Contributor (or higher)
- Subscription Creator role

### "GitHub API Error 401/403"

Check your GitHub PAT:
- Ensure it hasn't expired
- Verify it has the `admin:org` scope
- Confirm you have admin access to the organization

### "GitHub API Error 404 - Cost centers endpoint not found"

The Cost Centers API may not be available in your GitHub plan. This feature is typically available in GitHub Enterprise Cloud. Contact GitHub support to verify availability.

## File Structure

```
.
├── .env                              # Configuration (gitignored)
├── .env.example                      # Configuration template
├── .gitignore                        # Git ignore rules
├── mapping.csv                       # Source data
├── Create-InvoiceSections.ps1        # Invoice Section creation script
├── Create-AzureSubscriptions.ps1     # Subscription creation script
├── Ensure-GitHubCostCenters.ps1      # GitHub Cost Center creation script
├── README.md                         # This file
└── *.log                            # Log files (gitignored)
```

## Security Notes

- The `.env` file is excluded from git (via `.gitignore`)
- **Never commit the `.env` file to version control** - it contains sensitive tokens
- GitHub PAT is never logged or displayed in console output
- Log files are also excluded from git
- Use `.env.example` as a template for new environments
- Rotate your GitHub PAT regularly
- Use the principle of least privilege for all tokens and credentials

## License

This project is provided as-is for use within your organization.
