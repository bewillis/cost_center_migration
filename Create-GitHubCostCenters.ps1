<#
.SYNOPSIS
    Ensures GitHub Cost Centers exist based on mapping.csv

.DESCRIPTION
    This script imports a CSV file (configured in .env), extracts unique cost_center_name values,
    and ensures corresponding GitHub Cost Centers exist in the target GitHub organization.
    Creates any missing Cost Centers based on dry-run mode setting.
    
    All configuration is read from the .env file in the script directory.
    GitHub PAT token is never logged or echoed.

.EXAMPLE
    .\Ensure-GitHubCostCenters.ps1
    
    Reads all configuration from .env file and creates missing Cost Centers (or logs what would be created if DRY_RUN=true)
#>

# Configuration - Path to .env file
$EnvFilePath = Join-Path $PSScriptRoot ".env"

# Set error action preference
$ErrorActionPreference = "Stop"

# Configure logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFileName = "Ensure-GitHubCostCenters_$timestamp.log"
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
                if ($key -like "*PAT*" -or $key -like "*TOKEN*" -or $key -like "*SECRET*" -or $key -like "*PASSWORD*") {
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
    
    $uri = "https://api.github.com$Endpoint"
    
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
        
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        $errorMessage = $_.Exception.Message
        
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                $errorMessage = $errorJson.message
            }
            catch {
                $errorMessage = $_.ErrorDetails.Message
            }
        }
        
        throw "GitHub API Error [$statusCode]: $errorMessage"
    }
}

# Function to get existing cost centers from GitHub
function Get-GitHubCostCenters {
    param(
        [string]$Organization,
        [string]$Token
    )
    
    try {
        Write-ColorOutput "  Fetching existing cost centers..." -Color Gray -Level "INFO"
        
        # GitHub Enterprise Cloud API endpoint for cost centers
        # Note: This endpoint may vary based on your GitHub setup
        # Using /orgs/{org}/cost-centers as the standard endpoint
        $costCenters = Invoke-GitHubApi -Endpoint "/orgs/$Organization/cost-centers" -Token $Token
        
        Write-ColorOutput "  Found $($costCenters.Count) existing cost center(s)" -Color Gray -Level "INFO"
        return $costCenters
    }
    catch {
        # If the endpoint doesn't exist or returns 404, return empty array
        if ($_.Exception.Message -match "404") {
            Write-ColorOutput "  Cost centers endpoint not found or no cost centers exist" -Color Yellow -Level "WARN"
            return @()
        }
        throw
    }
}

# Function to check if a cost center exists
function Test-CostCenterExists {
    param(
        [array]$ExistingCostCenters,
        [string]$CostCenterName
    )
    
    # Check if cost center exists by name
    $exists = $ExistingCostCenters | Where-Object { $_.name -eq $CostCenterName -or $_.display_name -eq $CostCenterName }
    return ($null -ne $exists)
}

