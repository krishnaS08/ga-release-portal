using namespace System.Net

param($Request, $TriggerMetadata)


# Action semantics:
#   action='cancel'  → permitted on PENDING requests; submitter OR admin
#   action='delete'  → permitted on COMPLETED requests; admin only
# Both perform a hard delete from GAReleaseRequests storage.

# Hard-coded admin list (matches frontend GA_ADMINS in app.js)
$admins = @(
    'ks@aptean.com',
    'krishna.s@aptean.com',
    'kkumar@aptean.com',
    'kapilkumar@aptean.com',
    'srs@aptean.com',
    'subhavarman.rs@aptean.com'
) | ForEach-Object { $_.ToLower() }

try {
    $body        = $Request.Body
    $requestId   = $body.requestId
    $action      = ($body.action ?? '').ToString().ToLower()
    $editorEmail = ($body.editorEmail ?? '').ToString().ToLower()

    if (-not $requestId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "requestId is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if ($action -notin @('cancel', 'delete')) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "action must be 'cancel' or 'delete'" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if (-not $editorEmail) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "editorEmail is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $existing = Get-RequestById -RequestId $requestId
    if (-not $existing) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = (@{ message = "Request $requestId not found" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $isAdmin     = $admins -contains $editorEmail
    $isSubmitter = ($existing.submitterEmail -and $existing.submitterEmail.ToLower() -eq $editorEmail)
    $status      = [string]$existing.status

    # Status + auth gates per action
    if ($action -eq 'cancel') {
        if ($status -ne 'pending') {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Conflict
                Body       = (@{ message = "Only pending requests can be cancelled. Current status: $status" } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
        if (-not ($isAdmin -or $isSubmitter)) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Forbidden
                Body       = (@{ message = "Only the submitter or a GA admin can cancel this request." } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }
    elseif ($action -eq 'delete') {
        # Admins can delete any request, regardless of status. The status is
        # captured into the audit log so the operator can tell what was wiped.
        if (-not $isAdmin) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::Forbidden
                Body       = (@{ message = "Only a GA admin can delete requests." } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }

    $ok = Remove-RequestFromStorage -RequestId $requestId
    if (-not $ok) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = (@{ message = "Failed to delete request." } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    Write-Host "[AUDIT] $action of request $requestId by $editorEmail (was $status)"

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            message    = "Request $requestId $($action)led."
            requestId  = $requestId
            action     = $action
            wasStatus  = $status
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "DeleteRequest failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed: $($_.Exception.Message)" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
