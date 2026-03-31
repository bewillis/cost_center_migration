<#
.SYNOPSIS
    Ensures Azure Subscriptions exist based on mapping.csv

.DESCRIPTION
    This script imports a CSV file (configured in .env) containing subscription_name and 
    invoice_section_name values, and ensures corresponding Azure Subscriptions exist under 
    their mapped Invoice Sections. Creates any missing Subscriptions based on dry-run mode setting.
    
    All configuration is read from the .env file in the script directory.
    
    IMPORTANT: This script requires both Azure CLI and Azure PowerShell to be installed and authenticated:
    - Azure CLI: Used for billing API authentication (more reliable than PowerShell tokens)
    - Azure PowerShell: Used for subscription creation operations
    
    Run these commands before executing the script:
    - az login
    - Connect-AzAccount

.EXAMPLE
    .\Create-AzureSubscriptions.ps1
    
    Reads all configuration from .env file and creates missing Subscriptions (or logs what would be created if DRY_RUN=true)

.NOTES
    Requires Azure CLI and Azure PowerShell modules to be installed and authenticated.
    Uses Azure Billing API 2019-10-01-preview with REST calls for invoice section verification.
#>

# Configuration - Path to .env file
$EnvFilePath = Join-Path $PSScriptRoot ".env"

# Set error action preference
$ErrorActionPreference = "Stop"

# Configure logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFileName = "Create-AzureSubscriptions_$timestamp.log"
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

# Function to get retry delay (seconds) from throttling message
function Get-RetryDelaySecondsFromError {
    param(
        [string]$ErrorMessage,
        [int]$AttemptNumber,
        [int]$MaxBackoffSeconds = 900
    )

    # Try to parse service-provided wait duration (example: "Retry in 00:09:06.7040634 minutes")
    if ($ErrorMessage -match 'Retry\s+in\s+([0-9]{1,2}:[0-9]{2}:[0-9]{2}(?:\.[0-9]+)?)') {
        try {
            $retrySpan = [TimeSpan]::Parse($matches[1])
            $seconds = [Math]::Ceiling($retrySpan.TotalSeconds)
            return [Math]::Min([int]$seconds, $MaxBackoffSeconds)
        }
        catch {
            # Fall through to exponential backoff.
        }
    }

    # Fallback: bounded exponential backoff with jitter.
    $baseDelay = [Math]::Pow(2, [Math]::Min($AttemptNumber, 6))
    $jitter = Get-Random -Minimum 0 -Maximum 5
    $candidate = [int]([Math]::Ceiling($baseDelay + $jitter))
    return [Math]::Min($candidate, $MaxBackoffSeconds)
}

