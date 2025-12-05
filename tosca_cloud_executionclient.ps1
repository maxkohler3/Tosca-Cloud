  pwsh ./Invoke-ToscaCloudPlaylist.ps1 `
    -TokenUrl "https://amspresales.okta.com/oauth2/default/v1/token" `
    -ClientId "Tricentis_Cloud_API" `
    -ClientSecret $env:TOSCA_CLIENT_SECRET `
    -Scope "tta" `
    -TenantBaseUrl "https://amspresales.my.tricentis.com/8955895b-cacf-4695-a1bb-1210863f6212" `
    -PlaylistConfigFilePath "PlaylistConfig.json" `
    -ResultsFileName "results.xml" `
    -ResultsFolderPath "C:\Tricentis\Tosca\Results" `
    -VerboseMode

[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)]  [string]$TokenUrl,
    [Parameter(Mandatory=$true)]  [string]$ClientId,
    [Parameter(Mandatory=$true)]  [string]$ClientSecret,
	[Parameter(Mandatory=$false)] [string]$BearerToken,
    [Parameter(Mandatory=$false)] [string]$Scope = "tta",
    [Parameter(Mandatory=$true)]  [string]$TenantBaseUrl,
	[Parameter(Mandatory=$true)]  [string]$SpaceId = "",

    [Parameter(Mandatory=$false)] [string]$PlaylistId,
    [Parameter(Mandatory=$false)] [string]$PlaylistConfigFilePath,
    [Parameter(Mandatory=$false)] [string]$PlaylistName,

    [Parameter(Mandatory=$false)] [int]$PollSeconds = 10,
    [Parameter(Mandatory=$false)] [int]$TimeoutMinutes = 60,
    [Parameter(Mandatory=$false)] [string]$ResultsFileName = "results.xml",
    [Parameter(Mandatory=$false)] [string]$ResultsFolderPath = ".",
    [Parameter(Mandatory=$false)] [switch]$VerboseMode,
    [Parameter(Mandatory=$false)] [switch]$enqueueOnly

)

# ---------- Utility Functions ----------
function Write-Banner {
    param([string]$Text)
    Write-Host "`n=== $Text ===" -ForegroundColor Cyan
}
function Write-Info  { param([string]$m) Write-Host "[$(Get-Date -Format o)] $m" }
function Write-ErrorLine { param([string]$m) Write-Host "[$(Get-Date -Format o)] ERROR: $m" -ForegroundColor Red }
function Write-DebugMessage { param([string]$m) if ($VerboseMode) { Write-Host "[DEBUG] $m" -ForegroundColor Yellow } }

function Invoke-WithRetry {
  param(
    [Parameter(Mandatory=$true)][scriptblock]$Script,
    [int]$MaxRetries = 3,
    [int]$DelaySeconds = 5
  )
  $attempt = 0
  while ($true) {
    try { return & $Script }
    catch {
      $attempt++
      if ($attempt -ge $MaxRetries) { throw }
      Write-Info "Transient error: $($_.Exception.Message). Retry $attempt/$MaxRetries in $DelaySeconds sec..."
      Start-Sleep -Seconds $DelaySeconds
    }
  }
}

# ---------- NEW: Resolve Playlist by Name ----------
function Get-PlaylistIdByName {
    param (
        [Parameter(Mandatory=$true)] [string]$TenantBaseUrl,
        [Parameter(Mandatory=$true)] [string]$SpaceId,
        [Parameter(Mandatory=$true)] [string]$BearerToken,
        [Parameter(Mandatory=$true)] [string]$PlaylistName
    )

    Write-Info "Resolving Playlist ID for '$PlaylistName'..."
    $encodedName = [uri]::EscapeDataString($PlaylistName)
    $url = "$TenantBaseUrl/$SpaceId/_playlists/api/v2/playlists?name=equals($encodedName)"

    try {
        $response = Invoke-RestMethod -Method GET -Uri $url -Headers @{
            "Accept"        = "application/json"
            "Authorization" = "Bearer $BearerToken"
        } -ErrorAction Stop

        if ($null -eq $response.items -or $response.items.Count -eq 0) {
            throw "No playlist found with name '$PlaylistName'."
        }

        $playlist = $response.items[0]
        Write-Info "Found Playlist ID: $($playlist.id)"
        return $playlist.id
    }
    catch {
        Write-ErrorLine "Failed to resolve Playlist ID: $($_.Exception.Message)"
        throw
    }
}

