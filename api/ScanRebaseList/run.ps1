using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $repos = Get-RebaseEligibleRepos
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($repos | ConvertTo-Json -Depth 3 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "ScanRebaseList failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
