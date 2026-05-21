using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $action     = $body.action       # 'create' or 'delete'
    $branchName = $body.branchName
    $sourceBranch = $body.sourceBranch ?? 'main'
    $repos      = $body.repos

    if (-not $action -or -not $branchName -or -not $repos -or $repos.Count -eq 0) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ message = "Missing required fields: action, branchName, repos" } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    $results = @()
    foreach ($repo in $repos) {
        if ($action -eq 'create') {
            $result = New-AdoBranch -RepoId $repo.id -RepoName $repo.name -BranchName $branchName -SourceBranch $sourceBranch
        }
        elseif ($action -eq 'delete') {
            $result = Remove-AdoBranch -RepoId $repo.id -RepoName $repo.name -BranchName $branchName
        }
        else {
            $result = @{ name = $repo.name; success = $false; error = "Unknown action '$action'" }
        }
        $results += $result
    }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = ($results | ConvertTo-Json -Depth 5 -AsArray)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "ManageBranch failed: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ message = "Branch operation failed: $_" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
