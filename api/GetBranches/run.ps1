using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

$repoId = $Request.Query.repoId

if (-not $repoId) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Missing required query parameter: repoId" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

try {
    $branches = Get-AdoBranches -RepoId $repoId

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($branches | ConvertTo-Json -Depth 3 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Failed to retrieve branches: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to retrieve branches" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
