using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $days = [int]($Request.Query.days ?? 30)
    $results = Get-RebaseScanResults -DaysFilter $days

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($results | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "ScanRebase failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to scan repositories: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
