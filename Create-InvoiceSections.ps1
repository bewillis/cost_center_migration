<#
.SYNOPSIS
    Ensures Azure Invoice Sections exist based on mapping.csv

.DESCRIPTION
    This script imports a CSV file (configured in .env), extracts unique invoice_section_name values,
    and ensures corresponding Azure Invoice Sections exist under a given Billing Profile.
    Creates any missing Invoice Sections.
    
    All configuration is read from the .env file in the script directory.

.EXAMPLE
    .\Create-InvoiceSections.ps1
    
    Reads all configuration from .env file and creates missing Invoice Sections
#>

# Configuration - Path to .env file
$EnvFilePath = Join-Path $PSScriptRoot ".env"

# Set error action preference
$ErrorActionPreference = "Stop"

# Configure logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFileName = "Create-InvoiceSections_$timestamp.log"
$logFilePath = Join-Path $PSScriptRoot $logFileName

# Function to write to log file
function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )
    
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    
    # Write to log file
    Add-Content -Path $logFilePath -Value $logMessage -ErrorAction SilentlyContinue
}

# Function to write colored output (to console and log file)
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Level = "INFO"
    )
    
    # Write to console with color
    Write-Host $Message -ForegroundColor $Color
    
    # Strip ANSI color codes and special characters for log file
    $cleanMessage = $Message -replace "`n", " " -replace "`r", ""
    
    # Write to log file
    Write-Log -Message $cleanMessage -Level $Level
}

# Function to check if Az.Billing module is installed
function Test-AzBillingModule {
    $module = Get-Module -ListAvailable -Name Az.Billing
    if (-not $module) {
        Write-ColorOutput "Az.Billing module is not installed. Installing..." -Color Yellow -Level "WARN"
        Install-Module -Name Az.Billing -Scope CurrentUser -Force -AllowClobber
        Write-ColorOutput "Az.Billing module installed successfully." -Color Green -Level "INFO"
    }
    
    # Check if module is already imported
    $loadedModule = Get-Module -Name Az.Billing
    if (-not $loadedModule) {
        Write-ColorOutput "Importing Az.Billing module..." -Color Gray -Level "DEBUG"
        Import-Module Az.Billing -ErrorAction Stop
    }
    else {
        Write-ColorOutput "Az.Billing module already loaded (v$($loadedModule.Version))" -Color Gray -Level "DEBUG"
    }
}

# Function to ensure user is logged in to Azure
function Test-AzureConnection {
    try {
        $context = Get-AzContext
        if (-not $context) {
            Write-ColorOutput "Not logged in to Azure. Please run Connect-AzAccount first." -Color Red -Level "ERROR"
            exit 1
        }
        Write-ColorOutput "Connected to Azure as: $($context.Account.Id)" -Color Green -Level "INFO"
        Write-ColorOutput "Subscription: $($context.Subscription.Name)" -Color Cyan -Level "INFO"
    }
    catch {
        Write-ColorOutput "Error checking Azure connection: $_" -Color Red -Level "ERROR"
        exit 1
    }
}

# Function to load environment variables from .env file
function Get-EnvConfig {
    param(
        [string]$EnvFilePath
    )
    
    if (-not (Test-Path $EnvFilePath)) {
        Write-ColorOutput "Warning: .env file not found at: $EnvFilePath" -Color Yellow -Level "WARN"
        return @{}
    }
    
    Write-ColorOutput "Loading configuration from .env file: $EnvFilePath" -Color Green -Level "INFO"
    
    $config = @{}
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()
        
        # Skip empty lines and comments
        if ($line -and -not $line.StartsWith('#')) {
            # Parse KEY=VALUE format
            if ($line -match '^([^=]+)=(.*)$') {
                $key = $matches[1].Trim()
                $value = $matches[2].Trim()
                
                # Remove surrounding quotes if present
                $value = $value -replace '^["'']|["'']$', ''
                
                $config[$key] = $value
                Write-ColorOutput "  Loaded: $key" -Color Gray -Level "DEBUG"
            }
        }
    }
    
    return $config
}

