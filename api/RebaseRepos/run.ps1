using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $repos = $body.repos

    if (-not $repos -or $repos.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "No repos provided" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $results = @()
    foreach ($repo in $repos) {
        $result = Invoke-RebaseRepo -RepoId $repo.id -RepoName $repo.name
        $results += $result
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($results | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "RebaseRepos failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Rebase operation failed: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
