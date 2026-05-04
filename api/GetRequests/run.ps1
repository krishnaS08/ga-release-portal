using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

$status = $Request.Query.status
$team = $Request.Query.team

try {
    $requests = Get-RequestsFromStorage -Status $status -Team $team

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($requests | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Failed to retrieve requests: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to retrieve requests" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
