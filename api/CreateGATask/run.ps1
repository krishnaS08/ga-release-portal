using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

try {
    $body        = $Request.Body
    $requestId   = [string]$body.requestId
    $apps        = $body.apps          # array of { epicId, repoId, repoName, sourceBranch, targetMonth, taskPreview }
    $releaseWiId = [string]($body.releaseWiId ?? '')

    if (-not $requestId -or -not $apps) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ error = 'requestId and apps are required' } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $taskResults = @()

    foreach ($app in $apps) {
        $epicId       = [string]$app.epicId
        $repoId       = [string]$app.repoId
        $repoName     = [string]$app.repoName
        $sourceBranch = [string]$app.sourceBranch
        $targetMonth  = [string]($app.targetMonth ?? '')
        $tp           = $app.taskPreview

        if (-not $tp) {
            $taskResults += @{
                repoId       = $repoId; sourceBranch = $sourceBranch; epicId = $epicId
                success      = $false;  error = 'taskPreview is required'; consolidated = $false
            }
            continue
        }

        $appName        = [string]($tp.appName        ?? $repoName)
        $teamName       = [string]($tp.teamName       ?? '')
        $version        = [string]($tp.version        ?? '')
        $releaseType    = [string]($tp.releaseType    ?? '')
        $assignedTo     = [string]($tp.assignedTo     ?? '')
        $assignedToName = [string]($tp.assignedToName ?? '')
        $taskTitle      = [string]($tp.title          ?? (Get-GATaskTitle -AppShortName $appName -ReleaseType $releaseType -TargetMonth $targetMonth))

        if (-not $teamName -or -not $appName -or -not $version -or -not $releaseType) {
            $taskResults += @{
                repoId       = $repoId; sourceBranch = $sourceBranch; epicId = $epicId
                success      = $false
                error        = "Missing required task fields: teamName, appName, version, releaseType"
                consolidated = $false
            }
            continue
        }

        # Build month tags (MAY; GA2026)
        $taskTags = ''
        if ($targetMonth) {
            $parts = $targetMonth.Trim() -split '[\s\-]+'
            if ($parts.Count -ge 2 -and $parts[0] -and $parts[1]) {
                $yearPart = $parts[1]
                if ($yearPart -match '^\d{4}$') { $yearPart = "GA$yearPart" }
                $taskTags = "$($parts[0].ToUpper()); $yearPart"
            }
        }

        # --- Check for an existing global GA task for this app (cross-epic consolidation) ---
        $globalExisting = Find-GlobalGATask -AppName $appName -TargetMonth $targetMonth

        if ($globalExisting) {
            Write-Host "Consolidating Task #$($globalExisting.taskId) for app '$appName' — merging team '$teamName'"
            $consolidateResult = Update-GATaskForConsolidation `
                -TaskId       $globalExisting.taskId `
                -NewTeamName  $teamName `
                -NewRequestId $requestId `
                -NewEpicId    $epicId `
                -NewVersion   $version

            if ($consolidateResult.success) {
                $taskResults += @{
                    repoId          = $repoId
                    sourceBranch    = $sourceBranch
                    epicId          = $epicId
                    success         = $true
                    taskId          = $globalExisting.taskId
                    taskUrl         = $consolidateResult.taskUrl ?? ($globalExisting.taskUrl ?? '')
                    consolidated    = $true
                    mergedTeamName  = $consolidateResult.mergedTeamName
                    previousTeam    = $globalExisting.teamName
                    versionUpdated  = $consolidateResult.versionUpdated
                    previousVersion = $consolidateResult.previousVersion
                }
            }
            else {
                $taskResults += @{
                    repoId       = $repoId; sourceBranch = $sourceBranch; epicId = $epicId
                    success      = $false
                    error        = "Consolidation failed: $($consolidateResult.error)"
                    consolidated = $true
                }
            }
        }
        else {
            # Create new task
            $createResult = New-GATask `
                -EpicId          $epicId `
                -Title           $taskTitle `
                -AppShortName    $appName `
                -TeamName        $teamName `
                -ReleaseType     $releaseType `
                -AppName         $appName `
                -Version         $version `
                -AssignedTo      $assignedTo `
                -AssignedToName  $assignedToName `
                -Tags            $taskTags `
                -ReleaseWiId     $releaseWiId `
                -AreaPath        ($env:ADO_CLOSURE_AREA_PATH ?? '')

            if ($createResult.success) {
                Write-Host "Created GA Task #$($createResult.taskId) for '$appName' (request $requestId)"
                $taskResults += @{
                    repoId       = $repoId
                    sourceBranch = $sourceBranch
                    epicId       = $epicId
                    success      = $true
                    taskId       = $createResult.taskId
                    taskUrl      = $createResult.taskUrl
                    consolidated = $false
                }
            }
            else {
                $taskResults += @{
                    repoId       = $repoId; sourceBranch = $sourceBranch; epicId = $epicId
                    success      = $false
                    error        = $createResult.error
                    consolidated = $false
                }
            }
        }
    }

    $anyFailed = @($taskResults | Where-Object { -not $_.success })

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            success   = ($anyFailed.Count -eq 0)
            requestId = $requestId
            tasks     = $taskResults
        } | ConvertTo-Json -Depth 10)
    })
}
catch {
    Write-Error "CreateGATask failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
