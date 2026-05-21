using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $requestId = $body.requestId

    if (-not $requestId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = @{ error = 'requestId is required' } | ConvertTo-Json
        })
        return
    }

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
    $epics       = $request.epics

    # Fetch task parent WI (GA-Initial tasks are added as children of this WI)
    $taskParentWi   = $null
    try { $taskParentWi = Get-TaskParentWiConfig } catch { }
    $releaseWiId    = if ($taskParentWi) { [string]$taskParentWi.id    } else { '' }
    $releaseWiTitle = if ($taskParentWi) { [string]$taskParentWi.title } else { '' }

    $epicPreviews = @()

    foreach ($epic in $epics) {
        $epicId    = $epic.epicNumber
        $epicTitle = $epic.epicTitle
        $apps      = $epic.apps

        # Check for existing child tasks under this epic
        $existingTasks = @()
        try {
            $baseUrl = Get-AdoBaseUrl
            $wiql = "SELECT [System.Id],[System.Title],[System.State] FROM WorkItemLinks WHERE ([Source].[System.Id] = $epicId) AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward') AND ([Target].[System.WorkItemType] = 'Task') MODE (MustContain)"
            $url = "$baseUrl/_apis/wit/wiql"
            $wiqlResult = Invoke-AdoApi -Method 'POST' -Url $url -Body @{ query = $wiql }

            $childIds = ($wiqlResult.workItemRelations | Where-Object { $_.target -and $_.target.id }) | ForEach-Object { $_.target.id }
            if ($childIds -and $childIds.Count -gt 0) {
                $idsParam = ($childIds | Select-Object -First 50) -join ','
                $detailUrl = "$baseUrl/_apis/wit/workitems?ids=$idsParam&fields=System.Id,System.Title,System.State"
                $details = Invoke-AdoApi -Url $detailUrl
                $existingTasks = $details.value | ForEach-Object {
                    @{
                        id    = $_.id
                        title = $_.fields.'System.Title'
                        state = $_.fields.'System.State'
                    }
                }
            }
        }
        catch {
            Write-Warning "Could not fetch tasks for Epic #$epicId : $($_.Exception.Message)"
        }

        $appPreviews = @()
        foreach ($app in $apps) {
            $repoId       = $app.repoId
            $repoName     = $app.repoName
            $sourceBranch = $app.sourceBranch

            # Read app.json from MAIN branch (current version = main branch version)
            $appInfo = Get-AppInfoFromRepo -RepoId $repoId -Branch 'main'
            $currentVersion = $null
            $newVersion     = $null
            $appShortName   = ''
            $appName        = ''
            $appJsonError   = $null

            if ($appInfo.error) {
                # Fallback: try source branch if main doesn't have app.json
                $appInfo = Get-AppInfoFromRepo -RepoId $repoId -Branch $sourceBranch
                if ($appInfo.error) {
                    $appJsonError = $appInfo.error
                }
            }

            if (-not $appJsonError) {
                $currentVersion = $appInfo.version
                $appShortName   = $appInfo.appShortName
                $appName        = $appInfo.appName
                # Hotfix doesn't bump the app.json version — only appsourcecop.json moves.
                if ($releaseType -eq 'hotfix') {
                    $newVersion = $currentVersion
                } else {
                    $newVersion = New-VersionBump -CurrentVersion $currentVersion -ReleaseType $releaseType -TargetMonth ($request.targetMonth ?? '')
                }
            }

            # Get AppSourceCop version from latest stable tag on main branch
            $appSourceCopVersion = $null
            if (-not $appJsonError) {
                $stableVersion = Get-StableTagVersion -RepoId $repoId -Branch 'main'
                if ($stableVersion) {
                    $appSourceCopVersion = $stableVersion
                }
                else {
                    # Fallback: read from appsourcecop.json in main
                    if ($appInfo.appJsonPath) {
                        $appJsonDir = Split-Path $appInfo.appJsonPath -Parent
                        $ascPath = if ($appJsonDir) { "$appJsonDir/appsourcecop.json" } else { 'appsourcecop.json' }
                        $ascContent = Get-FileFromRepo -RepoId $repoId -FilePath $ascPath -Branch 'main'
                        if ($ascContent) {
                            try {
                                $ascJson = $ascContent | ConvertFrom-Json
                                $appSourceCopVersion = $ascJson.version
                            }
                            catch { }
                        }
                    }
                }
            }

            # Load branches for this repo (for target branch dropdown)
            $branches = @()
            try {
                $branches = Get-AdoBranches -RepoId $repoId
            }
            catch {
                Write-Warning "Could not load branches for $repoName"
            }

            # Find matching task
            # Epic-scoped task check (same epic, same app)
            $matchingTask = $null
            if ($existingTasks -and $appShortName) {
                $matchingTask = $existingTasks | Where-Object { $_.title -like "*$appShortName*" } | Select-Object -First 1
            }

            # Cross-team global task check (same app, possibly different epic/team)
            $globalTask = $null
            if ($appShortName -and -not $matchingTask) {
                try { $globalTask = Find-GlobalGATask -AppName $appShortName -TargetMonth ($request.targetMonth ?? '') } catch { }
            }

            # Build task creation preview
            $releaseLabel = switch ($releaseType) {
                'feature'      { 'Major' }
                'stability'    { 'Minor' }
                'hotfix'       { 'Hotfix' }
                'service-pack' { 'Service Pack' }
                default        { 'Minor' }
            }
            $taskTitle = Get-GATaskTitle -AppShortName $appShortName -ReleaseType $releaseType -TargetMonth ($request.targetMonth ?? '')
            $taskPreview = @{
                title       = $taskTitle
                appName     = $repoName
                teamName    = $teamName
                version     = $newVersion
                releaseType = $releaseLabel
            }

            $appPreviews += @{
                repoId              = $repoId
                repoName            = $repoName
                sourceBranch        = $sourceBranch
                appShortName        = $appShortName
                appName             = $appName
                currentVersion      = $currentVersion
                newVersion          = $newVersion
                appSourceCopVersion = $appSourceCopVersion
                branches            = $branches
                error               = $appJsonError
                task                = $matchingTask
                globalTask          = $globalTask   # cross-team consolidation candidate
                taskPreview         = $taskPreview
            }
        }

        $epicPreviews += @{
            epicId        = $epicId
            epicTitle     = $epicTitle
            apps          = $appPreviews
            existingTasks = $existingTasks
        }
    }

    $releaseLabel = switch ($releaseType) {
        'feature'      { 'Major' }
        'stability'    { 'Minor' }
        'hotfix'       { 'Hotfix' }
        'service-pack' { 'Service Pack' }
        default        { 'Minor' }
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            requestId      = $requestId
            teamName       = $teamName
            releaseType    = $releaseType
            releaseLabel   = $releaseLabel
            targetMonth    = $request.targetMonth ?? ''
            releaseWiId    = $releaseWiId
            releaseWiTitle = $releaseWiTitle
            status         = $request.status
            epics          = $epicPreviews
        } | ConvertTo-Json -Depth 10)
    })
}
catch {
    Write-Error "PreviewGA failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = @{ error = $_.Exception.Message } | ConvertTo-Json
    })
}
