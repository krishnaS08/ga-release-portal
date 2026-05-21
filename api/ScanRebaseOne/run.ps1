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

    $row = Get-RebaseScanSingle -RepoId $repoId -RepoName $repoName

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            row       = $row     # null if repo lacks main/develop refs
            repoId    = $repoId
            repoName  = $repoName
            skipped   = ($null -eq $row)
        } | ConvertTo-Json -Depth 5)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "ScanRebaseOne failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
