# GA Release Portal — Shared Azure DevOps Helper Functions

function Get-AdoHeaders {
    <#
    .SYNOPSIS
        Returns the authorization headers for Azure DevOps REST API calls.
    #>
    $pat = $env:ADO_PAT
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{
        'Authorization' = "Basic $base64Auth"
        'Content-Type'  = 'application/json'
    }
}

function Get-AdoBaseUrl {
    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    return "$org/$project"
}

function Invoke-AdoApi {
    param(
        [string]$Method = 'GET',
        [string]$Url,
        [object]$Body = $null,
        [string]$ApiVersion = '7.1'
    )

    $separator = if ($Url -match '\?') { '&' } else { '?' }
    $fullUrl = "$Url${separator}api-version=$ApiVersion"
    $headers = Get-AdoHeaders

    $params = @{
        Method  = $Method
        Uri     = $fullUrl
        Headers = $headers
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    }
    catch {
        Write-Error "ADO API call failed: $($_.Exception.Message)"
        throw
    }
}

function Get-AdoRepositories {
    <#
    .SYNOPSIS
        Returns all Git repositories the PAT has access to (org-level, not project-scoped).
    #>
    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $url = "$org/_apis/git/repositories"
    $result = Invoke-AdoApi -Url $url
    return $result.value | ForEach-Object {
        @{
            id   = $_.id
            name = $_.name
        }
    } | Sort-Object { $_.name }
}

function Get-AdoBranches {
    <#
    .SYNOPSIS
        Returns all branches for a given repository.
    #>
    param([string]$RepoId)

    $baseUrl = Get-AdoBaseUrl
    $url = "$baseUrl/_apis/git/repositories/$RepoId/refs?filter=heads/"
    $result = Invoke-AdoApi -Url $url
    return $result.value | ForEach-Object {
        $branchName = $_.name -replace '^refs/heads/', ''
        @{
            name     = $branchName
            objectId = $_.objectId
        }
    } | Sort-Object { $_.name }
}

function Get-AdoGAEpics {
    <#
    .SYNOPSIS
        Returns Epics whose Factory Status equals the configured GA validation value.
        Optionally filtered by Area Path containing the given team name.
    #>
    param(
        [string]$TeamName = ''
    )

    $statusField = if ($env:ADO_GA_STATUS_FIELD) { $env:ADO_GA_STATUS_FIELD } else { 'Custom.FactoryStatus' }
    $statusValue = if ($env:ADO_GA_STATUS_VALUE) { $env:ADO_GA_STATUS_VALUE } else { '70 GA Validations' }

    $baseUrl = Get-AdoBaseUrl
    $wiql = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Epic' AND [$statusField] = '$statusValue'"

    $wiql += " ORDER BY [System.Id] DESC"

    $url = "$baseUrl/_apis/wit/wiql"
    $body = @{ query = $wiql }
    $result = Invoke-AdoApi -Method 'POST' -Url $url -Body $body

    if (-not $result.workItems -or $result.workItems.Count -eq 0) {
        return @()
    }

    # Fetch work item details (batch of up to 200)
    $ids = ($result.workItems | Select-Object -First 200).id -join ','
    $detailUrl = "$baseUrl/_apis/wit/workitems?ids=$ids&fields=System.Id,System.Title,System.AreaPath"
    $details = Invoke-AdoApi -Url $detailUrl

    # Filter by team name (last segment of area path) if specified
    $items = $details.value
    if ($TeamName) {
        $items = $items | Where-Object { $_.fields.'System.AreaPath' -like "*\$TeamName" }
    }

    return $items | ForEach-Object {
        @{
            id       = $_.id
            title    = $_.fields.'System.Title'
            areaPath = $_.fields.'System.AreaPath'
        }
    }
}

function New-RequestId {
    $date = Get-Date -Format 'yyyyMMdd'
    $rand = Get-Random -Minimum 100 -Maximum 999
    return "GA-$date-$rand"
}

function Get-StorageContext {
    $connStr = $env:STORAGE_CONNECTION_STRING
    if ($connStr -eq 'UseDevelopmentStorage=true') {
        return New-AzStorageContext -Local
    }
    return New-AzStorageContext -ConnectionString $connStr
}

