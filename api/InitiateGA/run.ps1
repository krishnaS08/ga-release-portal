using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body

    $requestId             = $body.requestId
    $targetBranch          = $body.targetBranch ?? 'main'
    $appOverrides          = $body.appOverrides   # array of { repoId, repoName, sourceBranch, targetBranch, newVersion, epicId }
    $initiatorEmail        = $body.initiatorEmail  # email of release team member who clicked Initiate GA
    $initiatorName         = [string]($body.initiatorName ?? '')  # display name of the same person
    $skipTranslationCheck  = [bool]$body.skipTranslationCheck
    $releaseWiId           = [string]($body.releaseWiId ?? '')

    if ($skipTranslationCheck) {
        Write-Host "[AUDIT] Translation validation was SKIPPED for request $requestId by $initiatorEmail"
    }

    if (-not $requestId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @{ error = 'requestId is required' } | ConvertTo-Json
        })
        return
    }

    # Load the request from storage
    $request = Get-RequestById -RequestId $requestId
    if (-not $request) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::NotFound
            Body       = @{ error = "Request $requestId not found" } | ConvertTo-Json
        })
        return
    }

    $teamName    = $request.teamName
    $releaseType = $request.releaseType
    $targetMonth = $request.targetMonth
    $epics       = $request.epics

    if (-not $epics -or $epics.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @{ error = 'Request has no epics' } | ConvertTo-Json
        })
        return
    }

    # Update status to in-progress
    Update-RequestStatus -RequestId $requestId -NewStatus 'in-progress'

    $allResults = @()
    $hasErrors = $false

    foreach ($epic in $epics) {
        $epicId    = $epic.epicNumber
        $epicTitle = $epic.epicTitle
        $apps      = $epic.apps

        if (-not $apps -or $apps.Count -eq 0) { continue }

        foreach ($app in $apps) {
            $repoId       = $app.repoId
            $repoName     = $app.repoName
            $sourceBranch = $app.sourceBranch

            # Look up per-app overrides from frontend (custom target branch, version, appSourceCop, taskPreview, existingTaskId)
            $appTargetBranch  = $targetBranch
            $overrideVersion  = $null
            $overrideAppSourceCop = $null
            $taskPreview      = $null
            $existingTaskId   = ''
            if ($appOverrides) {
                $override = $appOverrides | Where-Object {
                    $_.repoId -eq $repoId -and $_.sourceBranch -eq $sourceBranch
                } | Select-Object -First 1
                if ($override) {
                    if ($override.targetBranch)        { $appTargetBranch    = $override.targetBranch }
                    if ($override.newVersion)          { $overrideVersion    = $override.newVersion }
                    if ($override.appSourceCopVersion) { $overrideAppSourceCop = $override.appSourceCopVersion }
                    if ($override.existingTaskId)      { $existingTaskId     = [string]$override.existingTaskId }
                    if ($override.taskPreview) {
                        $taskPreview = @{}
                        $override.taskPreview.PSObject.Properties | ForEach-Object {
                            $taskPreview[$_.Name] = $_.Value
                        }
                    }
                }
            }

            Write-Host "Processing: $repoName ($sourceBranch) → $appTargetBranch for Epic #$epicId"

            $result = Invoke-GAInitialProcess `
                -RepoId $repoId `
                -RepoName $repoName `
                -SourceBranch $sourceBranch `
                -TargetBranch $appTargetBranch `
                -ReleaseType $releaseType `
                -EpicId $epicId `
                -TeamName $teamName `
                -OverrideVersion $overrideVersion `
                -OverrideAppSourceCopVersion $overrideAppSourceCop `
                -TaskPreview $taskPreview `
                -InitiatorEmail $initiatorEmail `
                -InitiatorName  $initiatorName `
                -TargetMonth $targetMonth `
                -ExistingTaskId $existingTaskId `
                -ReleaseWiId $releaseWiId

            $allResults += @{
                repoName     = $repoName
                epicId       = $epicId
                success      = $result.success
                log          = $result.log
                appShortName = $result.appShortName
                oldVersion   = $result.oldVersion
                newVersion   = $result.newVersion
                commitMsg    = $result.commitMessage
                prResult     = $result.prResult
                taskResult   = $result.taskResult
                error        = $result.error
            }

            if (-not $result.success) {
                $hasErrors = $true
            }
        }
    }

    # Update status based on outcome
    if (-not $hasErrors) {
        Update-RequestStatus -RequestId $requestId -NewStatus 'completed'
    }

    # Send notification email if webhook is configured
    if ($env:POWER_AUTOMATE_WEBHOOK_URL) {
        $completionSubject = "GA-Initial Process $(if ($hasErrors) { 'Completed with Errors' } else { 'Completed Successfully' }) — $requestId"
        $completionBody = "<h2>GA-Initial Process Results</h2><p>Request: <strong>$requestId</strong><br>Team: <strong>$teamName</strong><br>Release: <strong>$releaseType</strong></p>"
        $completionBody += "<table border='1' cellpadding='4' cellspacing='0'><tr><th>App</th><th>Repo</th><th>Version Change</th><th>Status</th></tr>"
        foreach ($r in $allResults) {
            $statusColor = if ($r.success) { 'green' } else { 'red' }
            $statusText = if ($r.success) { 'OK' } else { 'Failed' }
            $completionBody += "<tr><td>$($r.appShortName)</td><td>$($r.repoName)</td><td>$($r.oldVersion) → $($r.newVersion)</td><td style='color:$statusColor;font-weight:bold;'>$statusText</td></tr>"
        }
        $completionBody += "</table>"

        Send-NotificationEmail -To ($request.submitterEmail) -Subject $completionSubject -Body $completionBody
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            success   = (-not $hasErrors)
            requestId = $requestId
            results   = $allResults
        } | ConvertTo-Json -Depth 10)
    })
}
catch {
    Write-Error "InitiateGA failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = $_.Exception.Message } | ConvertTo-Json
    })
}
