using namespace System.Net

param($Request, $TriggerMetadata)


$body = $Request.Body

if (-not $body.requestId -or -not $body.action) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Missing requestId or action" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$validActions = @('approved', 'rejected')
if ($body.action -notin $validActions) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "action must be one of: $($validActions -join ', ')" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

try {
    # Update the request status
    $updated = Update-RequestStatus -RequestId $body.requestId -NewStatus $body.action

    if (-not $updated) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = (@{ message = "Request not found: $($body.requestId)" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $responseBody = @{
        message   = "Request $($body.requestId) has been $($body.action)"
        requestId = $body.requestId
        status    = $body.action
    }

    # If approved, trigger GA process
    if ($body.action -eq 'approved') {
        Write-Host "GA process initiated for request: $($body.requestId)"
        $null = Update-RequestStatus -RequestId $body.requestId -NewStatus 'in-progress'
        $responseBody.status = 'in-progress'
        $responseBody.message = "Request $($body.requestId) approved — GA process initiated"
    }

    # --- Send email notification to submitter ---
    $requestData = Get-RequestById -RequestId $body.requestId
    if ($requestData -and $requestData.submitterEmail) {
        $actionLabel = if ($body.action -eq 'approved') { 'Approved' } else { 'Rejected' }
        $subject = "GA Release Request $($body.requestId) — $actionLabel"

        $epics = @($requestData.epics)
        $emailBody = Build-ApprovalEmailBody `
            -RequestId $body.requestId `
            -TeamName ($requestData.teamName ?? '') `
            -ReleaseType ($requestData.releaseType ?? '') `
            -Action $body.action `
            -SubmitterEmail $requestData.submitterEmail `
            -Epics $epics

        $emailSent = Send-NotificationEmail `
            -To $requestData.submitterEmail `
            -Subject $subject `
            -HtmlBody $emailBody `
            -From ($body.approverEmail ?? '')

        $responseBody.emailSent = $emailSent
        if (-not $emailSent) {
            Write-Warning "Email notification could not be sent to $($requestData.submitterEmail)"
        }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($responseBody | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "Failed to process action: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to process action" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