# ---------- 1) Get OAuth token (if not provided) ----------
Write-Banner "STEP 1: Authentication"

if (-not $BearerToken) {
    Write-Info "Requesting OAuth token..."
    $tokenBody = "grant_type=client_credentials&client_id=$([uri]::EscapeDataString($ClientId))&client_secret=$([uri]::EscapeDataString($ClientSecret))&scope=$([uri]::EscapeDataString($Scope))"

    $tokenResponse = Invoke-WithRetry {
      Invoke-RestMethod -Method POST -Uri $TokenUrl `
        -Headers @{ "Accept"="application/json"; "Content-Type"="application/x-www-form-urlencoded" } `
        -Body $tokenBody
    }
    $accessToken = $tokenResponse.access_token
    if (-not $accessToken) { throw "No access_token returned from token endpoint." }
    $BearerToken = $accessToken
    Write-Info "Token acquired."
}
else {
    Write-Info "Using pre-supplied Bearer token."
}

# Common headers
$apiHeaders = @{
  "Authorization" = "Bearer $BearerToken"
  "Accept"        = "application/json"
  "Content-Type"  = "application/json"
}

# ---------- 2) Trigger playlist run ----------
Write-Banner "STEP 2: Trigger Playlist Run"

try {
    if ($PlaylistConfigFilePath -and (Test-Path $PlaylistConfigFilePath)) {
        Write-Info "Using JSON payload from file: $PlaylistConfigFilePath"
        $triggerBody = Get-Content -Path $PlaylistConfigFilePath -Raw
        try { $null = $triggerBody | ConvertFrom-Json }
        catch { throw "Invalid JSON in PlaylistConfigFilePath '$PlaylistConfigFilePath': $($_.Exception.Message)" }
    }
    else {
        if (-not $PlaylistId) {
            if ($PlaylistName) {
                if (-not $SpaceId) { throw "SpaceId is required when resolving PlaylistName." }
                Write-Info "No PlaylistId provided — resolving via PlaylistName..."
                $PlaylistId = Get-PlaylistIdByName -TenantBaseUrl $TenantBaseUrl -SpaceId $SpaceId -BearerToken $BearerToken -PlaylistName $PlaylistName
            }
            else {
                throw "You must provide either PlaylistId, PlaylistName, or PlaylistConfigFilePath."
            }
        }

        $triggerBodyObj = [ordered]@{ playlistId = $PlaylistId; private = $false; parameterOverrides = @() }
        $triggerBody = $triggerBodyObj | ConvertTo-Json -Depth 5
    }

    Write-DebugMessage "Trigger request body:`n$triggerBody"

    $triggerUrl = "$TenantBaseUrl/$SpaceId/_playlists/api/v2/playlistRuns"
    Write-DebugMessage "Calling: $triggerUrl"

    $triggerResp = Invoke-WithRetry {
        Invoke-RestMethod -Method POST -Uri $triggerUrl -Headers $apiHeaders -Body $triggerBody
    }

    if ($triggerResp.id) { 
        $runId = $triggerResp.id 
    } elseif ($triggerResp.executionId) { 
        $runId = $triggerResp.executionId 
    } else { 
        $runId = $null 
    }

    if (-not $runId) { throw "No run ID returned. Raw response: $($triggerResp | ConvertTo-Json -Depth 6)" }
    Write-Info "Playlist run started successfully. Run ID: $runId"
	
	if ($enqueueOnly) {
        Write-Info "enqueueOnly switch provided — skipping monitoring and results retrieval."

        Write-Info "Playlist triggered successfully. Run ID: $runId"
        exit 0
}
}
catch {
    Write-ErrorLine "Failed to trigger playlist: $($_.Exception.Message)"
    exit 1
}

# ---------- 3) Poll Status ----------
Write-Banner "STEP 3: Monitor Playlist Run"

$deadline = (Get-Date).AddMinutes($TimeoutMinutes)
$activeStates = @("pending","running","starting")
$finalState = $null

