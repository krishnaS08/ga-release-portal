using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $repoId   = $Request.Query.repoId
    $repoName = $Request.Query.repoName

    if (-not $repoId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "repoId is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $result = Get-LiveStatusInfo -RepoId $repoId -RepoName $repoName

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($result | ConvertTo-Json -Depth 5)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "CheckLiveStatus failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to check live status: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
