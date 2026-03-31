<#
.SYNOPSIS
    Ensures GitHub Enterprise Cost Centers exist based on mapping.csv

.DESCRIPTION
    This script imports a CSV file (configured in .env), extracts unique cost_center_name values,
    and ensures corresponding GitHub Cost Centers exist at the Enterprise level.
    Creates any missing Cost Centers based on dry-run mode setting.

    All configuration is read from the .env file in the script directory.
    GitHub PAT token is never logged or echoed.

    After creating cost centers, organizations must be manually linked to Azure subscriptions.

.EXAMPLE
    .\Create-EnterpriseCostCenters.ps1

    Reads all configuration from .env file and creates missing enterprise cost centers

.EXAMPLE
    .\Create-EnterpriseCostCenters.ps1 -DryRun

    Forces dry-run mode without changing .env

.EXAMPLE
    .\Create-EnterpriseCostCenters.ps1 -LiveRun

    Forces live mode without changing .env
#>

param(
    [switch]$DryRun,
    [switch]$LiveRun
)

# Configuration - Path to .env file
$EnvFilePath = Join-Path $PSScriptRoot ".env"

# Set error action preference
$ErrorActionPreference = "Stop"

# Configure logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFileName = "Create-EnterpriseCostCenters_$timestamp.log"
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

    # Strip newline characters for log file readability
    $cleanMessage = $Message -replace "`n", " " -replace "`r", ""

    # Write to log file
    Write-Log -Message $cleanMessage -Level $Level
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

                # Don't log sensitive values
                if ($key -match '(^|_)(PAT|TOKEN|SECRET|PASSWORD)(_|$)') {
                    Write-ColorOutput "  Loaded: $key (value hidden)" -Color Gray -Level "DEBUG"
                }
                else {
                    Write-ColorOutput "  Loaded: $key" -Color Gray -Level "DEBUG"
                }
            }
        }
    }

    return $config
}

# Function to make GitHub API calls
function Invoke-GitHubApi {
    param(
        [string]$BaseUrl,
        [string]$Endpoint,
        [string]$Method = "GET",
        [string]$Token,
        [object]$Body = $null
    )

    $headers = @{
        "Authorization"        = "Bearer $Token"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $uri = "$BaseUrl$Endpoint"

    try {
        $params = @{
            Uri     = $uri
            Method  = $Method
            Headers = $headers
        }

        if ($Body) {
            $params['Body'] = ($Body | ConvertTo-Json -Depth 10)
            $params['ContentType'] = 'application/json'
        }

        return Invoke-RestMethod @params
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response -and $_.Exception.Response.StatusCode) {
            $statusCode = $_.Exception.Response.StatusCode.value__
        }

        $errorMessage = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errorJson.message) {
                    $errorMessage = $errorJson.message
                }
            }
            catch {
                $errorMessage = $_.ErrorDetails.Message
            }
        }

        if ($statusCode) {
            throw "GitHub API Error [$statusCode]: $errorMessage"
        }

        throw "GitHub API Error: $errorMessage"
    }
}

# Function to convert display name into a system-safe slug
function ConvertTo-CostCenterSlug {
    param(
        [string]$Name
    )

    $slug = ($Name -replace '[^a-zA-Z0-9]+', '-').ToLower()
    $slug = $slug.Trim('-')

    if ([string]::IsNullOrWhiteSpace($slug)) {
        throw "Unable to derive valid cost center slug from name: '$Name'"
    }

    return $slug
}

# Function to normalize cost center list payloads to an array
function ConvertTo-CostCenterArray {
    param(
        [object]$Response
    )

    if (-not $Response) {
        return @()
    }

    if ($Response -is [array]) {
        return $Response
    }

    if ($Response.PSObject.Properties.Name -contains 'cost_centers') {
        return @($Response.cost_centers)
    }

    if ($Response.PSObject.Properties.Name -contains 'costCenters') {
        return @($Response.costCenters)
    }

    if ($Response.PSObject.Properties.Name -contains 'value') {
        return @($Response.value)
    }

    return @($Response)
}

# Function to get existing enterprise cost centers from GitHub
function Get-EnterpriseCostCenters {
    param(
        [string]$BaseUrl,
        [string]$Endpoint,
        [string]$Token
    )

    Write-ColorOutput "  Fetching existing enterprise cost centers..." -Color Gray -Level "INFO"
    $response = Invoke-GitHubApi -BaseUrl $BaseUrl -Endpoint $Endpoint -Token $Token
    $costCenters = ConvertTo-CostCenterArray -Response $response

    Write-ColorOutput "  Found $($costCenters.Count) existing enterprise cost center(s)" -Color Gray -Level "INFO"
    return $costCenters
}

