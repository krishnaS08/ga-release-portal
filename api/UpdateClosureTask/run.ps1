using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $taskId = $body.taskId
    $f      = $body.fields   # { state, title, assignedTo, appName, teamName, version, releaseType, tags[] }

    if (-not $taskId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "taskId is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if (-not $f) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "fields object is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # ---- Server-side gate: closing a task requires App / Team / Release Type / Tags ----
    if ($f.state -eq 'Closed') {
        $missing = @()
        if (-not $f.appName)     { $missing += 'App' }
        if (-not $f.teamName)    { $missing += 'Team' }
        if (-not $f.releaseType) { $missing += 'Release Type' }
        if (-not $f.tags -or @($f.tags).Count -eq 0) { $missing += 'Tags' }

        if ($missing.Count -gt 0) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = (@{
                    message  = "Cannot close task — required field(s) missing: $($missing -join ', ')"
                    missing  = $missing
                } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }

    # ---- Build PATCH document for ADO Work Item ----
    $patch = @()

    if ($null -ne $f.title -and $f.title -ne '') {
        $patch += @{ op = 'add'; path = '/fields/System.Title';        value = $f.title }
    }
    if ($null -ne $f.state -and $f.state -ne '') {
        $patch += @{ op = 'add'; path = '/fields/System.State';        value = $f.state }
    }
    if ($null -ne $f.assignedTo -and $f.assignedTo -ne '') {
        $patch += @{ op = 'add'; path = '/fields/System.AssignedTo';   value = $f.assignedTo }
    }
    if ($null -ne $f.appName) {
        $patch += @{ op = 'add'; path = '/fields/Custom.AppName';      value = [string]$f.appName }
    }
    if ($null -ne $f.teamName) {
        $patch += @{ op = 'add'; path = '/fields/Custom.TeamName';     value = [string]$f.teamName }
    }
    if ($null -ne $f.version) {
        $patch += @{ op = 'add'; path = '/fields/Custom.Version';      value = [string]$f.version }
    }
    if ($null -ne $f.releaseType) {
        $patch += @{ op = 'add'; path = '/fields/Custom.ReleaseType';  value = [string]$f.releaseType }
    }
    if ($null -ne $f.tags) {
        # ADO expects tags as a single semicolon-separated string
        $tagsArr = @($f.tags) | Where-Object { $_ -and "$_".Trim() -ne '' } | ForEach-Object { "$_".Trim() }
        $patch += @{ op = 'add'; path = '/fields/System.Tags';         value = ($tagsArr -join '; ') }
    }
    # Audit trail
    $patch += @{ op = 'add'; path = '/fields/System.History'; value = "Edited via GA Release Portal closure subtab." }

    if ($patch.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "No fields provided to update" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url     = "$org/$project/_apis/wit/workitems/${taskId}?api-version=7.1"
    $headers = Get-AdoHeaders
    $headers['Content-Type'] = 'application/json-patch+json'

    Write-Host "UpdateClosureTask: PATCH $url with $($patch.Count) ops"

    $resp = Invoke-RestMethod -Method PATCH -Uri $url -Headers $headers `
                              -Body ($patch | ConvertTo-Json -Depth 5) `
                              -ContentType 'application/json-patch+json' `
                              -ErrorAction Stop

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            id      = $resp.id
            state   = $resp.fields.'System.State'
            title   = $resp.fields.'System.Title'
            success = $true
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    $errMsg = $_.Exception.Message
    $errBody = $null
    try { $errBody = $_.ErrorDetails.Message } catch {}
    Write-Error "UpdateClosureTask failed: $errMsg $errBody"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{
            message = "Update failed: $errMsg"
            detail  = $errBody
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
