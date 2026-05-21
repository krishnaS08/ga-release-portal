using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body        = $Request.Body
    $requestId   = $body.requestId
    $updates     = $body.updates       # hashtable of field updates
    $editorEmail = ($body.editorEmail ?? '').ToString().ToLower()

    if (-not $requestId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "requestId is required" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if (-not $updates) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "updates object is required" } | ConvertTo-Json)
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

    # --- Load existing record ---
    $existing = Get-RequestById -RequestId $requestId
    if (-not $existing) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = (@{ message = "Request $requestId not found" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # --- Auth gate: only the original submitter can self-edit ---
    $submitterLower = ([string]$existing.submitterEmail).ToLower()
    if ($editorEmail -ne $submitterLower) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Forbidden
            Body       = (@{ message = "Only the original submitter ($submitterLower) can edit this request." } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # --- Status gate: only 'pending' requests are self-editable ---
    if ($existing.status -ne 'pending') {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Conflict
            Body       = (@{
                message = "Request is '$($existing.status)' — only pending requests can be self-edited. Please ask the GA team."
                status  = $existing.status
            } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # --- Apply updates (only allowed fields) ---
    $allowed = @('teamName','releaseType','targetMonth','ccEmails','notes','epics','hotfixApprovedBy')
    $changed = @()

    # Build a fresh hashtable to save (Save-RequestToStorage does InsertOrReplace)
    $record = @{}
    foreach ($k in $existing.Keys) { $record[$k] = $existing[$k] }
    $record['requestId'] = $existing.id   # preserve RowKey

    foreach ($prop in $updates.PSObject.Properties) {
        $key = $prop.Name
        if ($allowed -notcontains $key) { continue }
        $newVal = $prop.Value
        # epics is stored as JSON string → re-serialize
        if ($key -eq 'epics' -and $newVal -is [System.Collections.IEnumerable]) {
            $record['epics'] = ($newVal | ConvertTo-Json -Depth 5 -Compress)
        } elseif ($key -eq 'ccEmails' -and $newVal -is [System.Collections.IEnumerable]) {
            $record['ccEmails'] = ($newVal -join ',')
        } else {
            $record[$key] = [string]$newVal
        }
        $changed += $key
    }

    if ($changed.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Body       = (@{ message = "No editable fields changed."; requestId = $requestId } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $record['lastEditedAt'] = (Get-Date).ToUniversalTime().ToString('o')
    $record['lastEditedBy'] = $editorEmail

    Save-RequestToStorage -Request $record | Out-Null

    # --- Notify the GA admins ---
    # Reuses GA_REVIEWER_MAP (comma-separated) from settings; falls back to the trio.
    $reviewers = @()
    if ($env:GA_REVIEWER_MAP) {
        $reviewers = $env:GA_REVIEWER_MAP.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    }
    if ($reviewers.Count -eq 0) {
        $reviewers = @('kapilkumar@aptean.com', 'subhavarman.rs@aptean.com', 'krishna.s@aptean.com')
    }

    $teamName    = [string]$record.teamName
    $releaseType = [string]$record.releaseType
    $targetMonth = [string]$record.targetMonth
    $changedList = ($changed | ForEach-Object { "<li><code>$_</code></li>" }) -join ''

    $subject = "GA Release request $requestId edited by submitter"
    $html = @"
<!DOCTYPE html>
<html><body style="font-family:'Segoe UI',sans-serif;color:#1e293b;max-width:680px;margin:0 auto;padding:20px;">
  <div style="background:linear-gradient(135deg,#0078d4 0%,#005a9e 100%);padding:18px 24px;border-radius:8px 8px 0 0;color:#fff;">
    <h1 style="margin:0;font-size:20px;">✏️ Request edited by submitter</h1>
  </div>
  <div style="border:1px solid #e5e7eb;border-top:none;border-radius:0 0 8px 8px;padding:20px 24px;">
    <p>The submitter <strong>$editorEmail</strong> has edited their pending request <strong>$requestId</strong>.</p>
    <table style="width:100%;border-collapse:collapse;font-size:13px;margin-top:12px;">
      <tr><td style="padding:6px 8px;color:#64748b;">Team</td><td style="padding:6px 8px;">$teamName</td></tr>
      <tr><td style="padding:6px 8px;color:#64748b;">Release Type</td><td style="padding:6px 8px;">$releaseType</td></tr>
      <tr><td style="padding:6px 8px;color:#64748b;">Target Month</td><td style="padding:6px 8px;">$targetMonth</td></tr>
    </table>
    <p style="margin-top:14px;"><strong>Fields changed:</strong></p>
    <ul style="margin:4px 0 0 18px;">$changedList</ul>
    <p style="margin-top:18px;color:#64748b;font-size:12px;">Open the GA Release Portal Dashboard to review and approve.</p>
  </div>
</body></html>
"@

    $sentTo = @()
    foreach ($r in $reviewers) {
        $ok = Send-NotificationEmail -To $r -Subject $subject -HtmlBody $html -From 'ga-release-portal@aptean.com'
        if ($ok) { $sentTo += $r }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            message     = "Request $requestId updated."
            requestId   = $requestId
            changed     = $changed
            notifiedGA  = $sentTo
        } | ConvertTo-Json -Depth 5)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "EditRequest failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Edit failed: $($_.Exception.Message)" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