# Function to create a cost center in GitHub
function New-GitHubCostCenter {
    param(
        [string]$Organization,
        [string]$Token,
        [string]$CostCenterName
    )
    
    try {
        $body = @{
            name         = $CostCenterName
            display_name = $CostCenterName
        }
        
        $result = Invoke-GitHubApi -Endpoint "/orgs/$Organization/cost-centers" `
            -Method "POST" `
            -Token $Token `
            -Body $body
        
        return $result
    }
    catch {
        throw "Failed to create cost center: $_"
    }
}

# Main script execution
try {
    # Initialize log file
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "GitHub Cost Center Provisioning Script Started" -Level "INFO"
    Write-Log -Message "Log File: $logFilePath" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
    
    Write-ColorOutput "`n=== GitHub Cost Center Provisioning Script ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file: $logFileName`n" -Color Gray -Level "INFO"

    # Load configuration from .env file
    Write-ColorOutput "Loading configuration from .env file..." -Color Yellow -Level "INFO"
    $envConfig = Get-EnvConfig -EnvFilePath $EnvFilePath
    
    if ($envConfig.Count -eq 0) {
        throw ".env file is empty or could not be loaded. Please ensure .env file exists and contains required configuration."
    }
    
    # Get and validate required configuration
    $requiredKeys = @('GITHUB_ORG', 'GITHUB_PAT', 'DRY_RUN', 'CSV_FILE_PATH')
    foreach ($key in $requiredKeys) {
        if (-not $envConfig.ContainsKey($key)) {
            throw "$key not found in .env file"
        }
    }
    
    $GitHubOrg = $envConfig['GITHUB_ORG']
    $GitHubPAT = $envConfig['GITHUB_PAT']
    $DryRun = $envConfig['DRY_RUN'] -eq 'true'
    $CsvPath = $envConfig['CSV_FILE_PATH']
    
    Write-ColorOutput "GitHub Organization: $GitHubOrg" -Color Cyan -Level "INFO"
    Write-ColorOutput "GitHub PAT: ***configured***" -Color Cyan -Level "INFO"
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

    # Import CSV and validate required columns
    Write-ColorOutput "`nImporting CSV file..." -Color Yellow -Level "INFO"
    $mappingData = Import-Csv -Path $CsvPath
    
    if (-not $mappingData) {
        throw "CSV file is empty or could not be imported"
    }
    
    # Validate required columns
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
    Write-ColorOutput "`nCost Centers to ensure:" -Color Yellow -Level "INFO"
    $uniqueCostCenters | ForEach-Object { 
        Write-ColorOutput "  - $_" -Color White -Level "INFO"
    }

    # Get existing cost centers from GitHub
    Write-ColorOutput "`nRetrieving existing Cost Centers from GitHub..." -Color Yellow -Level "INFO"
    Write-ColorOutput "Organization: $GitHubOrg" -Color Cyan -Level "INFO"
    
    try {
        $existingCostCenters = Get-GitHubCostCenters -Organization $GitHubOrg -Token $GitHubPAT
        
        if ($existingCostCenters -and $existingCostCenters.Count -gt 0) {
            Write-ColorOutput "Found $($existingCostCenters.Count) existing Cost Center(s)" -Color Green -Level "INFO"
        }
        else {
            Write-ColorOutput "No existing Cost Centers found" -Color Yellow -Level "WARN"
            $existingCostCenters = @()
        }
    }
    catch {
        Write-ColorOutput "Warning: Could not retrieve existing Cost Centers. Error: $_" -Color Yellow -Level "WARN"
        Write-ColorOutput "Continuing with assumption that no Cost Centers exist..." -Color Yellow -Level "WARN"
        $existingCostCenters = @()
    }

    # Process each unique cost center
    Write-ColorOutput "`n=== Processing Cost Centers ===" -Color Cyan -Level "INFO"
    $created = 0
    $skipped = 0
    $dryRunActions = 0
    $errors = 0

    foreach ($costCenterName in $uniqueCostCenters) {
        Write-ColorOutput "`nProcessing: $costCenterName" -Color Yellow -Level "INFO"
        
        # Check if cost center already exists
        if (Test-CostCenterExists -ExistingCostCenters $existingCostCenters -CostCenterName $costCenterName) {
            Write-ColorOutput "  ✓ Already exists - Skipping" -Color Green -Level "INFO"
            $skipped++
            continue
        }

        # Create cost center or log dry-run action
        if ($DryRun) {
            Write-ColorOutput "  [DRY-RUN] Would create Cost Center: $costCenterName" -Color Magenta -Level "INFO"
            $dryRunActions++
        }
        else {
            try {
                Write-ColorOutput "  Creating Cost Center..." -Color Yellow -Level "INFO"
                
                $result = New-GitHubCostCenter -Organization $GitHubOrg `
                    -Token $GitHubPAT `
                    -CostCenterName $costCenterName
                
                Write-ColorOutput "  ✓ Created successfully" -Color Green -Level "INFO"
                $created++
            }
            catch {
                Write-ColorOutput "  ✗ Error creating Cost Center: $_" -Color Red -Level "ERROR"
                Write-Log -Message "Detailed error for $costCenterName : $($_.Exception.Message)" -Level "ERROR"
                $errors++
            }
        }
    }

    # Summary
    Write-ColorOutput "`n=== Summary ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' })" -Color $(if ($DryRun) { "Magenta" } else { "Yellow" }) -Level "INFO"
    Write-ColorOutput "Total Cost Centers processed: $($uniqueCostCenters.Count)" -Color White -Level "INFO"
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
    Write-Log -Message "Mode: $(if ($DryRun) { 'DRY-RUN' } else { 'LIVE' }) | Total: $($uniqueCostCenters.Count) | Created: $created | Dry-run: $dryRunActions | Skipped: $skipped | Errors: $errors" -Level "INFO"
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
