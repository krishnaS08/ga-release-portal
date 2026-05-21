using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $requestId = $body.requestId

    # Optional single-app filter — when provided, validate only this one (repo, branch).
    # Used by the frontend's per-app progress flow so each call returns quickly and
    # the UI can render real percentage progress.
    $singleRepoId       = $body.repoId
    $singleSourceBranch = $body.sourceBranch
    $singleAppName      = $body.appName
    $singleEpicNumber   = $body.epicNumber

    $perRepoResults = @()
    $allMissing     = @()

    if ($singleRepoId -and $singleSourceBranch) {
        Write-Host "Validating translations for SINGLE app: $singleAppName ($singleSourceBranch)"
        $result = Test-RepoTranslationCoverage `
            -RepoId         $singleRepoId `
            -RepoName       ($singleAppName ?? $singleRepoId) `
            -SourceBranch   $singleSourceBranch `
            -BaselineBranch 'main'

        $perRepoResults += $result
        foreach ($m in $result.missing) {
            $allMissing += @{
                appName    = ($singleAppName ?? $singleRepoId)
                epicNumber = $singleEpicNumber
                file       = $m.file
                line       = $m.line
                type       = $m.type
                text       = $m.text
            }
        }
    }
    else {
        # Fallback: walk every (repo, sourceBranch) pair across all epics in the request
        if (-not $requestId) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::BadRequest
                Body       = (@{ error = 'requestId (or repoId+sourceBranch) is required' } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }

        $request = Get-RequestById -RequestId $requestId
        if (-not $request) {
            Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
                StatusCode = [HttpStatusCode]::NotFound
                Body       = (@{ error = "Request $requestId not found" } | ConvertTo-Json)
                Headers    = @{ 'Content-Type' = 'application/json' }
            })
            return
        }

        $repoKeys = New-Object 'System.Collections.Generic.HashSet[string]'
        foreach ($epic in $request.epics) {
            foreach ($app in $epic.apps) {
                $key = "$($app.repoId)|$($app.sourceBranch)"
                if (-not $repoKeys.Add($key)) { continue }   # skip duplicates

                Write-Host "Validating translations for $($app.repoName) @ $($app.sourceBranch)"
                $result = Test-RepoTranslationCoverage `
                    -RepoId         $app.repoId `
                    -RepoName       $app.repoName `
                    -SourceBranch   $app.sourceBranch `
                    -BaselineBranch 'main'

                $perRepoResults += $result
                foreach ($m in $result.missing) {
                    $allMissing += @{
                        appName    = $app.repoName
                        epicNumber = $epic.epicNumber
                        file       = $m.file
                        line       = $m.line
                        type       = $m.type
                        text       = $m.text
                    }
                }
            }
        }
    }

    $payload = @{
        requestId   = $requestId
        hasMissing  = ($allMissing.Count -gt 0)
        missing     = $allMissing
        perRepo     = $perRepoResults
        checkedAt   = (Get-Date).ToUniversalTime().ToString('o')
    } | ConvertTo-Json -Depth 6

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = $payload
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "ValidateTranslations failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
