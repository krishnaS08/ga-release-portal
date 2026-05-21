using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $epicId = $Request.Query.epicId
    if (-not $epicId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "epicId is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    Write-Host "GetEpicAppsFromPRs: epicId=$epicId"
    $result = Get-EpicAppsFromPRs -EpicId $epicId

    Write-Host "GetEpicAppsFromPRs: returning $(@($result.apps).Count) app(s) from $($result.stats.completedPRCount) completed PR(s) (of $($result.stats.prCount) total) under $($result.stats.descendantCount) descendant(s)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($result | ConvertTo-Json -Depth 6)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "GetEpicAppsFromPRs failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to derive apps from PRs: $($_.Exception.Message)" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
