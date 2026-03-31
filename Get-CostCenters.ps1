<#
.SYNOPSIS
    Lists existing GitHub Enterprise cost centers using .env configuration.

.DESCRIPTION
    This script reads GitHub configuration from .env, calls the enterprise cost center
    endpoint, and prints the cost centers that already exist.

    It does not create, update, or delete any resources.

.EXAMPLE
    .\Get-CostCenters.ps1

    Lists enterprise cost centers from the configured endpoint.
#>

# Configuration - Path to .env file
$EnvFilePath = Join-Path $PSScriptRoot ".env"

# Set error action preference
$ErrorActionPreference = "Stop"

# Configure logging
$timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$logFileName = "Get-CostCenters_$timestamp.log"
$logFilePath = Join-Path $PSScriptRoot $logFileName

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "INFO"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"
    Add-Content -Path $logFilePath -Value $logMessage -ErrorAction SilentlyContinue
}

function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White",
        [string]$Level = "INFO"
    )

    Write-Host $Message -ForegroundColor $Color
    $cleanMessage = $Message -replace "`n", " " -replace "`r", ""
    Write-Log -Message $cleanMessage -Level $Level
}

function Get-EnvConfig {
    param(
        [string]$EnvFilePath
    )

    if (-not (Test-Path $EnvFilePath)) {
        throw ".env file not found at: $EnvFilePath"
    }

    Write-ColorOutput "Loading configuration from .env file: $EnvFilePath" -Color Green -Level "INFO"

    $config = @{}
    Get-Content $EnvFilePath | ForEach-Object {
        $line = $_.Trim()

        if ($line -and -not $line.StartsWith('#')) {
            $index = $line.IndexOf('=')
            if ($index -gt 0) {
                $key = $line.Substring(0, $index).Trim()
                $value = $line.Substring($index + 1).Trim()
                $value = $value -replace '^["'']|["'']$', ''

                $config[$key] = $value

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

function Invoke-GitHubApi {
    param(
        [string]$BaseUrl,
        [string]$Endpoint,
        [string]$Token
    )

    $headers = @{
        "Authorization"        = "Bearer $Token"
        "Accept"               = "application/vnd.github+json"
        "X-GitHub-Api-Version" = "2022-11-28"
    }

    $uri = "$BaseUrl$Endpoint"

    try {
        return Invoke-RestMethod -Uri $uri -Method Get -Headers $headers
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

try {
    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "GitHub Enterprise Cost Center List Script Started" -Level "INFO"
    Write-Log -Message "Log File: $logFilePath" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"

    Write-ColorOutput "`n=== GitHub Enterprise Cost Centers ===" -Color Cyan -Level "INFO"
    Write-ColorOutput "Started at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file: $logFileName`n" -Color Gray -Level "INFO"

    $envConfig = Get-EnvConfig -EnvFilePath $EnvFilePath

    if (-not $envConfig.ContainsKey('GITHUB_PAT')) {
        throw "GITHUB_PAT not found in .env"
    }

    $hasEnterprise = $envConfig.ContainsKey('GITHUB_ENTERPRISE') -and -not [string]::IsNullOrWhiteSpace($envConfig['GITHUB_ENTERPRISE'])
    $hasEndpointOverride = $envConfig.ContainsKey('GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT') -and -not [string]::IsNullOrWhiteSpace($envConfig['GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT'])

    if (-not $hasEnterprise -and -not $hasEndpointOverride) {
        throw "Either GITHUB_ENTERPRISE or GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT must be set in .env"
    }

    $gitHubApiBaseUrl = if ($envConfig.ContainsKey('GITHUB_API_BASE_URL') -and -not [string]::IsNullOrWhiteSpace($envConfig['GITHUB_API_BASE_URL'])) {
        $envConfig['GITHUB_API_BASE_URL'].TrimEnd('/')
    }
    else {
        'https://api.github.com'
    }

    $endpoint = if ($hasEndpointOverride) {
        $envConfig['GITHUB_ENTERPRISE_COST_CENTER_ENDPOINT']
    }
    else {
        "/enterprises/$($envConfig['GITHUB_ENTERPRISE'])/settings/billing/cost-centers"
    }

    Write-ColorOutput "GitHub API Base URL: $gitHubApiBaseUrl" -Color Cyan -Level "INFO"
    Write-ColorOutput "Cost Center Endpoint: $endpoint" -Color Cyan -Level "INFO"
    Write-ColorOutput "GitHub PAT: ***configured***" -Color Cyan -Level "INFO"

    Write-ColorOutput "`nFetching cost centers..." -Color Yellow -Level "INFO"
    $response = Invoke-GitHubApi -BaseUrl $gitHubApiBaseUrl -Endpoint $endpoint -Token $envConfig['GITHUB_PAT']
    $costCenters = ConvertTo-CostCenterArray -Response $response

    Write-ColorOutput "`nTotal cost centers found: $($costCenters.Count)" -Color Green -Level "INFO"

    if ($costCenters.Count -eq 0) {
        Write-ColorOutput "No cost centers found." -Color Yellow -Level "WARN"
    }
    else {
        Write-ColorOutput "`nExisting cost centers:" -Color Yellow -Level "INFO"

        $costCenters | ForEach-Object {
            $displayName = if ($_.display_name) {
                $_.display_name
            }
            elseif ($_.displayName) {
                $_.displayName
            }
            elseif ($_.name) {
                $_.name
            }
            else {
                '<unknown>'
            }

            $systemName = if ($_.name) { $_.name } else { '<n/a>' }
            $id = if ($_.id) { $_.id } else { '<n/a>' }

            Write-ColorOutput "  - Display: $displayName | Name: $systemName | Id: $id" -Color White -Level "INFO"
        }
    }

    Write-ColorOutput "`nCompleted at: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')" -Color Gray -Level "INFO"
    Write-ColorOutput "Log file saved to: $logFilePath" -Color Gray -Level "INFO"

    Write-Log -Message "========================================" -Level "INFO"
    Write-Log -Message "Script completed successfully" -Level "INFO"
    Write-Log -Message "Total cost centers found: $($costCenters.Count)" -Level "INFO"
    Write-Log -Message "========================================" -Level "INFO"
}
catch {
    Write-ColorOutput "`nScript failed with error:" -Color Red -Level "ERROR"
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
