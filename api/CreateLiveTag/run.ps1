using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $repoId   = $body.repoId
    $repoName = $body.repoName
    $version  = $body.version
    $notify   = [bool]$body.notify

    if (-not $repoId -or -not $version) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "repoId and version are required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $result = New-LiveTag -RepoId $repoId -RepoName $repoName -Version $version -Notify $notify

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($result | ConvertTo-Json -Depth 5)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "CreateLiveTag failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to create live tag: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
