using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

try {
    $repos = Get-AdoRepositories

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($repos | ConvertTo-Json -Depth 3 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Failed to retrieve repositories: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to retrieve repositories" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
