using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

$method = $Request.Method.ToUpper()

# Helper: resolve which config type this request targets
# type=taskParent  → Task Parent WI (GA-Initial task parent, changes monthly)
# (default)        → Active Release WI (epic filtering on submit page)
function Get-ConfigType {
    param($QueryType, $BodyType)
    $t = if ($QueryType) { $QueryType } elseif ($BodyType) { $BodyType } else { '' }
    return $t.Trim().ToLower()
}

# ── DELETE ─────────────────────────────────────────────────────────────────────
if ($method -eq 'DELETE') {
    $configType = Get-ConfigType -QueryType $Request.Query.type -BodyType $null
    try {
        if ($configType -eq 'taskparent') {
            Clear-TaskParentWiConfig | Out-Null
        } else {
            Clear-ActiveReleaseConfig | Out-Null
        }
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ cleared = $true } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    } catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = (@{ message = "Failed to clear config: $_" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    }
    return
}

# ── POST — save config ─────────────────────────────────────────────────────────
if ($method -eq 'POST') {
    $body       = $Request.Body
    $releaseId  = [string]$body.id
    $configType = Get-ConfigType -QueryType $null -BodyType ([string]($body.type ?? ''))

    if (-not $releaseId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Missing required field: id" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    try {
        $baseUrl = Get-AdoBaseUrl
        $wiUrl   = "$baseUrl/_apis/wit/workitems/$releaseId`?fields=System.Id,System.Title"
        $wi      = Invoke-AdoApi -Url $wiUrl
        $title   = $wi.fields.'System.Title'
        if (-not $title) { throw "Work item $releaseId has no title" }

        if ($configType -eq 'taskparent') {
            Save-TaskParentWiConfig -Id $releaseId -Title $title | Out-Null
        } else {
            Save-ActiveReleaseConfig -Id $releaseId -Title $title | Out-Null
        }

        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ id = $releaseId; title = $title } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    } catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Could not fetch work item $releaseId`: $_" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    }
    return
}

# ── GET — return stored config (or preview a WI without saving) ────────────────
$previewId  = $Request.Query.preview
$configType = Get-ConfigType -QueryType $Request.Query.type -BodyType $null

if ($previewId) {
    try {
        $baseUrl = Get-AdoBaseUrl
        $wiUrl   = "$baseUrl/_apis/wit/workitems/$previewId`?fields=System.Id,System.Title"
        $wi      = Invoke-AdoApi -Url $wiUrl
        $title   = $wi.fields.'System.Title'
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ id = $previewId; title = $title } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    } catch {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Could not fetch work item $previewId`: $_" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
    }
    return
}

try {
    $config = if ($configType -eq 'taskparent') {
        Get-TaskParentWiConfig
    } else {
        Get-ActiveReleaseConfig
    }
    $bodyJson = if ($config) { $config | ConvertTo-Json } else { 'null' }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $bodyJson
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
} catch {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to read config: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
