using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $epicIds        = $body.epicIds
    $areaPathFilter = $body.areaPathFilter   # optional override; defaults to 'BC GA' or $env:ADO_CLOSURE_AREA_PATH

    # Normalize: PS sometimes deserializes an empty JSON array as $null
    if ($null -eq $epicIds) { $epicIds = @() }

    Write-Host "GetClosureTasks: epicIds=[$($epicIds -join ',')] areaFilter='$areaPathFilter'"

    # If no Epic IDs are passed, the helper auto-discovers every Epic where
    # Custom.FactoryStatus = '70 GA Validations' — that's the new default UX.
    $tasks = Get-ClosureTasks -EpicIds $epicIds -AreaPathFilter $areaPathFilter

    Write-Host "GetClosureTasks: returning $(@($tasks).Count) tasks"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@($tasks) | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    $errMsg = $_.Exception.Message
    $errAt  = $_.InvocationInfo.PositionMessage
    Write-Error "GetClosureTasks failed: $errMsg`n$errAt"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{
            message = "Failed to load closure tasks: $errMsg"
            location = $errAt
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