while ((Get-Date) -lt $deadline) {
    try {
        Start-Sleep -Seconds $PollSeconds
        $statusUrl = "$TenantBaseUrl/$SpaceId/_playlists/api/v2/playlistRuns/$runId"
        $statusResp = Invoke-RestMethod -Method GET -Uri $statusUrl -Headers $apiHeaders
        $state = $statusResp.state
        if (-not $state) {
            Write-Info "Warning: no state in response; will retry."
            continue
        }
        Write-Info "Current playlist state: $state"
        $normalized = $state.ToLower()

        if ($activeStates -contains $normalized) { continue }

        $finalState = $normalized
        break
    }
    catch {
        Write-ErrorLine "Status check error: $($_.Exception.Message); retrying..."
        continue
    }
}

if (-not $finalState) {
    Write-ErrorLine "Timeout reached without final state"
    $finalState = "timeout"
}

Write-Info "Final state: $finalState"

# ---------- 4) Fetch JUnit results ----------
Write-Banner "STEP 4: Retrieve JUnit Results"

try {
    $resultsUrl = "$TenantBaseUrl/$SpaceId/_playlists/api/v2/playlistRuns/$runId/junit"
    Write-DebugMessage "Attempting to download JUnit results from: $resultsUrl"

    if (-not (Test-Path $ResultsFolderPath)) {
        Write-Info "Creating results folder: $ResultsFolderPath"
        New-Item -ItemType Directory -Force -Path $ResultsFolderPath | Out-Null
    }

    $resultsFilePath = Join-Path -Path $ResultsFolderPath -ChildPath $ResultsFileName
    $maxRetries = 12
    $retryDelay = 10
    $attempt = 0
    $junitXml = $null

    do {
        try {
            $attempt++
            Write-Info "[$attempt/$maxRetries] Fetching JUnit results..."
            $response = Invoke-RestMethod -Method GET -Uri $resultsUrl -Headers @{
                "Accept"        = "application/xml"
                "Authorization" = "Bearer $BearerToken"
            } -TimeoutSec 60

            $junitXml = $response.OuterXml
            if ($junitXml -match "<testcase") {
                Write-Info "Valid JUnit results detected on attempt $attempt."
                break
            }
            else {
                Write-Info "Results not ready yet (no '<testcase>' found). Waiting $retryDelay seconds..."
                Start-Sleep -Seconds $retryDelay
            }
        }
        catch {
            Write-ErrorLine "Error fetching JUnit (attempt $attempt): $($_.Exception.Message)"
            Start-Sleep -Seconds $retryDelay
        }
    } while ($attempt -lt $maxRetries)

    if (-not [string]::IsNullOrWhiteSpace($junitXml)) {
        Write-DebugMessage "Validating JUnit XML structure..."
        try { [xml]$null = $junitXml; Write-DebugMessage "XML validation successful." }
        catch { Write-ErrorLine "Warning: Invalid XML detected; saving raw content anyway." }

        $utf8Bom = New-Object System.Text.UTF8Encoding($true)
        $formattedXml = $junitXml -replace 'encoding="utf-16"', 'encoding="utf-8"'
        [System.IO.File]::WriteAllText($resultsFilePath, $formattedXml, $utf8Bom)

        if (Test-Path $resultsFilePath) {
            $fileInfo = Get-Item $resultsFilePath
            Write-Info "JUnit results saved to: $resultsFilePath (${($fileInfo.Length)} bytes)"
        }
        else {
            Write-ErrorLine "Warning: JUnit results file not found after write."
        }
    }
    else {
        Write-ErrorLine "No JUnit content returned after waiting $($maxRetries * $retryDelay) seconds."
    }
}
catch {
    Write-ErrorLine "Could not download JUnit results: $($_.Exception.Message)"
}

# ---------- 5) Exit based on result ----------
Write-Banner "STEP 5: Final Result"

if ($finalState -in @("succeeded","passed","completed")) {
    Write-Info "Playlist [$PlaylistId] completed successfully."
    exit 0
}
elseif ($finalState -eq "failed") {
    Write-ErrorLine "Playlist [$PlaylistId] failed."
    exit 1
}
elseif ($finalState -eq "canceled") {
    Write-ErrorLine "Playlist [$PlaylistId] was cancelled."
    exit 1
}
else {
    Write-ErrorLine ("Execution ended with state '{0}'" -f $finalState)
    exit 1

}