# Function to check if a cost center already exists
function Test-CostCenterExists {
    param(
        [array]$ExistingCostCenters,
        [string]$CostCenterName,
        [string]$CostCenterSlug
    )

    $match = $ExistingCostCenters | Where-Object {
        $_.name -eq $CostCenterSlug -or
        $_.display_name -eq $CostCenterName -or
        $_.displayName -eq $CostCenterName -or
        $_.name -eq $CostCenterName
    }

    return ($null -ne $match)
}

# Function to create enterprise cost center in GitHub
function New-EnterpriseCostCenter {
    param(
        [string]$BaseUrl,
        [string]$Endpoint,
        [string]$Token,
        [string]$CostCenterName,
        [string]$CostCenterSlug
    )

    $body = @{
        name         = $CostCenterSlug
        display_name = $CostCenterName
    }

    return Invoke-GitHubApi -BaseUrl $BaseUrl -Endpoint $Endpoint -Method "POST" -Token $Token -Body $body
}

# Main script execution
try {
    if ($DryRun -and $LiveRun) {
        throw "DryRun and LiveRun cannot both be specified. Use only one override switch."
    }

    # Initialize log file
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "GitHub Enterprise Cost Center Provisioning Script Started" -Level "INFO"
    Write-Log -Message "Log File: $logFilePath" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    Write-ColorOutput "`n=== GitHub Enterprise Cost Center Provisioning Script ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file: $logFileName`n" -Color Gray -Level "INFO"

    # Load configuration from .env file
    Write-ColorOutput "Loading configuration from .env file..." -Color Yellow -Level "INFO"
    $envConfig = Get-EnvConfig -EnvFilePath $EnvFilePath

    if ($envConfig.Count -eq 0) {
        throw ".env file is empty or could not be loaded. Please ensure .env file exists and contains required configuration."
    }

    # Get and validate required configuration
    $requiredKeys = @('GITHUB_ENTERPRISE', 'GITHUB_PAT', 'DRY_RUN', 'CSV_FILE_PATH')
    foreach ($key in $requiredKeys) {
        if (-not $envConfig.ContainsKey($key)) {
            throw "$key not found in .env file"
        }
    }

    $GitHubEnterprise = $envConfig['GITHUB_ENTERPRISE']
    $GitHubPAT = $envConfig['GITHUB_PAT']
    $dryRunFromEnv = $envConfig['DRY_RUN'] -eq 'true'
    $effectiveDryRun = $dryRunFromEnv

    if ($DryRun) {
        $effectiveDryRun = $true
    }
    elseif ($LiveRun) {
        $effectiveDryRun = $false
    }
    $CsvPath = $envConfig['CSV_FILE_PATH']
    $GitHubApiBaseUrl = if ($envConfig.ContainsKey('GITHUB_API_BASE_URL') -and -not [string]::IsNullOrWhiteSpace($envConfig['GITHUB_API_BASE_URL'])) {
        $envConfig['GITHUB_API_BASE_URL'].TrimEnd('/')
    }
    else {
        'https://api.github.com'
    }

    $CostCenterEndpoint = if ($envConfig.ContainsKey('GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT') -and -not [string]::IsNullOrWhiteSpace($envConfig['GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT'])) {
        $envConfig['GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT']
    }
    else {
        "/enterprises/$GitHubEnterprise/settings/billing/cost-centers"
    }

    Write-ColorOutput "GitHub Enterprise: $GitHubEnterprise" -Color Cyan -Level "INFO"
    Write-ColorOutput "GitHub API Base URL: $GitHubApiBaseUrl" -Color Cyan -Level "INFO"
    Write-ColorOutput "Enterprise Cost Center Endpoint: $CostCenterEndpoint" -Color Cyan -Level "INFO"
    Write-ColorOutput "GitHub PAT: ***configured***" -Color Cyan -Level "INFO"
    Write-ColorOutput "Dry Run Mode (.env): $dryRunFromEnv" -Color Gray -Level "INFO"
    if ($DryRun -or $LiveRun) {
        Write-ColorOutput "Dry Run Override (CLI): $(if ($DryRun) { 'DryRun' } else { 'LiveRun' })" -Color Cyan -Level "INFO"
    }
    Write-ColorOutput "Dry Run Mode (effective): $effectiveDryRun" -Color $(if ($effectiveDryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"

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

    $requiredColumns = @('cost_center_name')
    $csvColumns = $mappingData[0].PSObject.Properties.Name
    foreach ($column in $requiredColumns) {
        if ($column -notin $csvColumns) {
            throw "Required column '$column' not found in CSV file"
        }
    }

    Write-ColorOutput "Total rows in CSV: $($mappingData.Count)" -Color Cyan -Level "INFO"

    # Extract unique cost center names
    $uniqueCostCenters = $mappingData |
    Select-Object -ExpandProperty cost_center_name -Unique |
    Where-Object { -not [string]::IsNullOrWhiteSpace($_) } |
    Sort-Object

    Write-ColorOutput "Unique Cost Centers found: $($uniqueCostCenters.Count)" -Color Cyan -Level "INFO"
    Write-ColorOutput "`nCost Centers to ensure (enterprise-level):" -Color Yellow -Level "INFO"
    $uniqueCostCenters | ForEach-Object {
        Write-ColorOutput "  - $_" -Color White -Level "INFO"
    }

    # Retrieve existing enterprise cost centers
    Write-ColorOutput "`nRetrieving existing enterprise Cost Centers from GitHub..." -Color Yellow -Level "INFO"

    try {
        $existingCostCenters = Get-EnterpriseCostCenters -BaseUrl $GitHubApiBaseUrl -Endpoint $CostCenterEndpoint -Token $GitHubPAT
    }
    catch {
        Write-ColorOutput "✗ Failed to retrieve existing enterprise Cost Centers" -Color Red -Level "ERROR"
        Write-ColorOutput "Error: $_" -Color Red -Level "ERROR"
        Write-ColorOutput "`nCannot proceed safely without knowing existing Cost Centers." -Color Red -Level "ERROR"
        Write-ColorOutput "This prevents accidental duplicate creation." -Color Red -Level "ERROR"
        throw
    }

    # Process each unique cost center
    Write-ColorOutput "`n=== Processing Enterprise Cost Centers ===" -Color Cyan -Level "INFO"
    $created = 0
    $skipped = 0
    $dryRunActions = 0
    $errors = 0

    foreach ($costCenterName in $uniqueCostCenters) {
        Write-ColorOutput "`nProcessing: $costCenterName" -Color Yellow -Level "INFO"

        try {
            $costCenterSlug = ConvertTo-CostCenterSlug -Name $costCenterName
            Write-ColorOutput "  System name: $costCenterSlug" -Color Gray -Level "DEBUG"

            if (Test-CostCenterExists -ExistingCostCenters $existingCostCenters -CostCenterName $costCenterName -CostCenterSlug $costCenterSlug) {
                Write-ColorOutput "  ✓ Already exists - Skipping" -Color Green -Level "INFO"
                $skipped++
                continue
            }

            if ($effectiveDryRun) {
                Write-ColorOutput "  [DRY-RUN] Would create enterprise Cost Center: $costCenterName (name=$costCenterSlug)" -Color Magenta -Level "INFO"
                $dryRunActions++
            }
            else {
                Write-ColorOutput "  Creating enterprise Cost Center..." -Color Yellow -Level "INFO"

                $result = New-EnterpriseCostCenter -BaseUrl $GitHubApiBaseUrl `
                    -Endpoint $CostCenterEndpoint `
                    -Token $GitHubPAT `
                    -CostCenterName $costCenterName `
                    -CostCenterSlug $costCenterSlug

                Write-ColorOutput "  ✓ Created successfully" -Color Green -Level "INFO"
                if ($result.id) {
                    Write-ColorOutput "  Cost Center ID: $($result.id)" -Color Gray -Level "DEBUG"
                }
                $created++

                # Keep local list updated to avoid duplicate creates in same run
                $existingCostCenters += [pscustomobject]@{ name = $costCenterSlug; display_name = $costCenterName }
            }
        }
        catch {
            Write-ColorOutput "  ✗ Error processing Cost Center: $($_.Exception.Message)" -Color Red -Level "ERROR"
            $errors++
        }
    }

    # Summary
    Write-ColorOutput "`n=== Summary ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Mode: $(if ($effectiveDryRun) { 'DRY-RUN' } else { 'LIVE' })" -Color $(if ($effectiveDryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    Write-ColorOutput "Total Cost Centers processed: $($uniqueCostCenters.Count)" -Color White -Level "INFO"
    Write-ColorOutput "Already existing (skipped): $skipped" -Color Green -Level "INFO"

    if ($effectiveDryRun) {
        Write-ColorOutput "Would create (dry-run): $dryRunActions" -Color Magenta -Level "INFO"
    }
    else {
        Write-ColorOutput "Newly created: $created" -Color Green -Level "INFO"
    }

    Write-ColorOutput "Errors: $errors" -Color $(if ($errors -gt 0) { "Red" } else { "Green" }) -Level $(if ($errors -gt 0) { "ERROR" } else { "INFO" })
    Write-ColorOutput "`nManual follow-up required:" -Color Yellow -Level "WARN"
    Write-ColorOutput "  Link organizations to the correct Azure subscriptions in GitHub billing settings." -Color Yellow -Level "WARN"
    Write-ColorOutput "Completed at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file saved to: $logFilePath" -Color Gray -Level "INFO"

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Script completed successfully" -Level "INFO"
    Write-Log -Message "Mode: $(if ($effectiveDryRun) { 'DRY-RUN' } else { 'LIVE' }) | Total: $($uniqueCostCenters.Count) | Created: $created | Dry-run: $dryRunActions | Skipped: $skipped | Errors: $errors" -Level "INFO"
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
