using namespace System.Net

param($Request, $TriggerMetadata)

Import-Module "$PSScriptRoot/../Shared/AdoHelpers.psm1" -Force

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

            # Read app.json
            $appInfo = Get-AppInfoFromRepo -RepoId $repoId -Branch $sourceBranch
            $currentVersion = $null
            $newVersion     = $null
            $appShortName   = ''
            $appName        = ''
            $appJsonError   = $null

            if ($appInfo.error) {
                $appJsonError = $appInfo.error
            }
            else {
                $currentVersion = $appInfo.version
                $appShortName   = $appInfo.appShortName
                $appName        = $appInfo.appName
                $newVersion     = New-VersionBump -CurrentVersion $currentVersion -ReleaseType $releaseType
            }

            # Read appsourcecop.json
            $appSourceCopVersion = $null
            if (-not $appJsonError -and $appInfo.appJsonPath) {
                $appJsonDir = Split-Path $appInfo.appJsonPath -Parent
                $ascPath = if ($appJsonDir) { "$appJsonDir/appsourcecop.json" } else { 'appsourcecop.json' }
                $ascContent = Get-FileFromRepo -RepoId $repoId -FilePath $ascPath -Branch $sourceBranch
                if ($ascContent) {
                    try {
                        $ascJson = $ascContent | ConvertFrom-Json
                        $appSourceCopVersion = $ascJson.version
                    }
                    catch { }
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
            $matchingTask = $null
            if ($existingTasks -and $appShortName) {
                $matchingTask = $existingTasks | Where-Object { $_.title -like "*$appShortName*" } | Select-Object -First 1
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
            }
        }

        $epicPreviews += @{
            epicId        = $epicId
            epicTitle     = $epicTitle
            apps          = $appPreviews
            existingTasks = $existingTasks
        }
    }

    $releaseLabel = if ($releaseType -eq 'feature') { 'Major' } else { 'Minor' }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{
            requestId    = $requestId
            teamName     = $teamName
            releaseType  = $releaseType
            releaseLabel = $releaseLabel
            status       = $request.status
            epics        = $epicPreviews
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