# Function to create a subscription with throttling-aware retries
function New-SubscriptionAliasWithRetry {
    param(
        [string]$AliasName,
        [string]$SubscriptionName,
        [string]$BillingScope,
        [string]$Workload = 'Production',
        [int]$MaxRetries = 4
    )

    for ($attempt = 0; $attempt -le $MaxRetries; $attempt++) {
        try {
            return New-AzSubscriptionAlias `
                -AliasName $AliasName `
                -SubscriptionName $SubscriptionName `
                -BillingScope $BillingScope `
                -Workload $Workload `
                -ErrorAction Stop
        }
        catch {
            $errorMessage = $_.Exception.Message
            $isThrottle = $false

            if ($errorMessage -match 'too many requests|throttl|429') {
                $isThrottle = $true
            }

            if (-not $isThrottle -or $attempt -ge $MaxRetries) {
                throw
            }

            $waitSeconds = Get-RetryDelaySecondsFromError -ErrorMessage $errorMessage -AttemptNumber ($attempt + 1)
            $attemptDisplay = $attempt + 1
            Write-ColorOutput "  ⚠ Throttled while creating '$SubscriptionName'. Retrying attempt $attemptDisplay/$MaxRetries after $waitSeconds second(s)..." -Color Yellow -Level "WARN"
            Start-Sleep -Seconds $waitSeconds
        }
    }
}

# Function to check if Az.Subscription and Az.Billing modules are installed
function Test-AzModules {
    $requiredModules = @('Az.Subscription', 'Az.Billing', 'Az.Accounts')
    
    foreach ($moduleName in $requiredModules) {
        $module = Get-Module -ListAvailable -Name $moduleName
        if (-not $module) {
            Write-ColorOutput "$moduleName module is not installed. Installing..." -Color Yellow -Level "WARN"
            Install-Module -Name $moduleName -Scope CurrentUser -Force -AllowClobber
            Write-ColorOutput "$moduleName module installed successfully." -Color Green -Level "INFO"
        }
        
        # Check if module is already imported
        $loadedModule = Get-Module -Name $moduleName
        if (-not $loadedModule) {
            Write-ColorOutput "Importing $moduleName module..." -Color Gray -Level "DEBUG"
            Import-Module $moduleName -ErrorAction Stop
        }
        else {
            Write-ColorOutput "$moduleName module already loaded (v$($loadedModule.Version))" -Color Gray -Level "DEBUG"
        }
    }
}

# Function to ensure user is logged in to Azure CLI and PowerShell
function Test-AzureConnection {
    param(
        [string]$TenantId
    )
    
    try {
        # Check Azure CLI login first
        Write-ColorOutput "Checking Azure CLI authentication..." -Color Gray -Level "DEBUG"
        $cliAccount = az account show --query "user.name" -o tsv 2>$null
        if ($LASTEXITCODE -ne 0) {
            Write-ColorOutput "Not logged in to Azure CLI. Please run 'az login' first." -Color Red -Level "ERROR"
            exit 1
        }
        Write-ColorOutput "Azure CLI authenticated as: $cliAccount" -Color Green -Level "INFO"
        
        # Check PowerShell context for subscription operations
        $context = Get-AzContext
        if (-not $context) {
            Write-ColorOutput "Not logged in to Azure PowerShell. Please run Connect-AzAccount first." -Color Red -Level "ERROR"
            exit 1
        }
        
        # Verify we're connected to the correct tenant
        if ($context.Tenant.Id -ne $TenantId) {
            Write-ColorOutput "Connected to tenant $($context.Tenant.Id) but configuration requires $TenantId" -Color Yellow -Level "WARN"
            Write-ColorOutput "Switching to tenant $TenantId..." -Color Yellow -Level "INFO"
            Connect-AzAccount -Tenant $TenantId -ErrorAction Stop | Out-Null
            $context = Get-AzContext
        }
        
        Write-ColorOutput "PowerShell connected to Azure as: $($context.Account.Id)" -Color Green -Level "INFO"
        Write-ColorOutput "Tenant: $($context.Tenant.Id)" -Color Cyan -Level "INFO"
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

# Function to verify Invoice Section exists
function Test-InvoiceSection {
    param(
        [string]$BillingAccountId,
        [string]$BillingProfileId,
        [string]$InvoiceSectionName
    )
    
    try {
            $cacheKey = "$BillingAccountId|$BillingProfileId"
            if (-not $script:InvoiceSectionsCache) {
                $script:InvoiceSectionsCache = @{}
            }

            if ($script:InvoiceSectionsCache.ContainsKey($cacheKey)) {
                $allInvoiceSections = $script:InvoiceSectionsCache[$cacheKey]
                Write-ColorOutput "  Using cached invoice sections ($($allInvoiceSections.Count) cached)" -Color Gray -Level "DEBUG"
            }
            else {
        # Use Azure CLI REST command (more reliable than PowerShell Invoke-RestMethod for billing API)
                $allInvoiceSections = @()
                $uri = "https://management.azure.com/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId/invoiceSections?api-version=2019-10-01-preview"
            
                do {
                    Write-ColorOutput "  Fetching page: $uri" -Color Gray -Level "DEBUG"
                    $invoiceSectionsJson = az rest --method get --url $uri 2>&1
                
                    if ($LASTEXITCODE -ne 0) {
                        throw "Azure CLI command failed: $invoiceSectionsJson"
                    }
                
                    $response = $invoiceSectionsJson | ConvertFrom-Json
                
                    if ($response.value) {
                        $allInvoiceSections += $response.value
                        Write-ColorOutput "  Retrieved $($response.value.Count) invoice sections from this page" -Color Gray -Level "DEBUG"
                    }
                
                    $uri = $response.nextLink
                } while ($uri)

                $script:InvoiceSectionsCache[$cacheKey] = $allInvoiceSections
                Write-ColorOutput "  Retrieved $($allInvoiceSections.Count) invoice sections from billing API" -Color Gray -Level "DEBUG"
            }
        
        # Find the specific invoice section by display name
        $section = $allInvoiceSections | Where-Object { $_.properties.displayName -eq $InvoiceSectionName }
        
        if ($section) {
            Write-ColorOutput "  ✓ Invoice Section '$InvoiceSectionName' exists (ID: $($section.name))" -Color Green -Level "INFO"
            return $section
        }
        else {
            Write-ColorOutput "  ✗ Invoice Section '$InvoiceSectionName' not found" -Color Red -Level "ERROR"
            Write-ColorOutput "  Available Invoice Sections:" -Color Yellow -Level "DEBUG"
            $allInvoiceSections | ForEach-Object {
                Write-ColorOutput "    - $($_.properties.displayName)" -Color Gray -Level "DEBUG"
            }
            return $null
        }
    }
    catch {
        Write-ColorOutput "  ✗ Error checking Invoice Section: $_" -Color Red -Level "ERROR"
        return $null
    }
}

# Function to check if subscription exists
function Test-SubscriptionExists {
    param(
        [string]$SubscriptionName
    )
    
    try {
        $subscriptions = Get-AzSubscription -ErrorAction SilentlyContinue
        $subscription = $subscriptions | Where-Object { $_.Name -eq $SubscriptionName }
        
        return ($null -ne $subscription)
    }
    catch {
        Write-ColorOutput "  Warning: Error checking subscription existence: $_" -Color Yellow -Level "WARN"
        return $false
    }
}

# Main script execution
try {
    # Initialize log file
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Azure Subscription Provisioning Script Started" -Level "INFO"
    Write-Log -Message "Log File: $logFilePath" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    Write-ColorOutput "`n=== Azure Subscription Provisioning Script ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file: $logFileName`n" -Color Gray -Level "INFO"

    # Load configuration from .env file
    Write-ColorOutput "Loading configuration from .env file..." -Color Yellow -Level "INFO"
    $envConfig = Get-EnvConfig -EnvFilePath $EnvFilePath
    
    if ($envConfig.Count -eq 0) {
        throw ".env file is empty or could not be loaded. Please ensure .env file exists and contains required configuration."
    }
    
    # Get and validate required configuration
    $requiredKeys = @('TENANT_ID', 'BILLING_ACCOUNT_ID', 'BILLING_PROFILE_ID', 'DRY_RUN', 'CSV_FILE_PATH')
    foreach ($key in $requiredKeys) {
        if (-not $envConfig.ContainsKey($key)) {
            throw "$key not found in .env file"
        }
    }
    
    $TenantId = $envConfig['TENANT_ID']
    $BillingAccountId = $envConfig['BILLING_ACCOUNT_ID']
    $BillingProfileId = $envConfig['BILLING_PROFILE_ID']
    $DryRun = $envConfig['DRY_RUN'] -eq 'true'
    $CsvPath = $envConfig['CSV_FILE_PATH']
    $CreateMaxRetries = if ($envConfig.ContainsKey('CREATE_SUBSCRIPTION_MAX_RETRIES')) { [int]$envConfig['CREATE_SUBSCRIPTION_MAX_RETRIES'] } else { 4 }
    $CreateDelaySeconds = if ($envConfig.ContainsKey('CREATE_SUBSCRIPTION_DELAY_SECONDS')) { [int]$envConfig['CREATE_SUBSCRIPTION_DELAY_SECONDS'] } else { 5 }
    
    Write-ColorOutput "Tenant ID: $TenantId" -Color Cyan -Level "INFO"
    Write-ColorOutput "Billing Account: $BillingAccountId" -Color Cyan -Level "INFO"
    Write-ColorOutput "Billing Profile: $BillingProfileId" -Color Cyan -Level "INFO"
    Write-ColorOutput "Dry Run Mode: $DryRun" -Color $(if ($DryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    Write-ColorOutput "Create Max Retries: $CreateMaxRetries" -Color Cyan -Level "INFO"
    Write-ColorOutput "Create Delay Seconds: $CreateDelaySeconds" -Color Cyan -Level "INFO"
    
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

    # Import CSV and validate required columns
    Write-ColorOutput "`nImporting CSV file..." -Color Yellow -Level "INFO"
    $mappingData = Import-Csv -Path $CsvPath
    
    if (-not $mappingData) {
        throw "CSV file is empty or could not be imported"
    }
    
    # Validate required columns
    $requiredColumns = @('subscription_name', 'invoice_section_name')
    $csvColumns = $mappingData[0].PSObject.Properties.Name
    foreach ($column in $requiredColumns) {
        if ($column -notin $csvColumns) {
            throw "Required column '$column' not found in CSV file"
        }
    }
    
    Write-ColorOutput "Total rows in CSV: $($mappingData.Count)" -Color Cyan -Level "INFO"
    
    # Extract unique subscription names with their invoice sections
    $subscriptionMappings = @{}
    foreach ($row in $mappingData) {
        $subName = $row.subscription_name
        $invoiceSection = $row.invoice_section_name
        
        if (-not [string]::IsNullOrWhiteSpace($subName)) {
            if (-not $subscriptionMappings.ContainsKey($subName)) {
                $subscriptionMappings[$subName] = $invoiceSection
            }
        }
    }
    
    Write-ColorOutput "Unique Subscriptions found: $($subscriptionMappings.Count)" -Color Cyan -Level "INFO"
    Write-ColorOutput "`nSubscriptions to ensure:" -Color Yellow -Level "INFO"
    $subscriptionMappings.GetEnumerator() | Sort-Object Key | ForEach-Object { 
        Write-ColorOutput "  - $($_.Key) → Invoice Section: $($_.Value)" -Color White -Level "INFO"
    }

    # Check Azure modules and connection
    Write-ColorOutput "`nChecking Azure PowerShell modules..." -Color Yellow -Level "INFO"
    Test-AzModules
    
    Write-ColorOutput "`nChecking Azure CLI and PowerShell connection..." -Color Yellow -Level "INFO"
    Test-AzureConnection -TenantId $TenantId

    # Get existing subscriptions
    Write-ColorOutput "`nRetrieving existing Subscriptions from Azure..." -Color Yellow -Level "INFO"
    
    try {
        $existingSubscriptions = Get-AzSubscription -ErrorAction Stop
        
        if ($existingSubscriptions) {
            Write-ColorOutput "Found $($existingSubscriptions.Count) existing Subscription(s)" -Color Green -Level "INFO"
            $existingSubNames = $existingSubscriptions | Select-Object -ExpandProperty Name
        }
        else {
            Write-ColorOutput "No existing Subscriptions found" -Color Yellow -Level "WARN"
            $existingSubNames = @()
        }
    }
    catch {
        Write-ColorOutput "✗ Failed to retrieve existing Subscriptions" -Color Red -Level "ERROR"
        Write-ColorOutput "Error: $_" -Color Red -Level "ERROR"
        Write-ColorOutput "`nCannot proceed safely without knowing existing Subscriptions." -Color Red -Level "ERROR"
        Write-ColorOutput "This prevents accidental duplicate creation." -Color Red -Level "ERROR"
        throw "Failed to retrieve existing Subscriptions: $_"
    }

    # Process each unique subscription
    Write-ColorOutput "`n=== Processing Subscriptions ===" -Color Cyan -Level "INFO"
    $created = 0
    $skipped = 0
    $dryRunActions = 0
    $errors = 0

    foreach ($subEntry in ($subscriptionMappings.GetEnumerator() | Sort-Object Key)) {
        $subscriptionName = $subEntry.Key
        $invoiceSectionName = $subEntry.Value
        
        Write-ColorOutput "`nProcessing: $subscriptionName" -Color Yellow -Level "INFO"
        Write-ColorOutput "  Target Invoice Section: $invoiceSectionName" -Color Gray -Level "INFO"
        
        # Verify Invoice Section exists
        $invoiceSection = Test-InvoiceSection -BillingAccountId $BillingAccountId `
            -BillingProfileId $BillingProfileId `
            -InvoiceSectionName $invoiceSectionName
        
        if (-not $invoiceSection) {
            Write-ColorOutput "  ✗ Skipping - Invoice Section does not exist" -Color Red -Level "ERROR"
            $errors++
            continue
        }
        
        # Check if subscription already exists
        if ($existingSubNames -contains $subscriptionName) {
            Write-ColorOutput "  ✓ Already exists - Skipping" -Color Green -Level "INFO"
            $skipped++
            continue
        }

        # Create subscription or log dry-run action
        if ($DryRun) {
            Write-ColorOutput "  [DRY-RUN] Would create Subscription: $subscriptionName" -Color Magenta -Level "INFO"
            Write-ColorOutput "  [DRY-RUN] Under Invoice Section: $invoiceSectionName" -Color Magenta -Level "INFO"
            $dryRunActions++
        }
        else {
            try {
                Write-ColorOutput "  Creating Subscription..." -Color Yellow -Level "INFO"
                
                # Note: The actual cmdlet for creating subscriptions may vary based on your Azure setup
                # Common options include:
                # - New-AzSubscription (for EA/MCA)
                # - New-AzSubscriptionAlias (for alias-based creation)
                # This example uses New-AzSubscriptionAlias which is common for MCA
                
                $aliasName = $subscriptionName -replace '[^a-zA-Z0-9-]', '-'

                if (($created -gt 0) -and ($CreateDelaySeconds -gt 0)) {
                    Write-ColorOutput "  Waiting $CreateDelaySeconds second(s) before next create to reduce throttling risk..." -Color Gray -Level "DEBUG"
                    Start-Sleep -Seconds $CreateDelaySeconds
                }

                $newSubscription = New-SubscriptionAliasWithRetry `
                    -AliasName $aliasName `
                    -SubscriptionName $subscriptionName `
                    -BillingScope "/providers/Microsoft.Billing/billingAccounts/$BillingAccountId/billingProfiles/$BillingProfileId/invoiceSections/$($invoiceSection.name)" `
                    -Workload 'Production' `
                    -MaxRetries $CreateMaxRetries
                
                Write-ColorOutput "  ✓ Created successfully" -Color Green -Level "INFO"
                Write-ColorOutput "  Subscription ID: $($newSubscription.Properties.SubscriptionId)" -Color Gray -Level "INFO"
                $created++
            }
            catch {
                Write-ColorOutput "  ✗ Error creating Subscription: $_" -Color Red -Level "ERROR"
                Write-Log -Message "Detailed error for $subscriptionName : $($_.Exception.Message)" -Level "ERROR"
                $errors++
            }
        }
    }

    # Summary
    Write-ColorOutput "`n=== Summary ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' })" -Color $(if ($DryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    Write-ColorOutput "Total Subscriptions processed: $($subscriptionMappings.Count)" -Color White -Level "INFO"
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
    Write-Log -Message "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }) | Total: $($subscriptionMappings.Count) | Created: $created | Dry-run: $dryRunActions | Skipped: $skipped | Errors: $errors" -Level "INFO"
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
