using namespace System.Net

param($Request, $TriggerMetadata)


# --- Validate request body ---
$body = $Request.Body

# --- Handle cutoff override request ---
if ($body.overrideRequest -eq $true) {
    Write-Host "Cutoff override request from $($body.submitterEmail) for $($body.targetMonth)"

    # Persist override request so the GA team can approve/reject it
    $overrideId = New-OverrideId
    $typeLabel = if ($body.typeLabel) { $body.typeLabel } else { $body.releaseType }
    $override = @{
        id             = $overrideId
        submitterEmail = $body.submitterEmail
        teamName       = $body.teamName
        releaseType    = $body.releaseType
        typeLabel      = $typeLabel
        targetMonth    = $body.targetMonth
        cutoffDate     = $body.cutoffDate
        reason         = $body.reason
        status         = 'pending'
        submittedAt    = (Get-Date).ToUniversalTime().ToString('o')
        decidedAt      = ''
        decidedBy      = ''
    }
    try {
        Save-OverrideRequest -Override $override | Out-Null
    } catch {
        Write-Error "Failed to save override request: $_"
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::InternalServerError
            Body       = (@{ message = "Failed to record override request" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # Build signed approve/reject URLs (deep links GA team will click in Teams)
    $portalBase = if ($body.portalBaseUrl) { $body.portalBaseUrl.TrimEnd('/') } elseif ($env:PORTAL_BASE_URL) { $env:PORTAL_BASE_URL.TrimEnd('/') } else { '' }
    $approveToken = Get-OverrideHmacToken -Id $overrideId -Decision 'approve'
    $rejectToken  = Get-OverrideHmacToken -Id $overrideId -Decision 'reject'
    $approveUrl = "$portalBase/api/DecideOverride?id=$overrideId&decision=approve&token=$approveToken"
    $rejectUrl  = "$portalBase/api/DecideOverride?id=$overrideId&decision=reject&token=$rejectToken"

    try {
        # Post to MS Teams channel via incoming webhook
        $teamsWebhookUrl = $env:TEAMS_CUTOFF_WEBHOOK_URL
        if ($teamsWebhookUrl) {
            $teamsCard = @{
                type        = "message"
                attachments = @(
                    @{
                        contentType = "application/vnd.microsoft.card.adaptive"
                        content     = @{
                            '$schema' = "http://adaptivecards.io/schemas/adaptive-card.json"
                            type      = "AdaptiveCard"
                            version   = "1.4"
                            body      = @(
                                @{
                                    type   = "TextBlock"
                                    text   = "⚠️ Cut-Off Override Request"
                                    weight = "Bolder"
                                    size   = "Large"
                                    color  = "Warning"
                                }
                                @{
                                    type  = "FactSet"
                                    facts = @(
                                        @{ title = "Team"; value = $body.teamName }
                                        @{ title = "Requested By"; value = $body.submitterEmail }
                                        @{ title = "Release Type"; value = $typeLabel }
                                        @{ title = "Target Month"; value = $body.targetMonth }
                                        @{ title = "Cut-off Date"; value = $body.cutoffDate }
                                        @{ title = "Override ID"; value = $overrideId }
                                    )
                                }
                                @{
                                    type      = "TextBlock"
                                    text      = "**Reason:**"
                                    wrap      = $true
                                    spacing   = "Medium"
                                }
                                @{
                                    type      = "TextBlock"
                                    text      = $body.reason
                                    wrap      = $true
                                    color     = "Accent"
                                }
                            )
                            actions = @(
                                @{
                                    type  = "Action.OpenUrl"
                                    title = "✅ Approve"
                                    url   = $approveUrl
                                    style = "positive"
                                }
                                @{
                                    type  = "Action.OpenUrl"
                                    title = "❌ Reject"
                                    url   = $rejectUrl
                                    style = "destructive"
                                }
                            )
                        }
                    }
                )
            }
            $null = Invoke-RestMethod -Uri $teamsWebhookUrl -Method Post -Body ($teamsCard | ConvertTo-Json -Depth 20) -ContentType 'application/json'
            Write-Host "Teams notification posted successfully (override $overrideId)"
        }
        else {
            Write-Host "Warning: TEAMS_CUTOFF_WEBHOOK_URL not configured"
        }
    }
    catch {
        Write-Host "Warning: Failed to post Teams notification: $_"
    }
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            message    = "Override request posted to GA Teams channel"
            overrideId = $overrideId
            status     = 'pending'
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$requiredFields = @('teamName', 'releaseType', 'submitterEmail', 'targetMonth', 'epics')
$missing = $requiredFields | Where-Object { -not $body.$_ }

if ($missing) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Missing required fields: $($missing -join ', ')" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Validate epics array
if (-not ($body.epics -is [System.Collections.IEnumerable]) -or $body.epics.Count -eq 0) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "At least one epic is required" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

foreach ($epic in $body.epics) {
    if (-not $epic.epicNumber) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Each epic must have an epicNumber" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    if (-not ($epic.apps -is [System.Collections.IEnumerable]) -or $epic.apps.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Epic #$($epic.epicNumber) must have at least one app" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
    foreach ($app in $epic.apps) {
        if (-not $app.repoName -or -not $app.sourceBranch) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = (@{ message = "Epic #$($epic.epicNumber): each app must have repoName and sourceBranch" } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }
    }
}

# Validate release type
$validReleaseTypes = @('feature', 'stability', 'hotfix', 'service-pack')
if ($body.releaseType -notin $validReleaseTypes) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "releaseType must be one of: $($validReleaseTypes -join ', ')" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# Service Pack is restricted to GA admins (matches the frontend ACL).
if ($body.releaseType -eq 'service-pack') {
    $gaAdmins = @(
        'ks@aptean.com',
        'krishna.s@aptean.com',
        'kkumar@aptean.com',
        'kapilkumar@aptean.com',
        'srs@aptean.com',
        'subhavarman.rs@aptean.com'
    )
    $submitterLower = ([string]$body.submitterEmail).ToLower()
    if ($submitterLower -notin $gaAdmins) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Forbidden
            Body       = (@{ message = "Service Pack releases can only be submitted by the GA team." } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
}

# Validate email format
if ($body.submitterEmail -notmatch '^[^@]+@[^@]+\.[^@]+$') {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Invalid email format" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Duplicate-epic guard ---
# Block submission if any of the epics in this request are already in another
# active (non-rejected, non-completed) request. The user can ask GA to reject
# or complete the prior one to free the epic.
try {
    $newEpicNumbers = @($body.epics | ForEach-Object { [string]$_.epicNumber })
    $existingRequests = Get-RequestsFromStorage

    $conflicts = @()
    foreach ($existing in $existingRequests) {
        $status = [string]$existing.status
        if ($status -in @('rejected', 'completed')) { continue }

        $existingEpics = @()
        if ($existing.epics) {
            try {
                if ($existing.epics -is [string]) {
                    $existingEpics = @($existing.epics | ConvertFrom-Json)
                } else {
                    $existingEpics = @($existing.epics)
                }
            } catch { $existingEpics = @() }
        }

        foreach ($e in $existingEpics) {
            if (-not $e.epicNumber) { continue }
            if ([string]$e.epicNumber -in $newEpicNumbers) {
                $conflicts += @{
                    epicNumber        = [string]$e.epicNumber
                    existingRequestId = [string]$existing.id
                    existingStatus    = $status
                    submitter         = [string]$existing.submitterEmail
                }
            }
        }
    }

    if ($conflicts.Count -gt 0) {
        $epicList = ($conflicts | ForEach-Object { "#$($_.epicNumber) (in $($_.existingRequestId), $($_.existingStatus))" }) -join '; '
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::Conflict
            Body       = (@{
                code      = 'epic_already_submitted'
                message   = "A request was already raised for: $epicList. You can't submit a new request for the same epic — please reach out to the GA team to enable edit options or to reject/complete the existing one."
                conflicts = $conflicts
            } | ConvertTo-Json -Depth 5)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }
}
catch {
    Write-Warning "Duplicate epic check failed; proceeding with submission. Error: $($_.Exception.Message)"
}

# --- Build request record ---
$requestId = New-RequestId

# --- Upload attachments to blob storage ---
$attachmentsMeta = @()
if ($body.attachments -and $body.attachments.Count -gt 0) {
    $allowedTypes = @(
        'image/jpeg','image/jpg','image/png','image/gif','image/bmp','image/webp',
        'application/vnd.ms-excel',
        'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
        'application/pdf','application/msword',
        'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
        'text/plain','text/csv'
    )
    $maxFileSize = 10 * 1024 * 1024  # 10 MB

    foreach ($att in $body.attachments) {
        if (-not $att.name -or -not $att.dataBase64) { continue }
        if ($att.type -notin $allowedTypes) {
            Write-Warning "Skipping attachment '$($att.name)': unsupported type '$($att.type)'"
            continue
        }
        $decodedSize = [Math]::Ceiling(($att.dataBase64.Length * 3) / 4)
        if ($decodedSize -gt $maxFileSize) {
            Write-Warning "Skipping attachment '$($att.name)': exceeds 10 MB"
            continue
        }
        # Sanitize filename — strip path separators and null bytes
        $safeName = [System.IO.Path]::GetFileName($att.name) -replace '[^\w.\-]', '_'
        try {
            $blobUrl = Save-AttachmentToBlob -RequestId $requestId -FileName $safeName `
                -ContentType $att.type -DataBase64 $att.dataBase64
            $attachmentsMeta += @{ name = $safeName; type = $att.type; size = $att.size; url = $blobUrl }
            Write-Host "Uploaded attachment '$safeName' for request $requestId"
        }
        catch {
            Write-Warning "Failed to upload attachment '$($att.name)': $_"
        }
    }
}

# --- Upload hotfix approval mail to blob (separate from general attachments) ---
$hotfixApprovalMailUrl = ''
if ($body.releaseType -eq 'hotfix' -and $body.approvalMailAttachment -and $body.approvalMailAttachment.dataBase64) {
    $att = $body.approvalMailAttachment
    $safeName = [System.IO.Path]::GetFileName([string]$att.name) -replace '[^\w.\-]', '_'
    if (-not $safeName) { $safeName = 'approval_mail' }
    try {
        $hotfixApprovalMailUrl = Save-AttachmentToBlob -RequestId $requestId -FileName "approval_mail_$safeName" `
            -ContentType ([string]($att.type ?? 'application/octet-stream')) -DataBase64 ([string]$att.dataBase64)
        Write-Host "Uploaded hotfix approval mail for $requestId"
    } catch {
        Write-Warning "Failed to upload hotfix approval mail: $_"
    }
}

$record = @{
    requestId          = $requestId
    teamName           = $body.teamName
    releaseType        = $body.releaseType
    submitterEmail     = $body.submitterEmail
    targetMonth        = $body.targetMonth
    epics              = ($body.epics | ConvertTo-Json -Depth 5 -Compress)
    notes              = $body.notes ?? ''
    attachments        = if ($attachmentsMeta.Count -gt 0) { ($attachmentsMeta | ConvertTo-Json -Depth 3 -Compress) } else { '' }
    submittedAt        = (Get-Date).ToUniversalTime().ToString('o')
    status             = 'pending'
    cutoffOverrideId   = $body.cutoffOverrideId ?? ''
    hotfixApprovedBy   = if ($body.releaseType -eq 'hotfix') { [string]($body.hotfixApprovedBy ?? '') } else { '' }
    hotfixApprovalMailUrl = $hotfixApprovalMailUrl
}

# --- Save to Azure Table Storage ---
try {
    Save-RequestToStorage -Request $record
    Write-Host "GA request $requestId saved successfully"
}
catch {
    Write-Error "Failed to save request: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Failed to save request. Please try again." } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

# --- Return success ---
Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        message   = 'GA release request submitted successfully'
        requestId = $requestId
        status    = 'pending'
    } | ConvertTo-Json)
    Headers    = @{ 'Content-Type' = 'application/json' }
})