function Save-RequestToStorage {
    param(
        [hashtable]$Request
    )

    $ctx = Get-StorageContext
    $tableName = 'GAReleaseRequests'

    # Ensure table exists
    $null = New-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue

    $table = (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable

    $entity = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $entity.PartitionKey = $Request.targetMonth ?? (Get-Date -Format 'yyyy-MM')
    $entity.RowKey = $Request.requestId

    foreach ($key in $Request.Keys) {
        $value = $Request[$key]
        if ($value -is [array]) {
            $value = $value -join ','
        }
        if ($value -is [bool]) {
            $entity.Properties[$key] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForBool($value)
        }
        else {
            $entity.Properties[$key] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString([string]$value)
        }
    }

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
    return $true
}

function Get-RequestsFromStorage {
    param(
        [string]$Status = '',
        [string]$Team = ''
    )

    $ctx = Get-StorageContext
    $tableName = 'GAReleaseRequests'

    try {
        $table = (Get-AzStorageTable -Name $tableName -Context $ctx -ErrorAction Stop).CloudTable
    }
    catch {
        return @()
    }

    $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery

    $filters = @()
    if ($Status) {
        $filters += [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('status', 'eq', $Status)
    }
    if ($Team) {
        $filters += [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('teamName', 'eq', $Team)
    }

    if ($filters.Count -gt 0) {
        $combined = $filters[0]
        for ($i = 1; $i -lt $filters.Count; $i++) {
            $combined = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($combined, 'and', $filters[$i])
        }
        $query.FilterString = $combined
    }

    $results = $table.ExecuteQuery($query)

    return $results | ForEach-Object {
        $obj = @{}
        foreach ($prop in $_.Properties.Keys) {
            $val = $_.Properties[$prop].StringValue
            if ($prop -eq 'epics') {
                # Stored as JSON string — parse back to array
                try {
                    $parsed = $val | ConvertFrom-Json
                    # Ensure it's always an array (PS unwraps single-element arrays)
                    $val = @($parsed)
                } catch { $val = @() }
            }
            if ($prop -in @('updatePermissionSets', 'autoCreatePR')) {
                $val = $_.Properties[$prop].BooleanValue
            }
            $obj[$prop] = $val
        }
        $obj['id'] = $_.RowKey
        $obj
    }
}

function Send-NotificationEmail {
    <#
    .SYNOPSIS
        Sends an email notification via Power Automate webhook.
    #>
    param(
        [string]$To,
        [string]$Subject,
        [string]$HtmlBody,
        [string]$From
    )

    $webhookUrl = $env:POWER_AUTOMATE_WEBHOOK_URL

    if (-not $webhookUrl) {
        Write-Warning "POWER_AUTOMATE_WEBHOOK_URL not configured — skipping email to $To"
        return $false
    }

    try {
        $payload = @{
            to      = $To
            from    = $From
            subject = $Subject
            body    = $HtmlBody
        } | ConvertTo-Json -Depth 5

        Invoke-RestMethod -Method POST `
            -Uri $webhookUrl `
            -ContentType 'application/json' `
            -Body $payload -ErrorAction Stop

        Write-Host "Email sent via Power Automate from $From to $To — Subject: $Subject"
        return $true
    }
    catch {
        $errDetail = $_.Exception.Message
        if ($_.ErrorDetails.Message) {
            $errDetail += " | Details: $($_.ErrorDetails.Message)"
        }
        Write-Warning "Failed to send email to ${To}: $errDetail"
        return $false
    }
}

function Build-ApprovalEmailBody {
    <#
    .SYNOPSIS
        Builds the HTML email body for approval/rejection notifications.
    #>
    param(
        [string]$RequestId,
        [string]$TeamName,
        [string]$ReleaseType,
        [string]$Action,
        [string]$SubmitterEmail,
        [array]$Epics
    )

    $statusColor = if ($Action -eq 'approved') { '#22c55e' } else { '#ef4444' }
    $statusLabel = if ($Action -eq 'approved') { 'Approved' } else { 'Rejected' }
    $statusIcon = if ($Action -eq 'approved') { '&#9989;' } else { '&#10060;' }
    $releaseLabel = if ($ReleaseType -eq 'feature') { 'Feature / Major' } else { 'Stability / Minor' }

    $epicRows = ''
    foreach ($epic in $Epics) {
        $appList = ($epic.apps | ForEach-Object {
            "<li><strong>$($_.repoName)</strong> &larr; <code>$($_.sourceBranch)</code></li>"
        }) -join ''
        $epicRows += @"
        <tr>
            <td style="padding:8px;border:1px solid #e5e7eb;">#$($epic.epicNumber)</td>
            <td style="padding:8px;border:1px solid #e5e7eb;">$($epic.epicTitle)</td>
            <td style="padding:8px;border:1px solid #e5e7eb;"><ul style="margin:0;padding-left:16px;">$appList</ul></td>
        </tr>
"@
    }

    $initiatedNote = if ($Action -eq 'approved') {
        '<p style="color:#16a34a;font-weight:600;">The GA team has initiated the release process for your request. You will receive further updates as the process progresses.</p>'
    } else {
        '<p style="color:#dc2626;">If you have questions about why your request was rejected, please reach out to the GA team.</p>'
    }

    return @"
<!DOCTYPE html>
<html>
<head><meta charset="utf-8"></head>
<body style="font-family:Segoe UI,Arial,sans-serif;color:#1e293b;max-width:640px;margin:0 auto;padding:20px;">
    <div style="background:linear-gradient(135deg,#667eea 0%,#764ba2 100%);padding:24px;border-radius:12px 12px 0 0;">
        <h1 style="color:#fff;margin:0;font-size:20px;">$statusIcon GA Release Request — $statusLabel</h1>
    </div>
    <div style="background:#fff;border:1px solid #e5e7eb;border-top:none;padding:24px;border-radius:0 0 12px 12px;">
        <p>Hi,</p>
        <p>Your GA release request <strong>$RequestId</strong> has been
           <span style="color:$statusColor;font-weight:700;">$($statusLabel.ToUpper())</span>.</p>

        <table style="width:100%;border-collapse:collapse;margin:16px 0;">
            <tr><td style="padding:6px 8px;color:#64748b;">Request ID</td><td style="padding:6px 8px;font-weight:600;">$RequestId</td></tr>
            <tr><td style="padding:6px 8px;color:#64748b;">Team</td><td style="padding:6px 8px;">$TeamName</td></tr>
            <tr><td style="padding:6px 8px;color:#64748b;">Release Type</td><td style="padding:6px 8px;">$releaseLabel</td></tr>
            <tr><td style="padding:6px 8px;color:#64748b;">Submitted By</td><td style="padding:6px 8px;">$SubmitterEmail</td></tr>
        </table>

        <h3 style="margin:20px 0 8px;">Epics &amp; Apps</h3>
        <table style="width:100%;border-collapse:collapse;">
            <thead>
                <tr style="background:#f1f5f9;">
                    <th style="padding:8px;border:1px solid #e5e7eb;text-align:left;">Epic #</th>
                    <th style="padding:8px;border:1px solid #e5e7eb;text-align:left;">Title</th>
                    <th style="padding:8px;border:1px solid #e5e7eb;text-align:left;">Apps</th>
                </tr>
            </thead>
            <tbody>$epicRows</tbody>
        </table>

        $initiatedNote

        <hr style="border:none;border-top:1px solid #e5e7eb;margin:24px 0;">
        <p style="color:#94a3b8;font-size:12px;">This is an automated notification from the GA Release Portal.</p>
    </div>
</body>
</html>
"@
}

function Update-RequestStatus {
    param(
        [string]$RequestId,
        [string]$NewStatus
    )

    $ctx = Get-StorageContext
    $tableName = 'GAReleaseRequests'
    $table = (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable

    # Find the entity by RowKey (scan all partitions)
    $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
    $query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('RowKey', 'eq', $RequestId)

    $entity = ($table.ExecuteQuery($query) | Select-Object -First 1)

    if ($entity) {
        $entity.Properties['status'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($NewStatus)
        $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Replace($entity))
        return $true
    }
    return $false
}

function Get-RequestById {
    <#
    .SYNOPSIS
        Fetches a single request from Table Storage by its RowKey (requestId).
    #>
    param([string]$RequestId)

    $ctx = Get-StorageContext
    $tableName = 'GAReleaseRequests'
    $table = (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable

    $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
    $query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('RowKey', 'eq', $RequestId)

    $entity = ($table.ExecuteQuery($query) | Select-Object -First 1)
    if (-not $entity) { return $null }

    $obj = @{}
    foreach ($prop in $entity.Properties.Keys) {
        $val = $entity.Properties[$prop].StringValue
        if ($prop -eq 'epics') {
            try { $parsed = $val | ConvertFrom-Json; $val = @($parsed) } catch { $val = @() }
        }
        $obj[$prop] = $val
    }
    $obj['id'] = $entity.RowKey
    return $obj
}

# ============================================
# GA-Initial Process Functions
# ============================================

function Get-FileFromRepo {
    <#
    .SYNOPSIS
        Reads a file from an ADO Git repository via REST API (no clone needed).
    #>
    param(
        [string]$RepoId,
        [string]$FilePath,
        [string]$Branch = 'main'
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $encodedPath = [uri]::EscapeDataString($FilePath)
    $url = "$org/$project/_apis/git/repositories/$RepoId/items?path=$encodedPath&versionDescriptor.version=$Branch&versionDescriptor.versionType=branch&`$format=text"
    $headers = Get-AdoHeaders

    try {
        $content = Invoke-RestMethod -Method GET -Uri "$url&api-version=7.1" -Headers $headers -ErrorAction Stop
        return $content
    }
    catch {
        Write-Warning "Failed to read $FilePath from repo $RepoId branch $Branch : $($_.Exception.Message)"
        return $null
    }
}

function Get-AppInfoFromRepo {
    <#
    .SYNOPSIS
        Reads app.json from a repo and extracts App Name (from contextSensitiveHelpUrl),
        version, id, name, and dependencies.
    #>
    param(
        [string]$RepoId,
        [string]$Branch
    )

    # Try common paths for app.json
    $appJsonPaths = @('app.json', 'App/app.json', 'src/app.json')
    $appJsonContent = $null
    $foundPath = ''

    foreach ($path in $appJsonPaths) {
        $content = Get-FileFromRepo -RepoId $RepoId -FilePath $path -Branch $Branch
        if ($content) {
            $appJsonContent = $content
            $foundPath = $path
            break
        }
    }

    if (-not $appJsonContent) {
        return @{ error = 'app.json not found' }
    }

    try {
        $appJson = $appJsonContent | ConvertFrom-Json
    }
    catch {
        return @{ error = "Failed to parse app.json: $($_.Exception.Message)" }
    }

    # Extract app short name from contextSensitiveHelpUrl
    $appShortName = ''
    if ($appJson.contextSensitiveHelpUrl) {
        $helpUrl = $appJson.contextSensitiveHelpUrl.TrimEnd('/')
        $segments = $helpUrl -split '/'
        $appShortName = $segments[-1]
    }

    return @{
        appShortName = $appShortName
        appName      = $appJson.name
        appId        = $appJson.id
        version      = $appJson.version
        appJsonPath  = $foundPath
        publisher    = $appJson.publisher
    }
}

function New-VersionBump {
    <#
    .SYNOPSIS
        Calculates the new version based on release type.
        Feature/Major: increment major, reset minor.build.rev to 0
        Stability/Minor: increment minor, reset build.rev to 0
    #>
    param(
        [string]$CurrentVersion,
        [string]$ReleaseType
    )

    $parts = $CurrentVersion -split '\.'
    if ($parts.Count -lt 4) {
        while ($parts.Count -lt 4) { $parts += '0' }
    }

    if ($ReleaseType -eq 'feature') {
        $parts[0] = [string]([int]$parts[0] + 1)
        $parts[1] = '0'
        $parts[2] = '0'
        $parts[3] = '0'
    }
    else {
        # stability / minor
        $parts[1] = [string]([int]$parts[1] + 1)
        $parts[2] = '0'
        $parts[3] = '0'
    }

    return "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
}

function Update-FileInRepo {
    <#
    .SYNOPSIS
        Pushes a single-file change to an ADO Git repo via the REST API (no local clone).
    #>
    param(
        [string]$RepoId,
        [string]$Branch,
        [string]$FilePath,
        [string]$NewContent,
        [string]$CommitMessage,
        [string]$OldObjectId
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/git/repositories/$RepoId/pushes"

    # If we don't have OldObjectId, get the latest commit on the branch
    if (-not $OldObjectId) {
        $refUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=heads/$Branch"
        $refs = Invoke-AdoApi -Url $refUrl
        $branchRef = $refs.value | Where-Object { $_.name -eq "refs/heads/$Branch" } | Select-Object -First 1
        if (-not $branchRef) {
            throw "Branch '$Branch' not found in repo $RepoId"
        }
        $OldObjectId = $branchRef.objectId
    }

    # Base64-encode the content
    $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($NewContent)
    $base64Content = [System.Convert]::ToBase64String($contentBytes)

    $pushBody = @{
        refUpdates = @(
            @{
                name        = "refs/heads/$Branch"
                oldObjectId = $OldObjectId
            }
        )
        commits = @(
            @{
                comment = $CommitMessage
                changes = @(
                    @{
                        changeType = 'edit'
                        item       = @{ path = "/$FilePath" }
                        newContent = @{
                            content     = $base64Content
                            contentType = 'base64encoded'
                        }
                    }
                )
            }
        )
    }

    $result = Invoke-AdoApi -Method 'POST' -Url $url -Body $pushBody
    return $result
}

function Push-MultiFileChanges {
    <#
    .SYNOPSIS
        Pushes multiple file changes in a single commit to an ADO Git repo.
    #>
    param(
        [string]$RepoId,
        [string]$Branch,
        [array]$FileChanges,   # array of @{ path; content }
        [string]$CommitMessage
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/git/repositories/$RepoId/pushes"

    # Get the latest commit on the branch
    $refUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=heads/$Branch"
    $refs = Invoke-AdoApi -Url $refUrl
    $branchRef = $refs.value | Where-Object { $_.name -eq "refs/heads/$Branch" } | Select-Object -First 1
    if (-not $branchRef) {
        throw "Branch '$Branch' not found in repo $RepoId"
    }
    $oldObjectId = $branchRef.objectId

    $changes = $FileChanges | ForEach-Object {
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($_.content)
        $base64Content = [System.Convert]::ToBase64String($contentBytes)
        @{
            changeType = 'edit'
            item       = @{ path = "/$($_.path)" }
            newContent = @{
                content     = $base64Content
                contentType = 'base64encoded'
            }
        }
    }

    $pushBody = @{
        refUpdates = @(
            @{
                name        = "refs/heads/$Branch"
                oldObjectId = $oldObjectId
            }
        )
        commits = @(
            @{
                comment = $CommitMessage
                changes = $changes
            }
        )
    }

    $result = Invoke-AdoApi -Method 'POST' -Url $url -Body $pushBody
    return $result
}

function New-AdoPullRequest {
    <#
    .SYNOPSIS
        Creates a PR in ADO from source → target branch.
    #>
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [string]$Title,
        [string]$Description,
        [string]$WorkItemId
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/git/repositories/$RepoId/pullrequests"

    $prBody = @{
        sourceRefName = "refs/heads/$SourceBranch"
        targetRefName = "refs/heads/$TargetBranch"
        title         = $Title
        description   = $Description
    }

    if ($WorkItemId) {
        $prBody.workItemRefs = @(
            @{ id = $WorkItemId }
        )
    }

    # Add GA reviewers
    $reviewerEmails = ($env:GA_REVIEWERS -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    if ($reviewerEmails.Count -gt 0) {
        $reviewers = @()
        foreach ($email in $reviewerEmails) {
            try {
                $identityUrl = "$org/_apis/identities?searchFilter=General&filterValue=$email"
                $identity = Invoke-AdoApi -Url $identityUrl
                if ($identity.value -and $identity.value.Count -gt 0) {
                    $reviewers += @{ id = $identity.value[0].id }
                }
            }
            catch {
                Write-Warning "Could not resolve reviewer identity for $email"
            }
        }
        if ($reviewers.Count -gt 0) {
            $prBody.reviewers = $reviewers
        }
    }

    try {
        $result = Invoke-AdoApi -Method 'POST' -Url $url -Body $prBody
        $prUrl = "$org/$($env:ADO_PROJECT)/_git/$RepoName/pullrequest/$($result.pullRequestId)"
        return @{
            success       = $true
            pullRequestId = $result.pullRequestId
            url           = $prUrl
        }
    }
    catch {
        $errMsg = $_.Exception.Message
        # Check for existing PR
        if ($errMsg -match '409|TF401179|already exists') {
            return @{
                success = $false
                error   = 'PR already exists'
                exists  = $true
            }
        }
        return @{
            success = $false
            error   = $errMsg
            exists  = $false
        }
    }
}

function New-GATask {
    <#
    .SYNOPSIS
        Creates a Task work item under the specified Epic in ADO.
    #>
    param(
        [string]$EpicId,
        [string]$Title,
        [string]$AppShortName,
        [string]$TeamName,
        [string]$ReleaseType,
        [string]$AssignedTo = ''
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/wit/workitems/`$Task"

    $releaseLabel = if ($ReleaseType -eq 'feature') { 'Major' } else { 'Minor' }

    $patchBody = @(
        @{ op = 'add'; path = '/fields/System.Title'; value = $Title }
    )

    # Add GA Release Work custom fields if present
    if ($AppShortName) {
        $patchBody += @{ op = 'add'; path = '/fields/Custom.AppName'; value = $AppShortName }
    }
    if ($TeamName) {
        $patchBody += @{ op = 'add'; path = '/fields/Custom.TeamName'; value = $TeamName }
    }
    if ($ReleaseType) {
        $patchBody += @{ op = 'add'; path = '/fields/Custom.ReleaseType'; value = $releaseLabel }
    }

    # Link to parent Epic
    $patchBody += @{
        op    = 'add'
        path  = '/relations/-'
        value = @{
            rel = 'System.LinkTypes.Hierarchy-Reverse'
            url = "$org/$project/_apis/wit/workItems/$EpicId"
        }
    }

    $headers = Get-AdoHeaders
    # Work item PATCH requires 'application/json-patch+json'
    $headers['Content-Type'] = 'application/json-patch+json'
    $bodyJson = ($patchBody | ConvertTo-Json -Depth 10)

    try {
        $result = Invoke-RestMethod -Method 'PATCH' `
            -Uri "$url`?api-version=7.1" `
            -Headers $headers `
            -Body $bodyJson -ErrorAction Stop

        return @{
            success    = $true
            taskId     = $result.id
            taskUrl    = $result._links.html.href
        }
    }
    catch {
        Write-Warning "Failed to create task: $($_.Exception.Message)"
        return @{
            success = $false
            error   = $_.Exception.Message
        }
    }
}

function Invoke-GAInitialProcess {
    <#
    .SYNOPSIS
        Runs the full GA-Initial process for a single app:
        1. Read app.json from repo (via API)
        2. Calculate new version
        3. Update app.json version (main + test app dependency)
        4. Update appsourcecop.json version
        5. Commit all changes
        6. Create PR (source → target branch)
        7. Create ADO Task under the epic
    #>
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [string]$ReleaseType,
        [string]$EpicId,
        [string]$TeamName,
        [string]$OverrideVersion = ''
    )

    $log = [System.Collections.ArrayList]::new()
    $null = $log.Add("=== Processing $RepoName ===")

    # Step 1: Read app.json
    $null = $log.Add("[INFO] Reading app.json from $RepoName ($SourceBranch)...")
    $appInfo = Get-AppInfoFromRepo -RepoId $RepoId -Branch $SourceBranch

    if ($appInfo.error) {
        $null = $log.Add("[ERROR] $($appInfo.error)")
        return @{ success = $false; log = $log; error = $appInfo.error }
    }

    $appShortName = $appInfo.appShortName
    $currentVersion = $appInfo.version
    $null = $log.Add("[INFO] App: $($appInfo.appName) | Short: $appShortName | Version: $currentVersion")

    # Step 2: Calculate new version (use override if provided)
    if ($OverrideVersion) {
        $newVersion = $OverrideVersion
        $null = $log.Add("[INFO] Using override version: $newVersion")
    }
    else {
        $newVersion = New-VersionBump -CurrentVersion $currentVersion -ReleaseType $ReleaseType
    }
    $null = $log.Add("[SUCCESS] Version bump: $currentVersion → $newVersion")

    # Step 3: Update app.json content
    $appJsonContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appInfo.appJsonPath -Branch $SourceBranch
    $updatedAppJson = $appJsonContent -replace "(""version""\s*:\s*"")$([regex]::Escape($currentVersion))("")", "`${1}$newVersion`${2}"
    $null = $log.Add("[INFO] Updated app.json version")

    $fileChanges = @(
        @{ path = $appInfo.appJsonPath; content = $updatedAppJson }
    )

    # Step 4: Update appsourcecop.json if it exists
    $appJsonDir = Split-Path $appInfo.appJsonPath -Parent
    $appSourceCopPath = if ($appJsonDir) { "$appJsonDir/appsourcecop.json" } else { 'appsourcecop.json' }
    $appSourceCopContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appSourceCopPath -Branch $SourceBranch

    if ($appSourceCopContent) {
        $updatedAppSourceCop = $appSourceCopContent
        # Update version field if present
        if ($appSourceCopContent -match '"version"\s*:\s*"') {
            $updatedAppSourceCop = $appSourceCopContent -replace '("version"\s*:\s*")[^"]+(")', "`${1}$newVersion`${2}"
            $null = $log.Add("[INFO] Updated appsourcecop.json version")
        }
        $fileChanges += @{ path = $appSourceCopPath; content = $updatedAppSourceCop }
    }
    else {
        $null = $log.Add("[WARN] appsourcecop.json not found — skipped")
    }

    # Step 5: Look for test app and update its dependency version
    $testAppPaths = @('Test/app.json', 'TestApp/app.json', 'test/app.json')
    foreach ($testPath in $testAppPaths) {
        $testAppContent = Get-FileFromRepo -RepoId $RepoId -FilePath $testPath -Branch $SourceBranch
        if ($testAppContent) {
            # Update the test app's own version
            $updatedTestApp = $testAppContent -replace "(""version""\s*:\s*"")$([regex]::Escape($currentVersion))("")", "`${1}$newVersion`${2}"
            # Also update dependency version referencing the main app
            if ($appInfo.appId) {
                # Find the dependency block with this appId and update its version
                $mainAppIdEscaped = [regex]::Escape($appInfo.appId)
                if ($updatedTestApp -match $mainAppIdEscaped) {
                    $updatedTestApp = $updatedTestApp -replace "(""id""\s*:\s*""$mainAppIdEscaped""[^}]*""version""\s*:\s*"")[^""]+("")", "`${1}$newVersion`${2}"
                    $null = $log.Add("[INFO] Updated test app ($testPath) version and dependency")
                }
            }
            $fileChanges += @{ path = $testPath; content = $updatedTestApp }
            break
        }
    }

    # Step 6: Commit all changes
    $releaseLabel = if ($ReleaseType -eq 'feature') { 'Major' } else { 'Minor' }
    $commitMsg = "v$newVersion $releaseLabel Release from BC GA team"
    $null = $log.Add("[INFO] Committing: $commitMsg")

    try {
        $null = Push-MultiFileChanges -RepoId $RepoId -Branch $SourceBranch `
            -FileChanges $fileChanges -CommitMessage $commitMsg
        $null = $log.Add("[SUCCESS] Changes committed to $SourceBranch")
    }
    catch {
        $null = $log.Add("[ERROR] Commit failed: $($_.Exception.Message)")
        return @{ success = $false; log = $log; error = "Commit failed: $($_.Exception.Message)" }
    }

    # Step 7: Create PR
    $null = $log.Add("[INFO] Creating PR: $SourceBranch → $TargetBranch")
    $prTitle = "v$newVersion $releaseLabel Release — $RepoName (GA-Initial)"
    $prDesc = "Automated GA-Initial process.`nApp: $($appInfo.appName) ($appShortName)`nVersion: $currentVersion → $newVersion`nRelease Type: $releaseLabel`nTeam: $TeamName"

    $prResult = New-AdoPullRequest -RepoId $RepoId -RepoName $RepoName `
        -SourceBranch $SourceBranch -TargetBranch $TargetBranch `
        -Title $prTitle -Description $prDesc -WorkItemId $EpicId

    if ($prResult.success) {
        $null = $log.Add("[SUCCESS] PR created: $($prResult.url)")
    }
    elseif ($prResult.exists) {
        $null = $log.Add("[WARN] PR already exists for this branch combination")
    }
    else {
        $null = $log.Add("[ERROR] PR creation failed: $($prResult.error)")
    }

    # Step 8: Create ADO Task
    $taskTitle = "GA Release — $appShortName — v$newVersion $releaseLabel"
    $null = $log.Add("[INFO] Creating ADO Task under Epic #$EpicId")

    $taskResult = New-GATask -EpicId $EpicId -Title $taskTitle `
        -AppShortName $appShortName -TeamName $TeamName -ReleaseType $ReleaseType

    if ($taskResult.success) {
        $null = $log.Add("[SUCCESS] Task #$($taskResult.taskId) created")
    }
    else {
        $null = $log.Add("[WARN] Task creation failed: $($taskResult.error)")
    }

    return @{
        success       = $true
        log           = $log
        appShortName  = $appShortName
        appName       = $appInfo.appName
        oldVersion    = $currentVersion
        newVersion    = $newVersion
        commitMessage = $commitMsg
        prResult      = $prResult
        taskResult    = $taskResult
    }
}

Export-ModuleMember -Function *
