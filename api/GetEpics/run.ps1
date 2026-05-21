using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

$teamName  = $Request.Query.teamName
$releaseId = $Request.Query.releaseId

try {
    if ($releaseId) {
        $epics = Get-EpicsFromRelease -ReleaseId $releaseId
    } else {
        $epics = Get-AdoGAEpics -TeamName $teamName
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($epics | ConvertTo-Json -Depth 3 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Failed to retrieve epics: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to retrieve epics" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
