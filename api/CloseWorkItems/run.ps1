using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $workItemIds = $body.workItemIds
    $type        = $body.type ?? 'Task'

    if (-not $workItemIds -or $workItemIds.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "No workItemIds provided" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $results = @()
    foreach ($id in $workItemIds) {
        $result = Close-AdoWorkItem -WorkItemId ([int]$id) -WorkItemType $type
        $results += $result
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($results | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "CloseWorkItems failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to close work items: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
