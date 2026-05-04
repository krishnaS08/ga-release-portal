using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

# --- Validate request body ---
$body = $Request.Body

$requiredFields = @('teamName', 'releaseType', 'submitterEmail', 'targetMonth', 'epics')
$missing = $requiredFields | Where-Object { -not $body.$_ }

if ($missing) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Missing required fields: $($missing -join ', ')" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Validate epics array
if (-not ($body.epics -is [System.Collections.IEnumerable]) -or $body.epics.Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "At least one epic is required" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

foreach ($epic in $body.epics) {
    if (-not $epic.epicNumber) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Each epic must have an epicNumber" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if (-not ($epic.apps -is [System.Collections.IEnumerable]) -or $epic.apps.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Epic #$($epic.epicNumber) must have at least one app" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    foreach ($app in $epic.apps) {
        if (-not $app.repoName -or -not $app.sourceBranch) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = (@{ message = "Epic #$($epic.epicNumber): each app must have repoName and sourceBranch" } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }
}

# Validate release type
if ($body.releaseType -notin @('feature', 'stability')) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "releaseType must be 'feature' or 'stability'" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Validate email format
if ($body.submitterEmail -notmatch '^[^@]+@[^@]+\.[^@]+$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Invalid email format" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Build request record ---
$requestId = New-RequestId

$record = @{
    requestId          = $requestId
    teamName           = $body.teamName
    releaseType        = $body.releaseType
    submitterEmail     = $body.submitterEmail
    targetMonth        = $body.targetMonth
    epics              = ($body.epics | ConvertTo-Json -Depth 5 -Compress)
    notes              = $body.notes ?? ''
    submittedAt        = (Get-Date).ToUniversalTime().ToString('o')
    status             = 'pending'
}

# --- Save to Azure Table Storage ---
try {
    Save-RequestToStorage -Request $record
    Write-Host "GA request $requestId saved successfully"
}
catch {
    Write-Error "Failed to save request: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to save request. Please try again." } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Return success ---
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        message   = 'GA release request submitted successfully'
        requestId = $requestId
        status    = 'pending'
    } | ConvertTo-Json)
    Headers    = @{ 'Content-Type' = 'application/json' }
})