# Main script execution
try {
    # Initialize log file
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Invoice Section Provisioning Script Started" -Level "INFO"
    Write-Log -Message "Log File: $logFilePath" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    Write-ColorOutput "`n=== Azure Invoice Section Provisioning Script ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file: $logFileName`n" -Color Gray -Level "INFO"

    # Load configuration from .env file
    Write-ColorOutput "Loading configuration from .env file..." -Color Yellow -Level "INFO"
    $envConfig = Get-EnvConfig -EnvFilePath $EnvFilePath
    
    if ($envConfig.Count -eq 0) {
        throw ".env file is empty or could not be loaded. Please ensure .env file exists and contains required configuration."
    }
    
    # Get and validate required configuration
    $requiredKeys = @('BILLING_ACCOUNT_ID', 'BILLING_PROFILE_ID', 'DRY_RUN', 'CSV_FILE_PATH')
    foreach ($key in $requiredKeys) {
        if (-not $envConfig.ContainsKey($key)) {
            throw "$key not found in .env file"
        }
    }
    
    $BillingAccountId = $envConfig['BILLING_ACCOUNT_ID']
    $BillingProfileId = $envConfig['BILLING_PROFILE_ID']
    $DryRun = $envConfig['DRY_RUN'] -eq 'true'
    $CsvPath = $envConfig['CSV_FILE_PATH']
    
    Write-ColorOutput "Billing Account ID: $BillingAccountId" -Color Cyan -Level "INFO"
    Write-ColorOutput "Billing Profile ID: $BillingProfileId" -Color Cyan -Level "INFO"
    Write-ColorOutput "Dry Run Mode: $DryRun" -Color $(if ($DryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    
    # Resolve relative path if needed
    if (-not [System.IO.Path]::IsPathRooted($CsvPath)) {
        $CsvPath = Join-Path $PSScriptRoot $CsvPath
    }
    
    Write-ColorOutput "" -Level "INFO"

    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        throw "CSV file not found at path: $CsvPath"
    }
    Write-ColorOutput "CSV file found: $CsvPath" -Color Green -Level "INFO"

    # Import CSV and extract unique invoice section names
    Write-ColorOutput "`nImporting CSV file..." -Color Yellow -Level "INFO"
    $mappingData = Import-Csv -Path $CsvPath
    
    if (-not $mappingData) {
        throw "CSV file is empty or could not be imported"
    }
    
    Write-ColorOutput "Total rows in CSV: $($mappingData.Count)" -Color Cyan -Level "INFO"
    
    # Extract unique invoice section names
    $uniqueInvoiceSections = $mappingData | 
    Select-Object -ExpandProperty invoice_section_name -Unique | 
    Sort-Object
    
    Write-ColorOutput "Unique Invoice Sections found: $($uniqueInvoiceSections.Count)" -Color Cyan -Level "INFO"
    Write-ColorOutput "`nInvoice Sections to ensure:" -Color Yellow -Level "INFO"
    $uniqueInvoiceSections | ForEach-Object { 
        Write-ColorOutput "  - $_" -Color White -Level "INFO"
    }

    # Check Azure modules and connection
    Write-ColorOutput "`nChecking Azure PowerShell modules..." -Color Yellow -Level "INFO"
    Test-AzBillingModule
    
    Write-ColorOutput "`nChecking Azure connection..." -Color Yellow -Level "INFO"
    Test-AzureConnection

    # Get existing invoice sections
    Write-ColorOutput "`nRetrieving existing Invoice Sections from Azure..." -Color Yellow -Level "INFO"
    
    try {
        # Use Azure CLI to retrieve invoice sections (PowerShell cmdlet has authentication issues)
        # Handle pagination to get all invoice sections
        $allInvoiceSections = @()
        $nextUrl = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId/invoiceSections?api-version=2019-10-01-preview"
        
        do {
            Write-ColorOutput "  Fetching page: $nextUrl" -Color Gray -Level "DEBUG"
            $invoiceSectionsJson = az rest --method get --url $nextUrl 2>&1
            
            if ($LASTEXITCODE -ne 0) {
                throw "Azure CLI command failed: $invoiceSectionsJson"
            }
            
            $invoiceSectionsResponse = $invoiceSectionsJson | ConvertFrom-Json
            
            if ($invoiceSectionsResponse.value) {
                $allInvoiceSections += $invoiceSectionsResponse.value
                Write-ColorOutput "  Retrieved $($invoiceSectionsResponse.value.Count) invoice sections from this page" -Color Gray -Level "DEBUG"
            }
            
            # Check for next page
            $nextUrl = $invoiceSectionsResponse.nextLink
            
        } while ($nextUrl)
        
        Write-ColorOutput "Total invoice sections retrieved: $($allInvoiceSections.Count)" -Color Cyan -Level "INFO"
        
        if ($allInvoiceSections -and $allInvoiceSections.Count -gt 0) {
            Write-ColorOutput "Found $($allInvoiceSections.Count) existing Invoice Section(s) for this Billing Profile" -Color Green -Level "INFO"
            $existingSectionNames = $allInvoiceSections | ForEach-Object { $_.properties.displayName }
            
            # Debug: Show first few invoice section names
            Write-ColorOutput "Sample existing invoice sections:" -Color Gray -Level "DEBUG"
            $existingSectionNames | Select-Object -First 5 | ForEach-Object {
                Write-ColorOutput "  - $_" -Color Gray -Level "DEBUG"
            }
        }
        else {
            Write-ColorOutput "No existing Invoice Sections found for this Billing Profile" -Color Yellow -Level "WARN"
            $existingSectionNames = @()
        }
    }
    catch {
        Write-ColorOutput "✗ Failed to retrieve existing Invoice Sections" -Color Red -Level "ERROR"
        Write-ColorOutput "Error: $_" -Color Red -Level "ERROR"
        
        # Check if it's an authentication issue
        if ($_.Exception.Message -match "credentials|authentication|unauthorized") {
            Write-ColorOutput "`nThis appears to be an authentication issue with Azure CLI." -Color Yellow -Level "WARN"
            Write-ColorOutput "Possible solutions:" -Color Yellow -Level "WARN"
            Write-ColorOutput "  1. Ensure you have the necessary permissions (Billing Account Reader or higher)" -Color Yellow -Level "WARN"
            Write-ColorOutput "  2. Try running: az login" -Color Yellow -Level "WARN"
            Write-ColorOutput "  3. Verify your account has access to billing account: $BillingAccountId" -Color Yellow -Level "WARN"
        }
        
        Write-ColorOutput "`nCannot proceed safely without knowing existing Invoice Sections." -Color Red -Level "ERROR"
        Write-ColorOutput "This prevents accidental duplicate creation." -Color Red -Level "ERROR"
        throw "Failed to retrieve existing Invoice Sections: $_"
    }

    # Process each unique invoice section
    Write-ColorOutput "`n=== Processing Invoice Sections ===" -Color Cyan -Level "INFO"
    $created = 0
    $skipped = 0
    $dryRunActions = 0
    $errors = 0

    foreach ($sectionName in $uniqueInvoiceSections) {
        Write-ColorOutput "`nProcessing: $sectionName" -Color Yellow -Level "INFO"
        
        # Check if invoice section already exists
        if ($existingSectionNames -contains $sectionName) {
            Write-ColorOutput "  ✓ Already exists - Skipping" -Color Green -Level "INFO"
            $skipped++
            continue
        }

        # Create invoice section or log dry-run action
        if ($DryRun) {
            Write-ColorOutput "  [DRY-RUN] Would create Invoice Section: $sectionName" -Color Magenta -Level "INFO"
            $dryRunActions++
        }
        else {
            try {
                Write-ColorOutput "  Creating Invoice Section..." -Color Yellow -Level "INFO"
                
                # Invoice Sections must be created via Azure REST API as there's no PowerShell cmdlet
                # Following: https://learn.microsoft.com/en-us/rest/api/billing/invoice-sections/create
                
                # Use Azure CLI to get access token (PowerShell tokens don't work with Billing API preview)
                $tokenJson = az account get-access-token --resource https://management.azure.com/ | ConvertFrom-Json
                $token = $tokenJson.accessToken
                
                Write-ColorOutput "  Got access token for Azure Management API (via Azure CLI)" -Color Gray -Level "DEBUG"
                
                # Generate a unique invoice section name (required in URL path)
                # Azure requires a system name (lowercase, no spaces, alphanumeric and hyphens only)
                $invoiceSectionName = ($sectionName -replace '[^a-zA-Z0-9]', '-').ToLower()
                # Ensure it starts with a letter and remove any leading/trailing hyphens
                $invoiceSectionName = $invoiceSectionName -replace '^[^a-z]+', '' -replace '-+$', ''
                
                # Construct the REST API URL following the documentation format
                # PUT https://management.azure.com/providers/Microsoft.Billing/billingAccounts/{billingAccountName}/billingProfiles/{billingProfileName}/invoiceSections/{invoiceSectionName}?api-version=2019-10-01-preview
                $apiVersion = "2019-10-01-preview"
                $url = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId/invoiceSections/$invoiceSectionName`?api-version=$apiVersion"
                
                Write-ColorOutput "  Invoice Section Name (system): $invoiceSectionName" -Color Gray -Level "DEBUG"
                Write-ColorOutput "  API URL: $url" -Color Gray -Level "DEBUG"
                
                # Prepare the request body following the documentation
                # The body should have properties.displayName
                $body = @{
                    properties = @{
                        displayName = $sectionName
                    }
                } | ConvertTo-Json -Depth 10
                
                Write-ColorOutput "  Request body: $body" -Color Gray -Level "DEBUG"
                
                # Make the REST API call using PUT method (as per documentation)
                $headers = @{
                    "Authorization" = "Bearer $token"
                    "Content-Type"  = "application/json"
                }
                
                try {
                    # PUT creates or updates the resource
                    $response = Invoke-RestMethod -Uri $url -Method Put -Headers $headers -Body $body -ErrorAction Stop
                    Write-ColorOutput "  ✓ Created successfully" -Color Green -Level "INFO"
                    if ($response.name) {
                        Write-ColorOutput "  Invoice Section ID: $($response.name)" -Color Gray -Level "DEBUG"
                    }
                    $created++
                }
                catch {
                    # Try to parse error details
                    $errorMessage = $_.ErrorDetails.Message
                    if ([string]::IsNullOrEmpty($errorMessage)) {
                        $errorMessage = $_.Exception.Message
                    }
                    
                    # Check for common issues
                    if ($errorMessage -match "InvalidAuthenticationToken|Unauthorized") {
                        Write-ColorOutput "  ✗ Authentication/Authorization issue" -Color Red -Level "ERROR"
                        Write-ColorOutput "  Ensure you have 'Invoice Section Contributor' or 'Billing Profile Contributor' role" -Color Yellow -Level "WARN"
                    }
                    elseif ($errorMessage -match "ResourceNotFound|NotFound") {
                        Write-ColorOutput "  ✗ Billing Account or Profile not found - verify IDs are correct" -Color Red -Level "ERROR"
                        Write-ColorOutput "  Billing Account: $BillingAccountId" -Color Yellow -Level "WARN"
                        Write-ColorOutput "  Billing Profile: $BillingProfileId" -Color Yellow -Level "WARN"
                    }
                    elseif ($errorMessage -match "AlreadyExists|Conflict") {
                        Write-ColorOutput "  ✗ Invoice Section already exists with this system name" -Color Red -Level "ERROR"
                    }
                    elseif ($errorMessage -match "InvalidResourceName|BadRequest") {
                        Write-ColorOutput "  ✗ Invalid invoice section name format" -Color Red -Level "ERROR"
                        Write-ColorOutput "  System name used: $invoiceSectionName" -Color Yellow -Level "WARN"
                    }
                    
                    throw $errorMessage
                }
            }
            catch {
                $errorMessage = if ($_ -is [string]) { $_ } else { $_.Exception.Message }
                Write-ColorOutput "  ✗ Error creating Invoice Section: $errorMessage" -Color Red -Level "ERROR"
                $errors++
            }
        }
    }

    # Summary
    Write-ColorOutput "`n=== Summary ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' })" -Color $(if ($DryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    Write-ColorOutput "Total Invoice Sections processed: $($uniqueInvoiceSections.Count)" -Color White -Level "INFO"
    Write-ColorOutput "Already existing (skipped): $skipped" -Color Green -Level "INFO"
    
    if ($DryRun) {
        Write-ColorOutput "Would create (dry-run): $dryRunActions" -Color Magenta -Level "INFO"
    }
    else {
        Write-ColorOutput "Newly created: $created" -Color Green -Level "INFO"
    }
    
    Write-ColorOutput "Errors: $errors" -Color $(if ($errors -gt 0) { "Red" } else { "Green" }) -Level $(if ($errors -gt 0) { "ERROR" } else { "INFO" })
    Write-ColorOutput "`nCompleted at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file saved to: $logFilePath" -Color Gray -Level "INFO"
    
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Script completed successfully" -Level "INFO"
    Write-Log -Message "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }) | Total: $($uniqueInvoiceSections.Count) | Created: $created | Dry-run: $dryRunActions | Skipped: $skipped | Errors: $errors" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    if ($errors -gt 0) {
        exit 1
    }
}
catch {
    Write-ColorOutput "`n✗ Script failed with error:" -Color Red -Level "ERROR"
    Write-ColorOutput $_.Exception.Message -Color Red -Level "ERROR"
    Write-ColorOutput "`nStack Trace:" -Color Gray -Level "ERROR"
    Write-ColorOutput $_.ScriptStackTrace -Color Gray -Level "ERROR"
    Write-ColorOutput "`nLog file saved to: $logFilePath" -Color Gray -Level "INFO"
    
    Write-Log -Message "========================================" -Level "ERROR"
    Write-Log -Message "Script failed with error: $($_.Exception.Message)" -Level "ERROR"
    Write-Log -Message "Stack Trace: $($_.ScriptStackTrace)" -Level "ERROR"
    Write-Log -Message "========================================" -Level "ERROR"
    
    exit 1
}
