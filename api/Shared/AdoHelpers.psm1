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
    }
}

function Get-AdoBaseUrl {
    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    return "$org/$project"
}

function Get-MonthDisplayName {
    param([string]$TargetMonth)
    $map = @{ JAN='January'; FEB='February'; MAR='March'; APR='April'; MAY='May'; JUN='June';
              JUL='July'; AUG='August'; SEP='September'; OCT='October'; NOV='November'; DEC='December' }
    $abbr = ($TargetMonth -split '[\s\-]+')[0].Trim().ToUpper()
    return $(if ($map.ContainsKey($abbr)) { $map[$abbr] } else { $abbr })
}

function Get-GATaskTitle {
    param(
        [string]$AppShortName,
        [string]$ReleaseType,
        [string]$TargetMonth = ''
    )
    if ($ReleaseType -eq 'hotfix') {
        return "$AppShortName - Hotfix - GA Release Activity"
    }
    $monthName = Get-MonthDisplayName -TargetMonth $TargetMonth
    return "$AppShortName - $monthName Release - GA Release Activity"
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
        $params.ContentType = 'application/json; charset=utf-8'
    }

    try {
        $response = Invoke-RestMethod @params -ErrorAction Stop
        return $response
    }
    catch {
        $errMsg = $_.Exception.Message
        $errBody = $_.ErrorDetails.Message
        if ($errBody) {
            Write-Error "ADO API call failed: $errMsg — Response: $errBody"
        } else {
            Write-Error "ADO API call failed: $errMsg"
        }
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
    $prefix = "GA-$date-"

    # Query Table Storage for today's requests to find the next sequence number
    try {
        $ctx = Get-StorageContext
        $tableName = 'GAReleaseRequests'
        $null = New-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue
        $cloudTable = (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable

        $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
        $startFilter = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('RowKey', 'ge', $prefix)
        $endFilter   = [Microsoft.Azure.Cosmos.Table.TableQuery]::GenerateFilterCondition('RowKey', 'lt', "GA-$date/")
        $query.FilterString = [Microsoft.Azure.Cosmos.Table.TableQuery]::CombineFilters($startFilter, 'and', $endFilter)
        $query.SelectColumns = [System.Collections.Generic.List[string]]@('RowKey')

        $existing = $cloudTable.ExecuteQuery($query)
        $maxSeq = 0
        foreach ($row in $existing) {
            $parts = $row.RowKey -split '-'
            $seq = [int]($parts[-1])
            if ($seq -gt $maxSeq) { $maxSeq = $seq }
        }
        $next = $maxSeq + 1
    }
    catch {
        Write-Host "Warning: Could not query for existing IDs, defaulting to 1. Error: $_"
        $next = 1
    }

    return "$prefix$next"
}

function Get-StorageContext {
    $connStr = $env:STORAGE_CONNECTION_STRING
    if ($connStr -eq 'UseDevelopmentStorage=true') {
        # Fast connectivity check so a missing Azurite fails in ~2s instead of hanging ~30s per call.
        $tcp = New-Object System.Net.Sockets.TcpClient
        try {
            $ar = $tcp.BeginConnect('127.0.0.1', 10002, $null, $null)
            $ok = $ar.AsyncWaitHandle.WaitOne(2000, $false)
        } finally { $tcp.Close() }
        if (-not $ok) {
            throw "Azurite is not running on port 10002. Run: azurite --location .azurite"
        }
        return New-AzStorageContext -Local
    }
    return New-AzStorageContext -ConnectionString $connStr
}

function Save-AttachmentToBlob {
    param(
        [string]$RequestId,
        [string]$FileName,
        [string]$ContentType,
        [string]$DataBase64
    )

    $ctx = Get-StorageContext
    $containerName = 'ga-attachments'

    $existing = Get-AzStorageContainer -Name $containerName -Context $ctx -ErrorAction SilentlyContinue
    if (-not $existing) {
        New-AzStorageContainer -Name $containerName -Context $ctx -Permission Off | Out-Null
    }

    $bytes = [Convert]::FromBase64String($DataBase64)
    $tmpFile = [System.IO.Path]::GetTempFileName()
    try {
        [System.IO.File]::WriteAllBytes($tmpFile, $bytes)
        $blobName = "$RequestId/$FileName"
        Set-AzStorageBlobContent -File $tmpFile -Container $containerName -Blob $blobName `
            -Properties @{ ContentType = $ContentType } -Context $ctx -Force | Out-Null
    }
    finally {
        Remove-Item $tmpFile -ErrorAction SilentlyContinue
    }

    $expiry = (Get-Date).ToUniversalTime().AddYears(2)
    $sasUri = New-AzStorageBlobSASToken -Container $containerName -Blob $blobName `
        -Context $ctx -Permission r -ExpiryTime $expiry -FullUri
    return $sasUri
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

function Remove-RequestFromStorage {
    <#
    .SYNOPSIS
        Permanently deletes a request row from the GAReleaseRequests table.
        Returns $true on success, $false if the row didn't exist.
    #>
    param([Parameter(Mandatory)][string]$RequestId)

    $ctx = Get-StorageContext
    $tableName = 'GAReleaseRequests'
    try {
        $table = (Get-AzStorageTable -Name $tableName -Context $ctx -ErrorAction Stop).CloudTable
    } catch {
        return $false
    }

    # We don't know the PartitionKey (= targetMonth) up-front, so look up first
    $existing = Get-RequestById -RequestId $RequestId
    if (-not $existing) { return $false }

    # Locate the entity and delete it
    $partitionKey = if ($existing.targetMonth) { [string]$existing.targetMonth } else { (Get-Date -Format 'yyyy-MM') }
    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve($partitionKey, $RequestId)
    $r = $table.Execute($op)
    if (-not $r.Result) { return $false }

    $deleteOp = [Microsoft.Azure.Cosmos.Table.TableOperation]::Delete($r.Result)
    $null = $table.Execute($deleteOp)
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

function New-OverrideId {
    $date = Get-Date -Format 'yyyyMMdd'
    $rand = ([guid]::NewGuid().ToString('N')).Substring(0, 8)
    return "OVR-$date-$rand"
}

function Get-OverrideTable {
    $ctx = Get-StorageContext
    $tableName = 'GACutoffOverrides'
    $null = New-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue
    return (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable
}

function Save-OverrideRequest {
    param([hashtable]$Override)

    $table = Get-OverrideTable
    $entity = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $entity.PartitionKey = 'override'
    $entity.RowKey = $Override.id

    foreach ($key in $Override.Keys) {
        if ($key -eq 'id') { continue }
        $value = [string]$Override[$key]
        $entity.Properties[$key] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($value)
    }

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
    return $true
}

function Get-OverrideRequest {
    param([Parameter(Mandatory)][string]$Id)

    try {
        $table = Get-OverrideTable
    } catch { return $null }

    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve('override', $Id)
    $result = $table.Execute($op)
    if (-not $result.Result) { return $null }

    $entity = $result.Result
    $obj = @{ id = $entity.RowKey }
    foreach ($prop in $entity.Properties.Keys) {
        $obj[$prop] = $entity.Properties[$prop].StringValue
    }
    return $obj
}

function Update-OverrideStatus {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][ValidateSet('approved', 'rejected')][string]$Status,
        [string]$DecidedBy = 'via Teams approval link'
    )

    $existing = Get-OverrideRequest -Id $Id
    if (-not $existing) { return $null }
    if ($existing.status -ne 'pending') { return $existing }   # idempotent — already decided

    $existing.status = $Status
    $existing.decidedBy = $DecidedBy
    $existing.decidedAt = (Get-Date).ToUniversalTime().ToString('o')

    Save-OverrideRequest -Override $existing | Out-Null
    return $existing
}

function Get-OverrideHmacToken {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Decision
    )
    $secret = $env:OVERRIDE_SIGNING_SECRET
    if (-not $secret) { throw "OVERRIDE_SIGNING_SECRET env var is not configured" }

    $payload = "$Id|$Decision"
    $hmac = [System.Security.Cryptography.HMACSHA256]::new([Text.Encoding]::UTF8.GetBytes($secret))
    try {
        $hash = $hmac.ComputeHash([Text.Encoding]::UTF8.GetBytes($payload))
    } finally {
        $hmac.Dispose()
    }
    # base64url
    return ([Convert]::ToBase64String($hash)) -replace '\+','-' -replace '/','_' -replace '=',''
}

function Test-OverrideHmacToken {
    param(
        [Parameter(Mandatory)][string]$Id,
        [Parameter(Mandatory)][string]$Decision,
        [Parameter(Mandatory)][string]$Token
    )
    try {
        $expected = Get-OverrideHmacToken -Id $Id -Decision $Decision
    } catch {
        return $false
    }
    # constant-time compare
    if ($expected.Length -ne $Token.Length) { return $false }
    $diff = 0
    for ($i = 0; $i -lt $expected.Length; $i++) {
        $diff = $diff -bor ([byte][char]$expected[$i] -bxor [byte][char]$Token[$i])
    }
    return ($diff -eq 0)
}

function Get-GraphAppToken {
    <#
    .SYNOPSIS
        Acquires a Microsoft Graph access token using the AAD app's
        client-credentials grant. Cached for the token lifetime.
    #>
    if ($script:GraphTokenCache -and $script:GraphTokenCacheExpiry -gt (Get-Date).AddMinutes(5)) {
        return $script:GraphTokenCache
    }

    $tenantId     = $env:AAD_TENANT_ID
    if (-not $tenantId) { $tenantId = '560ec2b0-df0c-4e8c-9848-a15718863bb6' }   # Aptean default
    $clientId     = $env:AAD_CLIENT_ID
    $clientSecret = $env:AAD_CLIENT_SECRET

    if (-not $clientId -or -not $clientSecret) {
        throw "AAD_CLIENT_ID or AAD_CLIENT_SECRET not configured — Graph mail send disabled."
    }

    $body = @{
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = 'https://graph.microsoft.com/.default'
        grant_type    = 'client_credentials'
    }
    $url  = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $resp = Invoke-RestMethod -Method POST -Uri $url -Body $body -ContentType 'application/x-www-form-urlencoded' -ErrorAction Stop

    $script:GraphTokenCache       = $resp.access_token
    $script:GraphTokenCacheExpiry = (Get-Date).AddSeconds([int]$resp.expires_in)
    return $resp.access_token
}

function Send-GraphMail {
    <#
    .SYNOPSIS
        Sends an email via Microsoft Graph sendMail using the AAD app's
        Mail.Send (Application) permission. Returns $true on success, $false
        on configuration miss; throws on remote-API failure so the caller
        can fall back.
    #>
    param(
        [Parameter(Mandatory)][string]$To,
        [Parameter(Mandatory)][string]$Subject,
        [Parameter(Mandatory)][string]$HtmlBody,
        [string]$From,
        [string[]]$Cc = @(),
        [string]$ReplyTo
    )

    if (-not $From) { $From = $env:GRAPH_MAIL_FROM }
    if (-not $From) {
        Write-Warning "GRAPH_MAIL_FROM not configured — Graph mail send skipped"
        return $false
    }

    $token = Get-GraphAppToken
    if (-not $token) { return $false }

    $toRecipients = @(@{ emailAddress = @{ address = $To } })
    $ccRecipients = @()
    foreach ($c in @($Cc)) {
        if ($c) { $ccRecipients += @{ emailAddress = @{ address = [string]$c } } }
    }

    $message = @{
        subject       = $Subject
        body          = @{ contentType = 'HTML'; content = $HtmlBody }
        toRecipients  = $toRecipients
    }
    if ($ccRecipients.Count -gt 0) { $message.ccRecipients = $ccRecipients }
    if ($ReplyTo) {
        $message.replyTo = @(@{ emailAddress = @{ address = $ReplyTo } })
    }

    $payload = @{
        message         = $message
        saveToSentItems = $true
    } | ConvertTo-Json -Depth 10

    $url = "https://graph.microsoft.com/v1.0/users/$([uri]::EscapeDataString($From))/sendMail"
    $headers = @{
        Authorization  = "Bearer $token"
        'Content-Type' = 'application/json'
    }

    try {
        Invoke-RestMethod -Method POST -Uri $url -Headers $headers -Body $payload -ErrorAction Stop
        Write-Host "Graph: mail sent from $From to $To — Subject: $Subject"
        return $true
    }
    catch {
        $errDetail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $errDetail += " | $($_.ErrorDetails.Message)"
        }
        throw "Graph sendMail failed: $errDetail"
    }
}

function Send-NotificationEmail {
    <#
    .SYNOPSIS
        Sends an email notification.
        - If GRAPH_MAIL_FROM is configured, uses Microsoft Graph sendMail
          (Mail.Send application permission) — preferred.
        - Otherwise falls back to the Power Automate webhook.
    #>
    param(
        [string]$To,
        [string]$Subject,
        [string]$HtmlBody,
        [string]$From,
        [string[]]$Cc = @()
    )

    # --- Path 1: Microsoft Graph (preferred when configured) ---
    # The sender mailbox is ALWAYS $env:GRAPH_MAIL_FROM (e.g. fb_captainamerica@aptean.com)
    # so notifications come from the GA service mailbox rather than whoever clicked Approve.
    # The $From parameter is used as Reply-To (so recipients can still reply to the approver).
    if ($env:GRAPH_MAIL_FROM) {
        try {
            $ok = Send-GraphMail -To $To -Subject $Subject -HtmlBody $HtmlBody `
                                 -From $env:GRAPH_MAIL_FROM -Cc $Cc -ReplyTo $From
            if ($ok) { return $true }
        }
        catch {
            Write-Warning "Graph mail failed for ${To}: $($_.Exception.Message) — will try Power Automate fallback."
            # fall through to webhook path
        }
    }

    # --- Path 2: Power Automate webhook fallback ---
    $webhookUrl = $env:POWER_AUTOMATE_WEBHOOK_URL
    if (-not $webhookUrl) {
        Write-Warning "Neither GRAPH_MAIL_FROM nor POWER_AUTOMATE_WEBHOOK_URL configured — skipping email to $To"
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
        Uses Invoke-WebRequest to get raw text content (avoids Invoke-RestMethod auto-parsing JSON).
    #>
    param(
        [string]$RepoId,
        [string]$FilePath,
        [string]$Branch = 'main'
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    # Encode each path segment individually — preserve '/' separators
    $encodedPath = ($FilePath -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
    $url = "$org/$project/_apis/git/repositories/$RepoId/items?path=$encodedPath&versionDescriptor.version=$Branch&versionDescriptor.versionType=branch&`$format=text&api-version=7.1"
    $headers = Get-AdoHeaders

    try {
        # Use Invoke-WebRequest to get raw text — prevents auto-parsing of JSON files
        $response = Invoke-WebRequest -Method GET -Uri $url -Headers $headers -ErrorAction Stop
        # .Content may be byte[] (when Content-Type is application/octet-stream) or string
        if ($response.Content -is [byte[]]) {
            return [System.Text.Encoding]::UTF8.GetString($response.Content)
        }
        return $response.Content
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
        Uses recursive item listing to discover app.json in any subdirectory.
    #>
    param(
        [string]$RepoId,
        [string]$Branch
    )

    # Step 1: Try common paths first (fast path)
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

    # Step 2: If not found, list all items in repo and search for app.json
    if (-not $appJsonContent) {
        Write-Host "[INFO] app.json not found at common paths, searching repo recursively..."
        try {
            $org = $env:ADO_ORG_URL.TrimEnd('/')
            $project = [uri]::EscapeDataString($env:ADO_PROJECT)
            $itemsUrl = "$org/$project/_apis/git/repositories/$RepoId/items?scopePath=/&recursionLevel=Full&versionDescriptor.version=$Branch&versionDescriptor.versionType=branch"
            $items = Invoke-AdoApi -Url $itemsUrl

            if ($items.value) {
                # Find all app.json files, excluding test folders
                $appJsonItems = $items.value | Where-Object {
                    $_.path -like '*/app.json' -and
                    $_.path -notmatch '(?i)(test|\.test)'
                } | Select-Object -First 1

                # If no non-test app.json found, try any app.json
                if (-not $appJsonItems) {
                    $appJsonItems = $items.value | Where-Object {
                        $_.path -like '*/app.json'
                    } | Select-Object -First 1
                }

                if ($appJsonItems) {
                    $discoveredPath = $appJsonItems.path.TrimStart('/')
                    Write-Host "[INFO] Found app.json at: $discoveredPath"
                    $content = Get-FileFromRepo -RepoId $RepoId -FilePath $discoveredPath -Branch $Branch
                    if ($content) {
                        $appJsonContent = $content
                        $foundPath = $discoveredPath
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to list repo items for app.json discovery: $($_.Exception.Message)"
        }
    }

    if (-not $appJsonContent) {
        return @{ error = 'app.json not found' }
    }

    try {
        # Handle case where content is already a parsed object (Invoke-RestMethod auto-parse)
        if ($appJsonContent -is [string]) {
            $appJson = $appJsonContent | ConvertFrom-Json
        }
        else {
            $appJson = $appJsonContent
        }
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
        Version format: YYMM.minor.build.revision
        Feature/Major: YYMM increments to next target month (e.g. 2603 → 2604), minor/build/rev reset to 0
        Stability/Minor/Hotfix: minor increments, build/rev reset to 0
    #>
    param(
        [string]$CurrentVersion,
        [string]$ReleaseType,
        [string]$TargetMonth = ''  # e.g. "JUN-2026"
    )

    $parts = $CurrentVersion -split '\.'
    if ($parts.Count -lt 4) {
        while ($parts.Count -lt 4) { $parts += '0' }
    }

    if ($ReleaseType -eq 'feature') {
        # Calculate next YYMM from target month if provided, else increment current YYMM
        if ($TargetMonth -and $TargetMonth -match '^([A-Z]{3})-(\d{4})$') {
            $monthNames = @('JAN','FEB','MAR','APR','MAY','JUN','JUL','AUG','SEP','OCT','NOV','DEC')
            $mIdx = [array]::IndexOf($monthNames, $Matches[1]) + 1
            $yr = $Matches[2].Substring(2)  # last 2 digits
            $newYYMM = "$yr{0:D2}" -f $mIdx
            $parts[0] = $newYYMM
        }
        else {
            # Fallback: increment YYMM by 1 month
            $yymm = [int]$parts[0]
            $yy = [math]::Floor($yymm / 100)
            $mm = $yymm % 100
            $mm++
            if ($mm -gt 12) { $mm = 1; $yy++ }
            $parts[0] = "$yy{0:D2}" -f $mm
        }
        $parts[1] = '0'
        $parts[2] = '0'
        $parts[3] = '0'
    }
    else {
        # stability / minor / hotfix — increment minor, reset build/rev
        $parts[1] = [string]([int]$parts[1] + 1)
        $parts[2] = '0'
        $parts[3] = '0'
    }

    return "$($parts[0]).$($parts[1]).$($parts[2]).$($parts[3])"
}

function Get-StableTagVersion {
    <#
    .SYNOPSIS
        Gets the version from the latest stable tag on a branch.
        Handles tag formats: stable-YYMM.minor.build.revision, Stable-YYMM.minor.build.revision,
        Stable_YYMM.minor.build.revision, etc.
        Returns just the version part (e.g. "2603.3.56789.0").
    #>
    param(
        [string]$RepoId,
        [string]$Branch = 'main'
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    
    try {
        # Get all tags (use broad filter to catch Stable/stable variants)
        $url = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=tags/"
        $result = Invoke-AdoApi -Url $url

        if (-not $result.value -or $result.value.Count -eq 0) {
            Write-Host "[INFO] No tags found for repo $RepoId"
            return $null
        }

        # Filter for stable tags using regex matching both Stable and stable with optional separator
        $stableTags = $result.value | Where-Object {
            $_.name -match 'refs/tags/(Stable|stable)[-_]?(\d+\.\d+\.\d+\.\d+)'
        } | ForEach-Object {
            if ($_.name -match '(\d+\.\d+\.\d+\.\d+)') {
                @{
                    name      = $_.name -replace '^refs/tags/', ''
                    version   = $Matches[1]
                    objectId  = $_.objectId
                }
            }
        } | Where-Object { $_ }

        if (-not $stableTags -or $stableTags.Count -eq 0) {
            Write-Host "[INFO] No stable tags found for repo $RepoId"
            return $null
        }

        Write-Host "[INFO] Found $($stableTags.Count) stable tags for repo $RepoId"

        # Sort by version descending (compare as version strings)
        $sorted = $stableTags | Sort-Object {
            $v = $_.version -split '\.'
            ($v | ForEach-Object { $_.PadLeft(10, '0') }) -join '.'
        } -Descending

        $latestVersion = $sorted[0].version
        Write-Host "[INFO] Latest stable tag version: $latestVersion"
        return $latestVersion
    }
    catch {
        Write-Warning "Failed to get stable tags for repo $RepoId : $($_.Exception.Message)"
        return $null
    }
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

    $changes = @($FileChanges | ForEach-Object {
        $p = $_.path -replace '^/+', ''
        $contentBytes = [System.Text.Encoding]::UTF8.GetBytes($_.content)
        $base64Content = [System.Convert]::ToBase64String($contentBytes)

        # Check if the file exists on the branch — also get actual path casing
        $org = $env:ADO_ORG_URL.TrimEnd('/')
        $project = [uri]::EscapeDataString($env:ADO_PROJECT)
        $encodedItemPath = ($p -split '/' | ForEach-Object { [uri]::EscapeDataString($_) }) -join '/'
        $itemUrl = "$org/$project/_apis/git/repositories/$RepoId/items?path=$encodedItemPath&versionDescriptor.version=$Branch&versionDescriptor.versionType=branch&`$format=json&api-version=7.1"
        $actualPath = $null
        try {
            $hdrs = Get-AdoHeaders
            $itemMeta = Invoke-RestMethod -Uri $itemUrl -Headers $hdrs -ErrorAction Stop
            $actualPath = $itemMeta.path   # exact casing from repo
        } catch { }
        $existsOnBranch = $null -ne $actualPath
        $changeType = if ($existsOnBranch) { 'edit' } else { 'add' }
        $finalPath = if ($actualPath) { $actualPath } else { "/$p" }
        Write-Host "[Push] File: $p | ChangeType: $changeType | Path: $finalPath"

        @{
            changeType = $changeType
            item       = @{ path = $finalPath }
            newContent = @{
                content     = $base64Content
                contentType = 'base64encoded'
            }
        }
    })

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
        [string]$WorkItemId,
        [string]$InitiatorEmail = '',
        [string]$InitiatorName  = ''
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

    # Add GA reviewers dynamically.
    # The initiator is NOT excluded — they are added as an optional reviewer so their
    # identity appears on the PR (the PR is technically created by the service PAT, but
    # the initiator shows as a participant). Other team members are added as required reviewers.
    $allReviewerEmails = ($env:GA_REVIEWER_MAP -split ',') | ForEach-Object { $_.Trim() } | Where-Object { $_ }
    $defaultReviewer = ($env:GA_DEFAULT_REVIEWER ?? '').Trim()
    $secondaryReviewer = ($env:GA_SECONDARY_REVIEWER ?? '').Trim()
    $initiator = $InitiatorEmail.Trim().ToLower()

    # Required reviewers: everyone except the initiator
    $candidateEmails = $allReviewerEmails | Where-Object { $_.ToLower() -ne $initiator }

    # Build ordered reviewer list: default first, then secondary, then others
    $orderedReviewers = @()
    if ($defaultReviewer -and ($candidateEmails | Where-Object { $_.ToLower() -eq $defaultReviewer.ToLower() })) {
        $orderedReviewers += $defaultReviewer
    }
    if ($secondaryReviewer -and ($candidateEmails | Where-Object { $_.ToLower() -eq $secondaryReviewer.ToLower() })) {
        $orderedReviewers += $secondaryReviewer
    }
    foreach ($e in $candidateEmails) {
        if ($orderedReviewers -notcontains $e) { $orderedReviewers += $e }
    }

    Write-Host "[PR] Initiator: $initiator | Required reviewers: $($orderedReviewers -join ', ')"

    $hdrs = Get-AdoHeaders
    $orgName = if ($org -match 'dev\.azure\.com/([^/]+)') { $Matches[1] } elseif ($org -match '//([^.]+)\.visualstudio\.com') { $Matches[1] } else { '' }

    # Helper: resolve an email to an ADO identity id
    function Resolve-ReviewerIdentity([string]$Email) {
        try {
            $url = "https://vssps.dev.azure.com/$orgName/_apis/identities?searchFilter=MailAddress&filterValue=$([uri]::EscapeDataString($Email))&api-version=7.1"
            $r = Invoke-RestMethod -Uri $url -Headers $hdrs -ErrorAction Stop
            if ($r.value -and $r.value.Count -gt 0) { return $r.value[0].id }
        } catch {
            Write-Warning "Could not resolve reviewer identity for $Email : $($_.Exception.Message)"
        }
        return $null
    }

    $reviewers = [System.Collections.Generic.List[hashtable]]::new()

    # Add the initiator as an optional reviewer (isRequired = false) so their name shows on the PR
    if ($initiator) {
        $initiatorId = Resolve-ReviewerIdentity -Email $initiator
        if ($initiatorId) {
            $reviewers.Add(@{ id = $initiatorId; isRequired = $false })
            Write-Host "[PR] Added initiator as optional reviewer: $initiator -> $initiatorId"
        }
    }

    # Add required reviewers
    foreach ($email in $orderedReviewers) {
        $id = Resolve-ReviewerIdentity -Email $email
        if ($id) {
            $reviewers.Add(@{ id = $id; isRequired = $true })
            Write-Host "[PR] Resolved required reviewer: $email -> $id"
        } else {
            Write-Warning "No identity found for reviewer $email"
        }
    }

    if ($reviewers.Count -gt 0) {
        $prBody.reviewers = $reviewers.ToArray()
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

function Find-GlobalGATask {
    <#
    .SYNOPSIS
        WIQL search for any open GA Task in the BC GA area path whose Custom.AppName
        matches exactly. Used for cross-epic consolidation (same app, different team).
        TargetMonth (e.g. "MAY-2026") scopes the search to the current release cycle via
        the System.Tags field so old-month tasks are not mistakenly treated as conflicts.
        Returns @{ taskId, title, state, appName, teamName } or $null.
    #>
    param(
        [Parameter(Mandatory)][string]$AppName,
        [string]$TargetMonth = ''
    )

    $areaFilter = if ($env:ADO_CLOSURE_AREA_PATH) { $env:ADO_CLOSURE_AREA_PATH } else { 'Foodware 365 BC\CoE\BC GA' }
    $baseUrl    = Get-AdoBaseUrl

    $escaped  = $AppName.Replace("'", "''")

    # Scope to the current release month via the tag set at task-creation time (e.g. "MAY; GA2026")
    $tagFilter = ''
    if ($TargetMonth) {
        $parts = $TargetMonth.Trim() -split '[\s\-]+'
        if ($parts.Count -ge 1 -and $parts[0]) {
            $monthTag = $parts[0].ToUpper()
            $tagFilter = " AND [System.Tags] CONTAINS '$monthTag'"
        }
    }

    $wiqlBody = @{
        query = "SELECT [System.Id] FROM WorkItems WHERE [System.WorkItemType] = 'Task' AND [System.State] <> 'Closed' AND [System.AreaPath] UNDER '$areaFilter' AND [Custom.AppName] = '$escaped'$tagFilter"
    }
    try {
        $wiqlResult = Invoke-AdoApi -Method 'POST' -Url "$baseUrl/_apis/wit/wiql" -Body $wiqlBody
        if (-not $wiqlResult.workItems -or $wiqlResult.workItems.Count -eq 0) { return $null }

        $ids     = ($wiqlResult.workItems | Select-Object -First 10 | ForEach-Object { $_.id }) -join ','
        $fields  = "System.Id,System.Title,System.State,Custom.AppName,Custom.TeamName,Custom.Version"
        $details = Invoke-AdoApi -Url "$baseUrl/_apis/wit/workitems?ids=$ids&fields=$fields&`$expand=links"
        $match   = $details.value | Select-Object -First 1
        if (-not $match) { return $null }
        $org     = $env:ADO_ORG_URL.TrimEnd('/')
        $proj    = $env:ADO_PROJECT
        return @{
            taskId   = [string]$match.id
            title    = [string]$match.fields.'System.Title'
            state    = [string]$match.fields.'System.State'
            appName  = [string]$match.fields.'Custom.AppName'
            teamName = [string]$match.fields.'Custom.TeamName'
            version  = [string]$match.fields.'Custom.Version'
            taskUrl  = "$org/$proj/_workitems/edit/$([string]$match.id)"
        }
    }
    catch {
        Write-Warning "Find-GlobalGATask failed for '$AppName': $_"
        return $null
    }
}

function Update-GATaskForConsolidation {
    <#
    .SYNOPSIS
        Merges a second team into an existing GA Task's Custom.TeamName (separator: /)
        and optionally updates Custom.Version if the new version differs.
    #>
    param(
        [Parameter(Mandatory)][string]$TaskId,
        [Parameter(Mandatory)][string]$NewTeamName,
        [string]$NewRequestId  = '',
        [string]$NewEpicId     = '',
        [string]$NewVersion    = ''
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $taskUrl = "$org/$project/_apis/wit/workitems/$TaskId"

    # Fetch current team name and version
    $currentTeam    = ''
    $currentVersion = ''
    try {
        $cur            = Invoke-AdoApi -Url "$taskUrl`?fields=Custom.TeamName,Custom.Version"
        $currentTeam    = [string]$cur.fields.'Custom.TeamName'
        $currentVersion = [string]$cur.fields.'Custom.Version'
    } catch { }

    # Merge team names with / separator — avoid duplicates
    $teams = @($currentTeam -split '[,;/]' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    if ($NewTeamName.Trim() -notin $teams) { $teams += $NewTeamName.Trim() }
    $mergedTeam = $teams -join '/'

    $comment = "Consolidated: also covers release request $NewRequestId"
    if ($NewEpicId) { $comment += " (Epic #$NewEpicId)" }

    $patchBody = [System.Collections.Generic.List[hashtable]]::new()
    $patchBody.Add(@{ op = 'replace'; path = '/fields/Custom.TeamName'; value = $mergedTeam })

    # Update version only if a new version is provided and differs from current
    $versionUpdated = $false
    if ($NewVersion -and $NewVersion -ne $currentVersion) {
        $patchBody.Add(@{ op = 'replace'; path = '/fields/Custom.Version'; value = $NewVersion })
        $comment += " | Version updated: $currentVersion → $NewVersion"
        $versionUpdated = $true
    }

    $patchBody.Add(@{ op = 'add'; path = '/fields/System.History'; value = $comment })

    $headers = Get-AdoHeaders
    $headers['Content-Type'] = 'application/json-patch+json'
    try {
        $result = Invoke-RestMethod -Method 'PATCH' -Uri "$taskUrl`?api-version=7.1" `
            -Headers $headers `
            -Body (ConvertTo-Json -InputObject $patchBody -Depth 10) `
            -ErrorAction Stop
        return @{
            success         = $true
            taskId          = [string]$result.id
            taskUrl         = $result._links.html.href
            mergedTeamName  = $mergedTeam
            versionUpdated  = $versionUpdated
            previousVersion = $currentVersion
        }
    }
    catch {
        $adoMsg = try { ($_.ErrorDetails.Message | ConvertFrom-Json).message } catch { $null }
        $errMsg = if ($adoMsg) { $adoMsg } else { $_.Exception.Message }
        Write-Warning "Update-GATaskForConsolidation failed (task $TaskId): $errMsg"
        return @{ success = $false; error = $errMsg }
    }
}

function Get-ExistingGATask {
    <#
    .SYNOPSIS
        Looks for an open Task under the given Epic where Custom.AppName matches.
        Returns @{ taskId, title, state } if found, otherwise $null.
        Filtered to the configured GA area path (ADO_CLOSURE_AREA_PATH, default 'BC GA').
    #>
    param(
        [Parameter(Mandatory)][string]$EpicId,
        [Parameter(Mandatory)][string]$AppName
    )

    $areaFilter = if ($env:ADO_CLOSURE_AREA_PATH) { $env:ADO_CLOSURE_AREA_PATH } else { 'Foodware 365 BC\CoE\BC GA' }
    $baseUrl    = Get-AdoBaseUrl

    # 1. Fetch the Epic's direct child relations
    $epicUrl = "$baseUrl/_apis/wit/workitems/$EpicId`?`$expand=relations"
    try {
        $epicWi = Invoke-AdoApi -Url $epicUrl
    } catch {
        Write-Warning "Get-ExistingGATask: failed to fetch Epic $EpicId`: $_"
        return $null
    }

    if (-not $epicWi.relations) { return $null }

    $childIds = @(
        $epicWi.relations |
            Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' } |
            ForEach-Object { $_.url -replace '^.+/(\d+)$', '$1' }
    )
    if ($childIds.Count -eq 0) { return $null }

    # 2. Batch-fetch child work items (cap at 200; epics rarely have more)
    $batchIds   = ($childIds | Select-Object -First 200) -join ','
    $fields     = "System.Id,System.WorkItemType,System.Title,System.State,System.AreaPath,Custom.AppName"
    $detailUrl  = "$baseUrl/_apis/wit/workitems?ids=$batchIds&fields=$fields"
    try {
        $details = Invoke-AdoApi -Url $detailUrl
    } catch {
        Write-Warning "Get-ExistingGATask: batch fetch failed: $_"
        return $null
    }

    # 3. Find first open Task under the GA area path whose AppName matches (case-insensitive)
    $match = $details.value | Where-Object {
        $f = $_.fields
        $f.'System.WorkItemType' -eq 'Task' -and
        $f.'System.State' -ne 'Closed' -and
        $f.'System.AreaPath' -like "*$areaFilter*" -and
        ([string]$f.'Custom.AppName').Trim() -ieq $AppName.Trim()
    } | Select-Object -First 1

    if (-not $match) { return $null }

    return @{
        taskId  = $match.id
        title   = $match.fields.'System.Title'
        state   = $match.fields.'System.State'
        appName = [string]$match.fields.'Custom.AppName'
    }
}

function Resolve-AdoUserIdentity {
    <#
    .SYNOPSIS
        Resolves an email/display name to the ADO providerDisplayName accepted by System.AssignedTo.
        Tries MailAddress filter first, then General filter with the display name.
        Returns $null if nothing is found so callers can fall back gracefully.
    #>
    param(
        [string]$Email       = '',
        [string]$DisplayName = ''
    )
    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $orgName = if ($org -match 'dev\.azure\.com/([^/]+)') { $Matches[1] } `
               elseif ($org -match '//([^.]+)\.visualstudio\.com') { $Matches[1] } `
               else { return $null }
    $hdrs = Get-AdoHeaders

    $hdrs['Accept'] = 'application/json'

    # Helper: call vssps identities API and return "DisplayName <uniqueName>" of first match
    function Invoke-IdentitySearch {
        param([string]$Filter, [string]$Value)
        if (-not $Value) { return $null }
        try {
            $url  = "https://vssps.dev.azure.com/$orgName/_apis/identities?searchFilter=$Filter&filterValue=$([uri]::EscapeDataString($Value))&api-version=7.1"
            $resp = Invoke-RestMethod -Uri $url -Headers $hdrs -ErrorAction Stop
            if ($resp.value -and $resp.value.Count -gt 0) {
                $identity = $resp.value[0]
                $dn = $identity.providerDisplayName
                # Account property holds the UPN/email — ADO requires "Name <email>" format
                $un = $identity.properties.Account.'$value'
                Write-Host "Resolve-AdoUserIdentity ($Filter='$Value'): dn='$dn' un='$un'"
                if ($dn -and $un) { return "$dn <$un>" }
                return $dn
            }
        }
        catch {
            Write-Warning "Resolve-AdoUserIdentity ($Filter='$Value'): $($_.Exception.Message)"
        }
        return $null
    }

    # 1. Try exact email match via MailAddress filter
    $result = Invoke-IdentitySearch -Filter 'MailAddress' -Value $Email
    if ($result) { return $result }

    # 2. Try broad General search with email (matches alias / UPN variants)
    $result = Invoke-IdentitySearch -Filter 'General' -Value $Email
    if ($result) { return $result }

    # 3. Try General search with display name
    $result = Invoke-IdentitySearch -Filter 'General' -Value $DisplayName
    if ($result) { return $result }

    return $null
}

function New-GATask {
    <#
    .SYNOPSIS
        Creates a Task work item under the specified Epic in ADO,
        populating "GA Release Work" tab fields.
    #>
    param(
        [string]$EpicId,
        [string]$Title,
        [string]$AppShortName,
        [string]$TeamName,
        [string]$ReleaseType,
        [string]$AssignedTo = '',
        [string]$AssignedToName = '',
        [string]$AppName = '',
        [string]$Version = '',
        [string]$Tags = '',
        [string]$ReleaseWiId = '',
        [string]$AreaPath = ''
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/wit/workitems/`$Task"

    $releaseLabel = if ($ReleaseType -eq 'feature') { 'Major' } else { 'Minor' }

    $resolvedAreaPath = if ($AreaPath) { $AreaPath } `
                        elseif ($env:ADO_CLOSURE_AREA_PATH) { $env:ADO_CLOSURE_AREA_PATH } `
                        else { 'Foodware 365 BC\CoE\BC GA' }

    $patchBody = [System.Collections.Generic.List[hashtable]]::new()
    $patchBody.Add(@{ op = 'add'; path = '/fields/System.Title'; value = $Title })

    # Area path — tasks must land in the BC GA area for Custom fields and WIQL searches to work
    if ($resolvedAreaPath) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/System.AreaPath'; value = $resolvedAreaPath })
    }

    # Assign — try vssps email lookup, then display-name lookup, then raw display name fallback
    if ($AssignedTo -or $AssignedToName) {
        $resolvedIdentity = $null
        if ($AssignedTo) {
            $resolvedIdentity = Resolve-AdoUserIdentity -Email $AssignedTo -DisplayName $AssignedToName
        }
        # Fall back to "Name <email>" ADO format when API resolution fails
        $assignValue = if ($resolvedIdentity) {
            $resolvedIdentity
        } elseif ($AssignedToName -and $AssignedTo) {
            "$AssignedToName <$AssignedTo>"
        } elseif ($AssignedTo) {
            $AssignedTo
        } elseif ($AssignedToName) {
            $AssignedToName
        } else {
            $null
        }
        if ($assignValue) {
            $patchBody.Add(@{ op = 'add'; path = '/fields/System.AssignedTo'; value = $assignValue })
        } else {
            Write-Warning "New-GATask: skipping AssignedTo — no identity resolved for '$AssignedTo'"
        }
    }

    # Add tags (e.g. "MAY; GA2026")
    if ($Tags) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/System.Tags'; value = $Tags })
    }

    # GA Release Work tab fields
    $gaAppName = if ($AppName) { $AppName } elseif ($AppShortName) { $AppShortName } else { '' }
    if ($gaAppName) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/Custom.AppName'; value = $gaAppName })
    }
    if ($TeamName) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/Custom.TeamName'; value = $TeamName })
    }
    if ($Version) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/Custom.Version'; value = $Version })
    }
    if ($ReleaseType) {
        $patchBody.Add(@{ op = 'add'; path = '/fields/Custom.ReleaseType'; value = $releaseLabel })
    }

    if ($ReleaseWiId) {
        # Child of the active Release work item; Related to the Epic
        $patchBody.Add(@{
            op    = 'add'
            path  = '/relations/-'
            value = @{
                rel        = 'System.LinkTypes.Hierarchy-Reverse'
                url        = "$org/_apis/wit/workItems/$ReleaseWiId"
                attributes = @{}
            }
        })
        $patchBody.Add(@{
            op    = 'add'
            path  = '/relations/-'
            value = @{
                rel        = 'System.LinkTypes.Related'
                url        = "$org/_apis/wit/workItems/$EpicId"
                attributes = @{}
            }
        })
    }
    else {
        # Fallback: child of Epic directly
        $patchBody.Add(@{
            op    = 'add'
            path  = '/relations/-'
            value = @{
                rel        = 'System.LinkTypes.Hierarchy-Reverse'
                url        = "$org/_apis/wit/workItems/$EpicId"
                attributes = @{}
            }
        })
    }

    $headers = Get-AdoHeaders
    # Work item PATCH requires 'application/json-patch+json'
    $headers['Content-Type'] = 'application/json-patch+json'
    # Use -InputObject to guarantee array serialization even for single-element lists
    $bodyJson = ConvertTo-Json -InputObject $patchBody -Depth 10

    try {
        $result = Invoke-RestMethod -Method 'PATCH' `
            -Uri "$url`?api-version=7.1" `
            -Headers $headers `
            -Body $bodyJson -ErrorAction Stop

        return @{
            success = $true
            taskId  = $result.id
            taskUrl = $result._links.html.href
        }
    }
    catch {
        # Capture the full ADO response body for actionable error messages
        $adoBody = $_.ErrorDetails.Message
        $adoMsg  = try { ($adoBody | ConvertFrom-Json).message } catch { $null }
        $errMsg  = if ($adoMsg) { $adoMsg } elseif ($adoBody) { $adoBody } else { $_.Exception.Message }
        Write-Warning "New-GATask failed: $errMsg"
        return @{
            success = $false
            error   = $errMsg
        }
    }
}

function Invoke-GAInitialProcess {
    <#
    .SYNOPSIS
        Runs the full GA-Initial process for a single app:
        1. Read app.json from main branch (current version)
        2. Calculate new version
        3. Update app.json version on source branch
        4. Update appsourcecop.json with stable tag version
        5. Commit all changes
        6. Create PR (source → target branch)
        7. Create ADO Task with GA Release Work fields
    #>
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$SourceBranch,
        [string]$TargetBranch,
        [string]$ReleaseType,
        [string]$EpicId,
        [string]$TeamName,
        [string]$OverrideVersion = '',
        [string]$OverrideAppSourceCopVersion = '',
        [hashtable]$TaskPreview = $null,
        [string]$InitiatorEmail = '',
        [string]$InitiatorName  = '',
        [string]$TargetMonth = '',
        [string]$ExistingTaskId = '',
        [string]$ReleaseWiId = ''
    )

    $log = [System.Collections.ArrayList]::new()
    $null = $log.Add("=== Processing $RepoName ===")

    # Step 1: Read app.json from MAIN branch (current version)
    $null = $log.Add("[INFO] Reading app.json from $RepoName (main)...")
    $appInfo = Get-AppInfoFromRepo -RepoId $RepoId -Branch 'main'

    if ($appInfo.error) {
        # Fallback: try source branch
        $null = $log.Add("[WARN] app.json not found on main, trying $SourceBranch...")
        $appInfo = Get-AppInfoFromRepo -RepoId $RepoId -Branch $SourceBranch
        if ($appInfo.error) {
            $null = $log.Add("[ERROR] $($appInfo.error)")
            return @{ success = $false; log = $log; error = $appInfo.error }
        }
    }

    $appShortName = $appInfo.appShortName
    $currentVersion = $appInfo.version
    $null = $log.Add("[INFO] App: $($appInfo.appName) | Short: $appShortName | Version: $currentVersion")

    # Hotfix flow: skip app.json version bump entirely. Only appsourcecop.json
    # gets touched on this run.
    $isHotfix = ($ReleaseType -eq 'hotfix')
    $fileChanges = @()

    if ($isHotfix) {
        $newVersion = $currentVersion
        $null = $log.Add("[INFO] Hotfix release — keeping app.json version $currentVersion (no bump)")
    }
    else {
        # Step 2: Calculate new version (use override if provided)
        if ($OverrideVersion) {
            $newVersion = $OverrideVersion
            $null = $log.Add("[INFO] Using override version: $newVersion")
        }
        else {
            $newVersion = New-VersionBump -CurrentVersion $currentVersion -ReleaseType $ReleaseType
        }
        $null = $log.Add("[SUCCESS] Version bump: $currentVersion → $newVersion")

        # Step 3: Update app.json content on source branch
        $sourceAppJsonContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appInfo.appJsonPath -Branch $SourceBranch
        if (-not $sourceAppJsonContent) {
            $sourceAppJsonContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appInfo.appJsonPath -Branch 'main'
        }
        # Extract actual version from source branch (may differ from main)
        $sourceVersion = if ($sourceAppJsonContent -match '"version"\s*:\s*"([^"]+)"') { $matches[1] } else { $currentVersion }
        $null = $log.Add("[INFO] Source branch version: $sourceVersion (main: $currentVersion)")
        $updatedAppJson = $sourceAppJsonContent -replace "(""version""\s*:\s*"")$([regex]::Escape($sourceVersion))("")", "`${1}$newVersion`${2}"
        $null = $log.Add("[INFO] Updated app.json version")

        $fileChanges += @{ path = $appInfo.appJsonPath; content = $updatedAppJson }
    }

    # Step 4: Update appsourcecop.json with stable tag version
    $appJsonDir = Split-Path $appInfo.appJsonPath -Parent
    $appSourceCopPath = if ($appJsonDir) { "$appJsonDir/appsourcecop.json" } else { 'appsourcecop.json' }
    $appSourceCopContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appSourceCopPath -Branch $SourceBranch
    if (-not $appSourceCopContent) {
        $appSourceCopContent = Get-FileFromRepo -RepoId $RepoId -FilePath $appSourceCopPath -Branch 'main'
    }

    $appSourceCopVersion = $OverrideAppSourceCopVersion
    if (-not $appSourceCopVersion) {
        # Get from latest stable tag
        $appSourceCopVersion = Get-StableTagVersion -RepoId $RepoId -Branch 'main'
    }

    if ($appSourceCopContent) {
        $updatedAppSourceCop = $appSourceCopContent
        if ($appSourceCopVersion -and $appSourceCopContent -match '"version"\s*:\s*"') {
            $updatedAppSourceCop = $appSourceCopContent -replace '("version"\s*:\s*")[^"]+(")', "`${1}$appSourceCopVersion`${2}"
            $null = $log.Add("[INFO] Updated appsourcecop.json version to $appSourceCopVersion (from stable tag)")
        }
        $fileChanges += @{ path = $appSourceCopPath; content = $updatedAppSourceCop }
    }
    else {
        $null = $log.Add("[WARN] appsourcecop.json not found — skipped")
    }

    # Step 5: Look for test app and update its version + dependency on main app
    # Skipped on hotfix — no version bump means no test app version update.
    $testAppContent = $null
    $testAppPath = $null

    if ($isHotfix) {
        $null = $log.Add("[INFO] Hotfix release — skipping test app version update")
    }
    else {

    # Derive test app paths from main app folder (e.g. WeighScale → WeighScaleTest, WeighScale/Test, etc.)
    $mainAppDir = if ($appInfo.appJsonPath -match '^(.+)/app\.json$') { $Matches[1] } else { '' }
    $testAppPaths = @('Test/app.json', 'TestApp/app.json', 'test/app.json')
    if ($mainAppDir) {
        # Add paths relative to the main app folder name: {MainApp}Test/app.json, {MainApp}/Test/app.json
        $testAppPaths = @(
            "${mainAppDir}Test/app.json"
            "${mainAppDir}/Test/app.json"
            "${mainAppDir}_Test/app.json"
        ) + $testAppPaths
    }

    foreach ($tp in $testAppPaths) {
        $content = Get-FileFromRepo -RepoId $RepoId -FilePath $tp -Branch $SourceBranch
        if ($content) {
            $testAppContent = $content
            $testAppPath = $tp
            $null = $log.Add("[INFO] Found test app at: $tp")
            break
        }
    }

    # Fallback: search repo items for any *test*/app.json
    if (-not $testAppContent) {
        try {
            $org2 = $env:ADO_ORG_URL.TrimEnd('/')
            $project2 = [uri]::EscapeDataString($env:ADO_PROJECT)
            $itemsUrl2 = "$org2/$project2/_apis/git/repositories/$RepoId/items?scopePath=/&recursionLevel=Full&versionDescriptor.version=$SourceBranch&versionDescriptor.versionType=branch"
            $items2 = Invoke-AdoApi -Url $itemsUrl2
            if ($items2.value) {
                $testItem = $items2.value | Where-Object {
                    $_.path -like '*/app.json' -and $_.path -match '(?i)test'
                } | Select-Object -First 1
                if ($testItem) {
                    $discoveredTestPath = $testItem.path.TrimStart('/')
                    $content = Get-FileFromRepo -RepoId $RepoId -FilePath $discoveredTestPath -Branch $SourceBranch
                    if ($content) {
                        $testAppContent = $content
                        $testAppPath = $discoveredTestPath
                        $null = $log.Add("[INFO] Discovered test app at: $discoveredTestPath")
                    }
                }
            }
        }
        catch {
            Write-Warning "Failed to search for test app: $($_.Exception.Message)"
        }
    }

    if ($testAppContent) {
        # Extract actual version from test app source (may differ from main)
        $testSourceVersion = if ($testAppContent -match '"version"\s*:\s*"([^"]+)"') { $matches[1] } else { $currentVersion }
        $null = $log.Add("[INFO] Test app source version: $testSourceVersion")
        # Update the test app's own version
        $updatedTestApp = $testAppContent -replace "(""version""\s*:\s*"")$([regex]::Escape($testSourceVersion))("")", "`${1}$newVersion`${2}"

        # Update dependency version referencing the main app (by ID or by name)
        $depUpdated = $false
        if ($appInfo.appId) {
            $mainAppIdEscaped = [regex]::Escape($appInfo.appId)
            if ($updatedTestApp -match $mainAppIdEscaped) {
                $updatedTestApp = $updatedTestApp -replace "(""id""\s*:\s*""$mainAppIdEscaped""[^}]*""version""\s*:\s*"")[^""]+("")", "`${1}$newVersion`${2}"
                $depUpdated = $true
            }
        }
        if (-not $depUpdated -and $appInfo.appName) {
            # Try matching by app name in dependencies
            $mainAppNameEscaped = [regex]::Escape($appInfo.appName)
            if ($updatedTestApp -match $mainAppNameEscaped) {
                $updatedTestApp = $updatedTestApp -replace "(""name""\s*:\s*""$mainAppNameEscaped""[^}]*""version""\s*:\s*"")[^""]+("")", "`${1}$newVersion`${2}"
                $depUpdated = $true
            }
        }

        if ($depUpdated) {
            $null = $log.Add("[INFO] Updated test app ($testAppPath) version and dependency to $newVersion")
        } else {
            $null = $log.Add("[INFO] Updated test app ($testAppPath) version to $newVersion (no matching dependency found)")
        }
        $fileChanges += @{ path = $testAppPath; content = $updatedTestApp }
    }
    else {
        $null = $log.Add("[INFO] No test app found — skipped")
    }

    }   # end if (-not $isHotfix) — test app block

    # Hotfix sanity: at least one file must be in $fileChanges, otherwise there
    # is nothing to commit.
    if ($isHotfix -and $fileChanges.Count -eq 0) {
        $null = $log.Add("[WARN] Hotfix — no appsourcecop.json found in repo; nothing to commit.")
        return @{ success = $false; log = $log; error = "Hotfix produced no file changes (no appsourcecop.json present)." }
    }

    # Step 6: Commit all changes
    $releaseLabel = if ($ReleaseType -eq 'feature') { 'Major' } elseif ($ReleaseType -eq 'hotfix') { 'Hotfix' } else { 'Minor' }
    $commitMsg = if ($isHotfix) {
        "AppSourceCop update (Hotfix) — $appShortName from BC GA team"
    } else {
        "v$newVersion $releaseLabel Release from BC GA team"
    }
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

    # Step 7: Create ADO Task with GA Release Work fields (before PR so we can link it)
    $taskAppName = if ($TaskPreview -and $TaskPreview.appName) { $TaskPreview.appName } else { $RepoName }
    $taskTeamName = if ($TaskPreview -and $TaskPreview.teamName) { $TaskPreview.teamName } else { $TeamName }
    $taskVersion = if ($TaskPreview -and $TaskPreview.version) { $TaskPreview.version } else { $newVersion }
    $taskReleaseType = $ReleaseType
    $taskTitle = if ($TaskPreview -and $TaskPreview.title) { $TaskPreview.title } else { Get-GATaskTitle -AppShortName $appShortName -ReleaseType $ReleaseType -TargetMonth $TargetMonth }

    # Build the two tags from target month.
    #   New format: "MAY GA2026" → tags "MAY; GA2026"
    #   Legacy:     "MAY-2026"   → tags "MAY; GA2026"  (year auto-prefixed with "GA")
    $taskTags = ''
    if ($TargetMonth) {
        $tm = $TargetMonth.Trim()
        $parts = $tm -split '[\s\-]+'
        if ($parts.Count -ge 2 -and $parts[0] -and $parts[1]) {
            $monthTag = $parts[0].ToUpper()
            $yearPart = $parts[1]
            # Normalize bare year (e.g. "2026") to "GA2026" — both formats end up identical
            if ($yearPart -match '^\d{4}$') { $yearPart = "GA$yearPart" }
            $taskTags = "$monthTag; $yearPart"
        }
    }

    # Use a pre-created task (from the two-phase UI) if provided; otherwise find or create
    $prWorkItemId = $EpicId
    if ($ExistingTaskId) {
        $null = $log.Add("[INFO] Using pre-created Task #$ExistingTaskId (supplied by UI)")
        $taskResult = @{ success = $true; taskId = $ExistingTaskId; taskUrl = ''; reused = $true }
        $prWorkItemId = $ExistingTaskId
    }
    else {
        # Check for an existing open GA Task under this Epic for the same app
        $null = $log.Add("[INFO] Checking for existing GA Task under Epic #$EpicId for app '$taskAppName'")
        $existingTask = Get-ExistingGATask -EpicId $EpicId -AppName $taskAppName

        if ($existingTask) {
            $null = $log.Add("[INFO] Found existing Task #$($existingTask.taskId) ('$($existingTask.title)', state: $($existingTask.state)) — reusing")
            $taskResult = @{ success = $true; taskId = $existingTask.taskId; taskUrl = ''; reused = $true }
            $prWorkItemId = $existingTask.taskId
        }
        else {
            $null = $log.Add("[INFO] No existing GA Task found — creating new Task under Epic #$EpicId")
            $taskResult = New-GATask -EpicId $EpicId -Title $taskTitle `
                -AppShortName $appShortName -TeamName $taskTeamName -ReleaseType $taskReleaseType `
                -AppName $taskAppName -Version $taskVersion `
                -AssignedTo $InitiatorEmail -Tags $taskTags -ReleaseWiId $ReleaseWiId `
                -AreaPath ($env:ADO_CLOSURE_AREA_PATH ?? '')

            if ($taskResult.success) {
                $null = $log.Add("[SUCCESS] Task #$($taskResult.taskId) created with GA Release Work fields")
                $prWorkItemId = $taskResult.taskId
            }
            else {
                $null = $log.Add("[WARN] Task creation failed: $($taskResult.error) — linking Epic to PR instead")
            }
        }
    }

    # Step 8: Create PR (linked to the created task, or epic as fallback)
    $null = $log.Add("[INFO] Creating PR: $SourceBranch → $TargetBranch (linked to work item #$prWorkItemId)")
    $prTitle = "v$newVersion $releaseLabel Release — $RepoName (GA-Initial)"
    $initiatorLabel = if ($InitiatorName) { "$InitiatorName ($InitiatorEmail)" } elseif ($InitiatorEmail) { $InitiatorEmail } else { 'GA Team' }
    $prDesc = "Automated GA-Initial process.`nApp: $($appInfo.appName) ($appShortName)`nVersion: $currentVersion → $newVersion`nRelease Type: $releaseLabel`nTeam: $TeamName`nInitiated by: $initiatorLabel"

    $prResult = New-AdoPullRequest -RepoId $RepoId -RepoName $RepoName `
        -SourceBranch $SourceBranch -TargetBranch $TargetBranch `
        -Title $prTitle -Description $prDesc -WorkItemId $prWorkItemId `
        -InitiatorEmail $InitiatorEmail -InitiatorName $InitiatorName

    if ($prResult.success) {
        $null = $log.Add("[SUCCESS] PR created: $($prResult.url)")
    }
    elseif ($prResult.exists) {
        $null = $log.Add("[WARN] PR already exists for this branch combination")
    }
    else {
        $null = $log.Add("[ERROR] PR creation failed: $($prResult.error)")
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

# ============================================
#  Rebase Tool Helpers
# ============================================

$script:RebaseIgnoredRepos = @(
    'Aptean.FB.DevOps', 'Aptean.Translations', 'FB-DataVerse-Integration',
    'FB-Translations', 'FB.Migration', 'FBConfiguration', 'FBBusinessInsights',
    'FBDataLake', 'FBDeliverySW', 'FBECommerce', 'FBField', 'FBMasterPlanning',
    'FBPowerAutomate', 'FBSRE', 'FBTranslation', 'FBWarehouseSW', 'ManualTests',
    'Aptean.Common', 'FB-BCOnPrem-DevOps', 'FB-DevOps', 'FB.Infrastructure',
    'FB.PrivateExtensions'
)

function Get-RebaseEligibleRepos {
    <#
    .SYNOPSIS
        Returns the list of repos eligible for a rebase scan, after filtering
        out the ignored repos. Each entry has id + name so the frontend can
        iterate and call Get-RebaseScanSingle per-repo (for progress display).
    #>
    $repos = Get-AdoRepositories
    return @(
        $repos | Where-Object { $script:RebaseIgnoredRepos -notcontains $_.name } |
            ForEach-Object { @{ id = $_.id; name = $_.name } }
    )
}

function Get-RebaseScanSingle {
    <#
    .SYNOPSIS
        Performs the main-vs-develop sync check on a single repo. Returns the
        same row shape used by Get-RebaseScanResults; returns $null if the
        repo doesn't have both main/master and develop refs, or if its develop
        branch has been inactive for more than $InactiveAfterDays days.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [string]$RepoName = '',
        [int]$InactiveAfterDays = 365
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    try {
        $refsUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=heads/"
        $refs = Invoke-AdoApi -Url $refsUrl
        $mainRef = $refs.value | Where-Object { $_.name -eq 'refs/heads/main' -or $_.name -eq 'refs/heads/master' } | Select-Object -First 1
        $devRef  = $refs.value | Where-Object { $_.name -eq 'refs/heads/develop' } | Select-Object -First 1

        if (-not $mainRef -or -not $devRef) { return $null }

        $mainCommit = $mainRef.objectId
        $devCommit  = $devRef.objectId

        # Activity filter: fetch the develop tip commit, drop repos whose latest
        # develop commit is older than $InactiveAfterDays.
        try {
            $commitUrl = "$org/$project/_apis/git/repositories/$RepoId/commits/$devCommit"
            $commit = Invoke-AdoApi -Url $commitUrl
            $lastDate = $null
            if ($commit.committer -and $commit.committer.date) { $lastDate = [datetime]$commit.committer.date }
            elseif ($commit.author -and $commit.author.date) { $lastDate = [datetime]$commit.author.date }
            if ($lastDate -and ((Get-Date) - $lastDate).TotalDays -gt $InactiveAfterDays) {
                Write-Host "Rebase scan: skipping '$RepoName' — develop inactive for $([int]((Get-Date) - $lastDate).TotalDays) days"
                return $null
            }
        } catch {
            # If we can't fetch the commit date, don't filter — better to over-include than miss
            Write-Warning "Rebase scan: activity check failed for $RepoName : $($_.Exception.Message)"
        }

        if ($mainCommit -eq $devCommit) {
            return @{
                id            = $RepoId
                name          = $RepoName
                mainCommit    = $mainCommit
                developCommit = $devCommit
                behindBy      = 0
            }
        }

        $diffUrl = "$org/$project/_apis/git/repositories/$RepoId/diffs/commits?baseVersion=$($devRef.name -replace 'refs/heads/','' )&targetVersion=$($mainRef.name -replace 'refs/heads/','' )"
        try {
            $diff = Invoke-AdoApi -Url $diffUrl
            $behindBy = $diff.behindCount
        } catch {
            $behindBy = 1
        }

        return @{
            id            = $RepoId
            name          = $RepoName
            mainCommit    = $mainCommit
            developCommit = $devCommit
            behindBy      = [int]$behindBy
        }
    }
    catch {
        Write-Warning "Skipping repo $RepoName : $_"
        return $null
    }
}

function Get-RebaseScanResults {
    <#
    .SYNOPSIS
        Legacy one-shot scan — kept so /api/ScanRebase still works for callers
        that don't want progress.  Internally just iterates the two new helpers.
    #>
    param([int]$DaysFilter = 30)

    $eligible = Get-RebaseEligibleRepos
    $results = @()
    foreach ($repo in $eligible) {
        $row = Get-RebaseScanSingle -RepoId $repo.id -RepoName $repo.name
        if ($row) { $results += $row }
    }
    return $results | Sort-Object { -$_.behindBy }, { $_.name }
}

function Invoke-RebaseRepo {
    param(
        [string]$RepoId,
        [string]$RepoName
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    # Use ADO merge API: create a merge of main into develop via cherry-pick / merge
    # We'll create a "merge" by updating the develop ref to point to a merge commit
    # The simplest server-side approach: create a PR from main to develop and auto-complete it

    try {
        # Check if there's already such a PR
        $prUrl = "$org/$project/_apis/git/repositories/$RepoId/pullrequests"
        $createPr = @{
            sourceRefName = 'refs/heads/main'
            targetRefName = 'refs/heads/develop'
            title         = 'Rebase: Merge main into develop'
            description   = 'Automated rebase via GA Release Portal'
        }
        $pr = Invoke-AdoApi -Method POST -Url $prUrl -Body $createPr

        # Auto-complete the PR
        $prId = $pr.pullRequestId
        $completePrUrl = "$org/$project/_apis/git/repositories/$RepoId/pullrequests/$prId"
        $completeBody = @{
            status           = 'completed'
            lastMergeSourceCommit = $pr.lastMergeSourceCommit
            completionOptions = @{
                mergeStrategy = 'noFastForward'
                deleteSourceBranch = $false
            }
        }
        $null = Invoke-AdoApi -Method PATCH -Url $completePrUrl -Body $completeBody

        return @{ repoId = $RepoId; name = $RepoName; success = $true }
    }
    catch {
        return @{ repoId = $RepoId; name = $RepoName; success = $false; error = $_.Exception.Message }
    }
}

# ============================================
#  Branch Management Helpers
# ============================================

function New-AdoBranch {
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$BranchName,
        [string]$SourceBranch = 'main'
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    try {
        # Get source branch commit
        $refsUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=heads/$SourceBranch"
        $refs = Invoke-AdoApi -Url $refsUrl
        $sourceRef = $refs.value | Select-Object -First 1
        if (-not $sourceRef) { throw "Source branch '$SourceBranch' not found" }

        $body = @(
            @{
                name        = "refs/heads/$BranchName"
                oldObjectId = '0000000000000000000000000000000000000000'
                newObjectId = $sourceRef.objectId
            }
        )

        $pushUrl = "$org/$project/_apis/git/repositories/$RepoId/refs"
        $null = Invoke-AdoApi -Method POST -Url $pushUrl -Body $body

        return @{ name = $RepoName; success = $true }
    }
    catch {
        return @{ name = $RepoName; success = $false; error = $_.Exception.Message }
    }
}

function Remove-AdoBranch {
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$BranchName
    )

    $protected = @('main', 'master', 'develop', 'development', 'uat', 'testing', 'production', 'release')
    if ($protected -contains $BranchName.ToLower()) {
        return @{ name = $RepoName; success = $false; error = "Cannot delete protected branch '$BranchName'" }
    }

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    try {
        # Get branch commit to delete
        $refsUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=heads/$BranchName"
        $refs = Invoke-AdoApi -Url $refsUrl
        $branchRef = $refs.value | Select-Object -First 1
        if (-not $branchRef) { throw "Branch '$BranchName' not found" }

        $body = @(
            @{
                name        = "refs/heads/$BranchName"
                oldObjectId = $branchRef.objectId
                newObjectId = '0000000000000000000000000000000000000000'
            }
        )

        $pushUrl = "$org/$project/_apis/git/repositories/$RepoId/refs"
        $null = Invoke-AdoApi -Method POST -Url $pushUrl -Body $body

        return @{ name = $RepoName; success = $true }
    }
    catch {
        return @{ name = $RepoName; success = $false; error = $_.Exception.Message }
    }
}

# ============================================
#  Task / Epic Closure Helpers
# ============================================

function Get-EpicTargetMonthMap {
    <#
    .SYNOPSIS
        One-shot scan of GAReleaseRequests storage to build a map of
        epicId -> targetMonth (e.g. 332992 -> 'MAY-2026'). Used so the
        closure modal can propose [YEAR, MONTH] tags per task.
    #>
    $map = @{}
    try {
        $ctx = Get-StorageContext
        $table = (Get-AzStorageTable -Name 'GAReleaseRequests' -Context $ctx -ErrorAction Stop).CloudTable
    } catch {
        return $map
    }

    $query = New-Object Microsoft.Azure.Cosmos.Table.TableQuery
    $rows = $table.ExecuteQuery($query)

    foreach ($row in $rows) {
        $epicsJson = $null
        if ($row.Properties.ContainsKey('epics')) {
            $epicsJson = $row.Properties['epics'].StringValue
        }
        $targetMonth = $null
        if ($row.Properties.ContainsKey('targetMonth')) {
            $targetMonth = $row.Properties['targetMonth'].StringValue
        }
        if (-not $epicsJson -or -not $targetMonth) { continue }

        try {
            $epics = $epicsJson | ConvertFrom-Json
            foreach ($e in $epics) {
                if ($e.epicNumber) {
                    $map["$($e.epicNumber)"] = $targetMonth
                }
            }
        } catch { continue }
    }
    return $map
}

function Get-ClosureTasks {
    <#
    .SYNOPSIS
        Returns child Tasks under the given Epic IDs (or auto-discovers GA-Validation
        epics if none are supplied), filtered by Area Path contains $AreaPathFilter.
    #>
    param(
        [string[]]$EpicIds,
        [string]$AreaPathFilter = ''
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT
    $areaFilter = if ($AreaPathFilter) { $AreaPathFilter } elseif ($env:ADO_CLOSURE_AREA_PATH) { $env:ADO_CLOSURE_AREA_PATH } else { 'BC GA' }

    # Auto-discover: if no Epic IDs were supplied, pull every Epic where
    #   Custom.FactoryStatus = '70 GA Validations'
    if (-not $EpicIds -or $EpicIds.Count -eq 0) {
        Write-Host "Get-ClosureTasks: auto-discovering GA-Validation epics"
        $epics = Get-AdoGAEpics
        $EpicIds = @($epics | ForEach-Object { [string]$_.id })
        if ($EpicIds.Count -eq 0) { return @() }
    }

    $tasks = @()
    # Build a map of epicId → targetMonth (e.g. 'MAY-2026') from request storage,
    # so we can attach a suggestedTags pair per task. One-shot scan, not per-task.
    $epicMonths = Get-EpicTargetMonthMap

    foreach ($epicId in $EpicIds) {
        try {
            # Get epic with relations
            $url = "$org/$project/_apis/wit/workitems/${epicId}?`$expand=relations"
            $epic = Invoke-AdoApi -Url $url

            if (-not $epic.relations) { continue }

            # Find child work items
            $childLinks = $epic.relations | Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' }
            foreach ($link in $childLinks) {
                $childId = $link.url -replace '.*/(\d+)$', '$1'
                try {
                    $childUrl = "$org/$project/_apis/wit/workitems/${childId}"
                    $child = Invoke-AdoApi -Url $childUrl
                    $fields = $child.fields

                    if ($fields.'System.WorkItemType' -ne 'Task') { continue }

                    # Skip already-closed tasks — closure subtab only cares about open work
                    if ($fields.'System.State' -eq 'Closed') { continue }

                    # Filter by area path — only tasks under the configured BC GA area
                    $areaPath = [string]$fields.'System.AreaPath'
                    if ($areaFilter -and ($areaPath -notmatch [regex]::Escape($areaFilter))) {
                        continue
                    }

                    # Parse ADO tags (semicolon-separated) into an array
                    $tagList = @()
                    if ($fields.'System.Tags') {
                        $tagList = @(
                            $fields.'System.Tags' -split ';' |
                                ForEach-Object { $_.Trim() } |
                                Where-Object { $_ }
                        )
                    }

                    # Look up the parent request's targetMonth (if any) → suggested tags
                    # Supports both new ("MAY GA2026") and legacy ("MAY-2026") formats.
                    $reqTargetMonth = $null
                    $suggestedTags  = @()
                    if ($epicMonths.ContainsKey("$epicId")) {
                        $reqTargetMonth = $epicMonths["$epicId"]
                        $tmParts = $reqTargetMonth -split '[\s\-]+'
                        if ($tmParts.Count -ge 2 -and $tmParts[0] -and $tmParts[1]) {
                            $monthPart = $tmParts[0].ToUpper()
                            $yearPart  = $tmParts[1]
                            if ($yearPart -match '^\d{4}$') { $yearPart = "GA$yearPart" }
                            $suggestedTags = @($monthPart, $yearPart)   # e.g. ['MAY','GA2026']
                        }
                    }

                    $tasks += @{
                        id            = $child.id
                        epicId        = [int]$epicId
                        title         = $fields.'System.Title'
                        state         = $fields.'System.State'
                        assignedTo    = $fields.'System.AssignedTo'.displayName
                        areaPath      = $areaPath
                        # Actual values (used as columns in the closure table)
                        appName       = [string]$fields.'Custom.AppName'
                        teamName      = [string]$fields.'Custom.TeamName'
                        version       = [string]$fields.'Custom.Version'
                        releaseType   = [string]$fields.'Custom.ReleaseType'
                        tags          = $tagList
                        # Hints carried into the Edit modal:
                        requestTargetMonth = $reqTargetMonth   # e.g. 'MAY-2026'
                        suggestedTags = $suggestedTags          # e.g. @('2026','MAY')
                    }
                }
                catch {
                    Write-Warning "Failed to read child $childId : $_"
                }
            }
        }
        catch {
            Write-Warning "Failed to read epic $epicId : $_"
        }
    }

    return $tasks
}

function Close-AdoWorkItem {
    param(
        [int]$WorkItemId,
        [string]$WorkItemType = 'Task'
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    try {
        $url = "$org/$project/_apis/wit/workitems/${WorkItemId}"
        $body = @(
            @{ op = 'add'; path = '/fields/System.State'; value = 'Closed' }
            @{ op = 'add'; path = '/fields/System.History'; value = "Closed via GA Release Portal ($WorkItemType closure)." }
        )

        $headers = Get-AdoHeaders
        $headers['Content-Type'] = 'application/json-patch+json'

        $separator = if ($url -match '\?') { '&' } else { '?' }
        $fullUrl = "${url}${separator}api-version=7.1"

        $null = Invoke-RestMethod -Method PATCH -Uri $fullUrl -Headers $headers `
            -Body ($body | ConvertTo-Json -Depth 5) -ContentType 'application/json-patch+json'

        return @{ id = $WorkItemId; success = $true }
    }
    catch {
        return @{ id = $WorkItemId; success = $false; error = $_.Exception.Message }
    }
}

# ============================================
#  Live Status Helpers
# ============================================

function Get-LiveStatusInfo {
    param(
        [string]$RepoId,
        [string]$RepoName
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    # 1. Get app.json version from main branch
    $appJsonVersion = $null
    try {
        $appInfo = Get-AppInfoFromRepo -RepoId $RepoId -Branch 'main'
        $appJsonVersion = $appInfo.version
    }
    catch {
        Write-Warning "Could not read app.json for $RepoName"
    }

    # 2. Get latest stable tag version
    $stableTagVersion = $null
    try {
        $stableTagVersion = Get-StableTagVersion -RepoId $RepoId
    }
    catch {
        Write-Warning "Could not get stable tag for $RepoName"
    }

    # 3. Scrape AppSource marketplace for published version
    $appSourceVersion = $null
    try {
        $appId = $null
        if ($appJsonVersion) {
            # Try reading the app ID from app.json
            try {
                $appJsonContent = Get-FileFromRepo -RepoId $RepoId -FilePath 'app.json' -Branch 'main'
                if (-not $appJsonContent) {
                    # Try subdirectory
                    $items = Invoke-AdoApi -Url "$org/$project/_apis/git/repositories/$RepoId/items?scopePath=/&recursionLevel=OneLevel&version=main"
                    $appDir = $items.value | Where-Object { $_.isFolder -and $_.path -ne '/' } | Select-Object -First 1
                    if ($appDir) {
                        $appJsonContent = Get-FileFromRepo -RepoId $RepoId -FilePath "$($appDir.path)/app.json" -Branch 'main'
                    }
                }
                if ($appJsonContent) {
                    $parsed = $appJsonContent | ConvertFrom-Json
                    $appId = $parsed.id
                }
            } catch { }
        }

        # Use marketplace search (limited — we look for the version in Aptean's publisher page)
        if ($appId) {
            $searchUrl = "https://appsource.microsoft.com/en-us/product/dynamics-365-business-central/PUBID.aptlogicinc%7CAID.$appId"
            try {
                $webResponse = Invoke-WebRequest -Uri $searchUrl -UseBasicParsing -TimeoutSec 15 -ErrorAction Stop
                $content = $webResponse.Content
                # Look for version pattern in the page
                if ($content -match '"version"\s*:\s*"(\d+\.\d+\.\d+\.\d+)"') {
                    $appSourceVersion = $Matches[1]
                }
            } catch {
                Write-Warning "Could not scrape AppSource for $RepoName"
            }
        }
    }
    catch {
        Write-Warning "AppSource check failed for $RepoName : $_"
    }

    # 4. Check if live tag already exists
    $liveTag = $null
    if ($stableTagVersion) {
        try {
            $tagFilter = "tags/live-$stableTagVersion"
            $tagsUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=$tagFilter"
            $tagRefs = Invoke-AdoApi -Url $tagsUrl
            if ($tagRefs.value -and $tagRefs.value.Count -gt 0) {
                $liveTag = "live-$stableTagVersion"
            }
        }
        catch { }
    }

    return @{
        repoId            = $RepoId
        repoName          = $RepoName
        appJsonVersion    = $appJsonVersion
        stableTagVersion  = $stableTagVersion
        appSourceVersion  = $appSourceVersion
        liveTag           = $liveTag
    }
}

function New-LiveTag {
    param(
        [string]$RepoId,
        [string]$RepoName,
        [string]$Version,
        [bool]$Notify = $false
    )

    $org     = $env:ADO_ORG_URL.TrimEnd('/')
    $project = $env:ADO_PROJECT

    # Get the stable tag's commit to base live tag on
    $tagName = "live-$Version"
    $stableFilter = "tags/stable-$Version"
    $tagsUrl = "$org/$project/_apis/git/repositories/$RepoId/refs?filter=$stableFilter"
    $stableRefs = Invoke-AdoApi -Url $tagsUrl
    $stableRef = $stableRefs.value | Select-Object -First 1
    if (-not $stableRef) {
        throw "Stable tag 'stable-$Version' not found in $RepoName"
    }

    # Create the live tag
    $body = @(
        @{
            name        = "refs/tags/$tagName"
            oldObjectId = '0000000000000000000000000000000000000000'
            newObjectId = $stableRef.objectId
        }
    )
    $pushUrl = "$org/$project/_apis/git/repositories/$RepoId/refs"
    $null = Invoke-AdoApi -Method POST -Url $pushUrl -Body $body

    # Send Teams notification if requested
    if ($Notify) {
        $webhookUrl = $env:POWER_AUTOMATE_WEBHOOK_URL
        if ($webhookUrl) {
            $notifyBody = @{
                repoName = $RepoName
                version  = $Version
                tagName  = $tagName
                message  = "$RepoName is now live on AppSource with version $Version"
            }
            try {
                Invoke-RestMethod -Method POST -Uri $webhookUrl `
                    -Body ($notifyBody | ConvertTo-Json -Depth 5) `
                    -ContentType 'application/json' -TimeoutSec 15
            }
            catch {
                Write-Warning "Teams notification failed: $_"
            }
        }
    }

    return @{ tagName = $tagName; success = $true }
}

# ============================================================
#  Translation validation (AL captions/labels/tooltips vs .xlf)
# ============================================================

function Get-RepoFiles {
    <#
    .SYNOPSIS
        Lists every file in a repo branch matching a glob-ish suffix
        (e.g. '.al', '.xlf'). Returns array of { path }.
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$Branch,
        [string[]]$Suffixes = @('.al')
    )

    $org = $env:ADO_ORG_URL.TrimEnd('/')
    $project = [uri]::EscapeDataString($env:ADO_PROJECT)
    $url = "$org/$project/_apis/git/repositories/$RepoId/items?scopePath=/&recursionLevel=Full&versionDescriptor.version=$Branch&versionDescriptor.versionType=branch&api-version=7.1"
    try {
        $items = Invoke-AdoApi -Url $url
    } catch {
        Write-Warning "Get-RepoFiles failed for $RepoId@${Branch}: $($_.Exception.Message)"
        return @()
    }
    if (-not $items.value) { return @() }

    $matches = @()
    foreach ($item in $items.value) {
        if ($item.gitObjectType -ne 'blob') { continue }
        $p = $item.path
        foreach ($sfx in $Suffixes) {
            if ($p.ToLower().EndsWith($sfx.ToLower())) {
                $matches += @{ path = $p.TrimStart('/') }
                break
            }
        }
    }
    return $matches
}

function Get-AlCaptionsFromText {
    <#
    .SYNOPSIS
        Extracts every Caption / ToolTip / Label declaration from an .al file's
        text. Returns array of { type, text, line } where text is the literal
        between the matching quotes.
    #>
    param([string]$Content)
    if (-not $Content) { return @() }

    $results = @()
    $lines = $Content -split "`r?`n"
    for ($i = 0; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        # Strip line comments (but keep doubled apostrophes inside strings working — we accept some imprecision here)
        $stripped = $line -replace '//.*$', ''

        # Caption = 'text';   ToolTip = 'text';
        if ($stripped -match "(?i)\b(Caption|ToolTip)\s*=\s*'((?:[^']|'')+)'") {
            $results += @{
                type = $Matches[1]
                text = ($Matches[2] -replace "''", "'")
                line = $i + 1
            }
        }
        # FieldName: Label 'text';        (variable / property declarations)
        if ($stripped -match "(?i):\s*Label\s+'((?:[^']|'')+)'") {
            $results += @{
                type = 'Label'
                text = ($Matches[1] -replace "''", "'")
                line = $i + 1
            }
        }
    }
    return $results
}

function Get-XlfSourceTexts {
    <#
    .SYNOPSIS
        Returns every <source> text contained in an XLIFF 1.2 .xlf file.
    #>
    param([string]$XlfContent)
    if (-not $XlfContent) { return @() }

    $sources = @()
    try {
        # Strip the XLIFF default namespace so simple XPath works without binding
        $clean = $XlfContent -replace '\sxmlns="[^"]+"', ''
        [xml]$xml = $clean
        $nodes = $xml.SelectNodes('//trans-unit/source')
        foreach ($n in $nodes) {
            $s = ($n.InnerText ?? '').Trim()
            if ($s) { $sources += $s }
        }
    } catch {
        # Fallback: regex if the file is malformed
        $regex = [regex]'<source[^>]*>([^<]*)</source>'
        foreach ($m in $regex.Matches($XlfContent)) {
            $s = $m.Groups[1].Value.Trim()
            if ($s) { $sources += $s }
        }
    }
    return ($sources | Select-Object -Unique)
}

function Test-RepoTranslationCoverage {
    <#
    .SYNOPSIS
        Compares captions/labels/tooltips in a repo's source branch against
        those already in main. New ones must be present in some .xlf file
        on the source branch — anything missing is reported.
    .OUTPUTS
        @{ missing = @[ {file, line, type, text} ]; appName = ''; checkedFiles = N; warnings = @() }
    #>
    param(
        [Parameter(Mandatory)][string]$RepoId,
        [Parameter(Mandatory)][string]$RepoName,
        [Parameter(Mandatory)][string]$SourceBranch,
        [string]$BaselineBranch = 'main',
        [int]$MaxAlFiles = 500
    )

    $missing = @()
    $warnings = @()

    # 1. Enumerate .al files in source branch (capped)
    $sourceFiles = Get-RepoFiles -RepoId $RepoId -Branch $SourceBranch -Suffixes @('.al')
    if ($sourceFiles.Count -eq 0) {
        $warnings += "No .al files found on $SourceBranch (or repo listing failed)"
        return @{ repoName = $RepoName; missing = @(); checkedFiles = 0; warnings = $warnings }
    }
    if ($sourceFiles.Count -gt $MaxAlFiles) {
        $warnings += "Repo has $($sourceFiles.Count) .al files; capped scan at $MaxAlFiles"
        $sourceFiles = $sourceFiles | Select-Object -First $MaxAlFiles
    }

    # 2. Build a hashset of texts that already exist in main (so we only flag new ones)
    $baselineTexts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($f in $sourceFiles) {
        $base = Get-FileFromRepo -RepoId $RepoId -FilePath $f.path -Branch $BaselineBranch
        if ($base) {
            foreach ($cap in (Get-AlCaptionsFromText -Content $base)) {
                [void]$baselineTexts.Add($cap.text)
            }
        }
    }

    # 3. Build a hashset of all <source> texts from every .xlf on source branch
    $xlfFiles = Get-RepoFiles -RepoId $RepoId -Branch $SourceBranch -Suffixes @('.xlf', '.xliff')
    $translatedTexts = New-Object 'System.Collections.Generic.HashSet[string]'
    foreach ($x in $xlfFiles) {
        $xc = Get-FileFromRepo -RepoId $RepoId -FilePath $x.path -Branch $SourceBranch
        if ($xc) {
            foreach ($s in (Get-XlfSourceTexts -XlfContent $xc)) {
                [void]$translatedTexts.Add($s)
            }
        }
    }

    if ($xlfFiles.Count -eq 0) {
        $warnings += "No .xlf translation files found on $SourceBranch"
    }

    # 4. For each .al file in source, find captions NEW vs main and check them against translations
    foreach ($f in $sourceFiles) {
        $src = Get-FileFromRepo -RepoId $RepoId -FilePath $f.path -Branch $SourceBranch
        if (-not $src) { continue }
        $caps = Get-AlCaptionsFromText -Content $src
        foreach ($cap in $caps) {
            if ($baselineTexts.Contains($cap.text)) { continue }   # already in main → not new
            if ($translatedTexts.Contains($cap.text)) { continue } # has translation entry → ok
            $missing += @{
                file = $f.path
                line = $cap.line
                type = $cap.type
                text = $cap.text
            }
        }
    }

    return @{
        repoName     = $RepoName
        missing      = $missing
        checkedFiles = $sourceFiles.Count
        warnings     = $warnings
    }
}

# ============================================================
#  Auto-derive app list from an Epic's PR-linked work items
# ============================================================
function Get-EpicAppsFromPRs {
    <#
    .SYNOPSIS
        Walks an Epic's full descendant tree (Features → Stories → Tasks/Bugs),
        extracts every linked PR via the work item's ArtifactLink relations,
        fetches each PR, and returns a deduplicated list of (repo, branch)
        pairs derived from the PRs' targetRefName. Skips active/abandoned PRs.

    .OUTPUTS
        @{
            apps     = @[ { repoId; repoName; sourceBranch } ]
            warnings = @[ string ]
            stats    = @{ descendantCount; prCount; completedPRCount }
        }
    #>
    param(
        [Parameter(Mandatory)][string]$EpicId,
        [int]$MaxPRs = 50
    )

    $org        = $env:ADO_ORG_URL.TrimEnd('/')
    $project    = $env:ADO_PROJECT
    $projectEnc = [uri]::EscapeDataString($project)
    $headers    = Get-AdoHeaders

    $warnings = @()

    # ---- 1) Recursive WIQL: every descendant under the Epic ----
    $wiql = "SELECT [System.Id] FROM WorkItemLinks " +
            "WHERE ([Source].[System.Id] = $EpicId) " +
            "AND ([System.Links.LinkType] = 'System.LinkTypes.Hierarchy-Forward') " +
            "MODE (Recursive)"
    try {
        $wiqlUrl = "$org/$projectEnc/_apis/wit/wiql?api-version=7.1"
        $jsonHeaders = $headers.Clone()
        $jsonHeaders['Content-Type'] = 'application/json'
        $wiqlResp = Invoke-RestMethod -Method POST -Uri $wiqlUrl -Headers $jsonHeaders `
                     -Body (@{ query = $wiql } | ConvertTo-Json) -ErrorAction Stop
    } catch {
        throw "Failed to query descendants for epic $EpicId : $($_.Exception.Message)"
    }

    # ---- Also fetch the Epic itself so we can return its GA Date field ----
    $epicGADate    = $null
    $epicAreaPath  = $null
    $epicTitle     = $null
    try {
        $epicUrl = "$org/$projectEnc/_apis/wit/workitems/${EpicId}?api-version=7.1"
        $epicResp = Invoke-RestMethod -Method GET -Uri $epicUrl -Headers $headers -ErrorAction Stop
        if ($epicResp.fields) {
            $epicTitle    = [string]$epicResp.fields.'System.Title'
            $epicAreaPath = [string]$epicResp.fields.'System.AreaPath'

            # Configurable: which custom field on the Epic holds the GA Date.
            # Defaults to the built-in Target Date field; override with ADO_EPIC_GA_DATE_FIELD.
            $gaDateField = $env:ADO_EPIC_GA_DATE_FIELD
            if (-not $gaDateField) { $gaDateField = 'Microsoft.VSTS.Scheduling.TargetDate' }

            $rawDate = $epicResp.fields.$gaDateField
            if ($rawDate) {
                # ADO usually returns ISO8601 with 'Z'. Keep raw + parsed parts.
                $epicGADate = [string]$rawDate
            }
        }
    } catch {
        $warnings += "Could not fetch Epic ${EpicId}: $($_.Exception.Message)"
    }

    if (-not $wiqlResp.workItemRelations) {
        return @{
            apps         = @()
            warnings     = $warnings + @('Epic has no descendant work items.')
            epicGADate   = $epicGADate
            epicTitle    = $epicTitle
            epicAreaPath = $epicAreaPath
            stats        = @{ descendantCount = 0; prCount = 0; completedPRCount = 0 }
        }
    }

    # Include the source Epic itself — PRs are sometimes linked directly to it.
    $descendantIds = @([int]$EpicId)
    foreach ($rel in $wiqlResp.workItemRelations) {
        if ($rel.target -and $rel.target.id) {
            $descendantIds += [int]$rel.target.id
        }
    }
    $descendantIds = $descendantIds | Select-Object -Unique
    Write-Host "Get-EpicAppsFromPRs: descendants (incl. source) = [$($descendantIds -join ',')]"
    if ($descendantIds.Count -eq 0) {
        return @{ apps = @(); warnings = @('Epic has no descendant work items.'); stats = @{ descendantCount = 0; prCount = 0; completedPRCount = 0 } }
    }

    # ---- 2) Batch-fetch the descendants with relations expanded ----
    # Using the POST `workitemsbatch` endpoint (recommended for $expand) — the
    # GET form with $expand in the query string returns 400 in some ADO
    # configurations.
    $prRefs = @{}     # key: "repoId|prId" → @{ repoId; prId }
    $artifactLinkCount = 0
    $unmatchedArtifactSamples = @()
    $batchSize = 200
    $batchHeaders = $headers.Clone()
    $batchHeaders['Content-Type'] = 'application/json'
    Write-Host "Get-EpicAppsFromPRs: walking $($descendantIds.Count) descendant(s) of epic $EpicId"

    for ($i = 0; $i -lt $descendantIds.Count; $i += $batchSize) {
        $end = [Math]::Min($i + $batchSize - 1, $descendantIds.Count - 1)
        # Hand-build the ids array as a strict int[] so ConvertTo-Json always
        # emits a JSON array (PowerShell collapses single-element arrays to a
        # scalar otherwise, and ADO 400s on `"ids": 373805`).
        [int[]]$batchSlice = @($descendantIds[$i..$end]) | ForEach-Object { [int]$_ }
        if ($batchSlice.Count -eq 0) { continue }

        $batchUrl = "$org/$projectEnc/_apis/wit/workitemsbatch?api-version=7.1"
        # Build the JSON manually for the same reason — ConvertTo-Json on a
        # 1-element [int[]] still loses the array wrapper through PSObject.
        $idsJson = '[' + (($batchSlice | ForEach-Object { $_.ToString() }) -join ',') + ']'
        $payloadJson = '{"ids":' + $idsJson + ',"$expand":"Relations"}'

        Write-Host "Get-EpicAppsFromPRs: batch $i payload: $payloadJson"

        try {
            $wiResp = Invoke-RestMethod -Method POST -Uri $batchUrl -Headers $batchHeaders `
                        -Body $payloadJson -ContentType 'application/json' -ErrorAction Stop
        } catch {
            $errBody = $null
            try { $errBody = $_.ErrorDetails.Message } catch {}
            Write-Host "Get-EpicAppsFromPRs: batch $i FAILED: $($_.Exception.Message) | body: $errBody"
            $warnings += "Batch $i failed: $($_.Exception.Message)$(if ($errBody) { " — $errBody" })"
            continue
        }

        foreach ($wi in @($wiResp.value)) {
            $wiType = [string]$wi.fields.'System.WorkItemType'
            $relCount = if ($wi.relations) { @($wi.relations).Count } else { 0 }
            Write-Host "  WI #$($wi.id) [$wiType]: $relCount relation(s)"
            if (-not $wi.relations) { continue }

            foreach ($r in $wi.relations) {
                # Log every relation so we can see what's actually attached
                $relName = ''
                if ($r.attributes -and $r.attributes.name) { $relName = [string]$r.attributes.name }
                Write-Host "      rel='$($r.rel)' name='$relName' url='$($r.url)'"

                # Capture every ArtifactLink (and similar) so we can log mismatches.
                # ADO PR links are 'ArtifactLink' with attributes.name = 'Pull Request',
                # but some integrations use 'GitHub Pull Request' or a custom rel.
                $isArtifact = $r.rel -eq 'ArtifactLink' -or $r.rel -like '*Pull Request*'
                if (-not $isArtifact) { continue }
                $artifactLinkCount++

                # Accept three URL shapes seen in the wild:
                #   vstfs:///Git/PullRequestId/<projGuid>/<repoGuid>/<prId>
                #   vstfs:///Git/PullRequestId/<projGuid>%2F<repoGuid>%2F<prId>     (URL-encoded)
                #   vstfs:///CodeReview/CodeReviewId/<projGuid>/<id>                (TFVC, no PRs in Git)
                $url = [string]$r.url
                $matched = $false
                if ($url -match '(?i)^vstfs:/+Git/PullRequestId/[^/]+/([^/]+)/(\d+)$') {
                    $repoId = $Matches[1]
                    $prId   = $Matches[2]
                    $matched = $true
                }
                elseif ($url -match '(?i)PullRequestId/[^/%]+(?:%2F|/)([^/%]+)(?:%2F|/)(\d+)') {
                    # Decoded segments — handles URL-encoded slashes inside vstfs URLs
                    $repoId = $Matches[1]
                    $prId   = $Matches[2]
                    $matched = $true
                }

                if ($matched) {
                    $key = "$repoId|$prId"
                    if (-not $prRefs.ContainsKey($key)) {
                        $prRefs[$key] = @{ repoId = $repoId; prId = [int]$prId }
                    }
                }
                elseif ($unmatchedArtifactSamples.Count -lt 5) {
                    $unmatchedArtifactSamples += "$($r.rel) | $url"
                }
            }
        }
    }

    Write-Host "Get-EpicAppsFromPRs: scanned $artifactLinkCount artifact link(s); matched $($prRefs.Count) PR(s)"
    if ($unmatchedArtifactSamples.Count -gt 0) {
        Write-Host "Get-EpicAppsFromPRs: unmatched artifact-link samples (first 5):"
        foreach ($s in $unmatchedArtifactSamples) { Write-Host "    $s" }
        $warnings += "Encountered $($artifactLinkCount - $prRefs.Count) artifact link(s) we couldn't parse — see Function logs."
    }

    # ---- 2b) Fallback: scan all repos' completed PRs for workItemRefs that match
    # any of our descendants. This handles the (very common) case where PRs are
    # linked via commit messages or PR description AB#-refs, which don't surface
    # as relations on the work item itself.
    if ($prRefs.Count -eq 0) {
        Write-Host "Get-EpicAppsFromPRs: no work-item-side relations found — running repo PR-scan fallback"
        $repos = @()
        try {
            $repos = @(Get-AdoRepositories)
        } catch {
            $warnings += "Repo listing for PR scan failed: $($_.Exception.Message)"
        }

        if (@($repos).Count -gt 0) {
            $descendantSet = New-Object 'System.Collections.Generic.HashSet[int]'
            foreach ($d in $descendantIds) { [void]$descendantSet.Add([int]$d) }

            Write-Host "Get-EpicAppsFromPRs: scanning $(@($repos).Count) repo(s) for completed PRs"
            $reposScanned = 0
            $prsChecked   = 0

            foreach ($repo in @($repos)) {
                $reposScanned++
                $repoId   = [string]$repo.id
                $repoName = [string]$repo.name
                $prsUrl = "$org/$projectEnc/_apis/git/repositories/$repoId/pullrequests?searchCriteria.status=completed&`$top=100&api-version=7.1"
                try {
                    $prsResp = Invoke-RestMethod -Method GET -Uri $prsUrl -Headers $headers -ErrorAction Stop
                } catch {
                    continue
                }
                foreach ($pr in @($prsResp.value)) {
                    $prsChecked++
                    # Fetch the PR's associated work items (covers PR description + commit-message links)
                    $wiUrl2 = "$org/$projectEnc/_apis/git/repositories/$repoId/pullrequests/$($pr.pullRequestId)/workitems?api-version=7.1"
                    try {
                        $wiResp2 = Invoke-RestMethod -Method GET -Uri $wiUrl2 -Headers $headers -ErrorAction Stop
                    } catch {
                        continue
                    }

                    $matched = $false
                    foreach ($wi in @($wiResp2.value)) {
                        if ($descendantSet.Contains([int]$wi.id)) { $matched = $true; break }
                    }
                    if ($matched) {
                        $key = "$repoId|$($pr.pullRequestId)"
                        if (-not $prRefs.ContainsKey($key)) {
                            $prRefs[$key] = @{ repoId = $repoId; prId = [int]$pr.pullRequestId }
                            Write-Host "  Fallback match: PR #$($pr.pullRequestId) in '$repoName'"
                        }
                    }
                }
            }
            Write-Host "Get-EpicAppsFromPRs: repo PR-scan checked $prsChecked PR(s) across $reposScanned repo(s); matched $($prRefs.Count) total"
        }
    }

    if ($prRefs.Count -eq 0) {
        return @{
            apps         = @()
            warnings     = $warnings + @('No pull requests linked to this epic''s descendants.')
            epicGADate   = $epicGADate
            epicTitle    = $epicTitle
            epicAreaPath = $epicAreaPath
            stats        = @{ descendantCount = $descendantIds.Count; prCount = 0; completedPRCount = 0 }
        }
    }

    # ---- 3) Cap PR count + fetch each PR's details ----
    $allPRs = @($prRefs.Values)
    $totalFound = $allPRs.Count
    if ($totalFound -gt $MaxPRs) {
        $warnings += "Found $totalFound PRs; processing first $MaxPRs. Use Add App to add more manually."
        $allPRs = $allPRs | Select-Object -First $MaxPRs
    }

    $apps = @{}                    # key: "repoId|targetBranch" → app entry
    $completedCount = 0

    $statusBreakdown = @{ completed = 0; active = 0; abandoned = 0; other = 0 }
    foreach ($pr in $allPRs) {
        try {
            $prUrl = "$org/$projectEnc/_apis/git/repositories/$($pr.repoId)/pullrequests/$($pr.prId)?api-version=7.1"
            $prDetail = Invoke-RestMethod -Method GET -Uri $prUrl -Headers $headers -ErrorAction Stop
        } catch {
            $warnings += "PR #$($pr.prId) in repo $($pr.repoId): $($_.Exception.Message)"
            Write-Host "  PR #$($pr.prId): fetch failed - $($_.Exception.Message)"
            continue
        }

        $st       = [string]$prDetail.status
        $repoNm   = [string]$prDetail.repository.name
        $tgtRef   = [string]$prDetail.targetRefName
        Write-Host "  PR #$($pr.prId): status='$st' repo='$repoNm' target='$tgtRef'"

        if ($statusBreakdown.ContainsKey($st)) { $statusBreakdown[$st]++ } else { $statusBreakdown['other']++ }

        if ($st -ne 'completed') { continue }   # skip active/abandoned
        $completedCount++

        $repoId       = [string]$prDetail.repository.id
        $repoName     = [string]$prDetail.repository.name
        $targetBranch = [string]$prDetail.targetRefName -replace '^refs/heads/', ''

        if (-not $repoId -or -not $targetBranch) { continue }

        $key = "$repoId|$targetBranch"
        if (-not $apps.ContainsKey($key)) {
            $apps[$key] = @{
                repoId       = $repoId
                repoName     = $repoName
                sourceBranch = $targetBranch
            }
        }
    }

    Write-Host "Get-EpicAppsFromPRs: PR status breakdown — completed=$($statusBreakdown.completed) active=$($statusBreakdown.active) abandoned=$($statusBreakdown.abandoned) other=$($statusBreakdown.other)"
    Write-Host "Get-EpicAppsFromPRs: built $(@($apps.Values).Count) unique app row(s) from $completedCount completed PR(s)"

    # If we found PRs but none are completed, surface that as a warning so the
    # operator sees it in the toast (rather than the generic "no apps" message).
    if ($completedCount -eq 0 -and ($statusBreakdown.active -gt 0 -or $statusBreakdown.abandoned -gt 0)) {
        $warnings += "Found $($statusBreakdown.active) active and $($statusBreakdown.abandoned) abandoned PR(s) but no completed (merged) ones. Auto-fill only uses completed PRs."
    }

    return @{
        apps         = @($apps.Values)
        warnings     = $warnings
        epicGADate   = $epicGADate
        epicTitle    = $epicTitle
        epicAreaPath = $epicAreaPath
        stats        = @{
            descendantCount  = $descendantIds.Count
            prCount          = $totalFound
            completedPRCount = $completedCount
            statusBreakdown  = $statusBreakdown
        }
    }
}

# ─── Active Release Config (GAConfig table) ──────────────────────────────────

function Get-ConfigTable {
    $ctx = Get-StorageContext
    $tableName = 'GAConfig'
    $null = New-AzStorageTable -Name $tableName -Context $ctx -ErrorAction SilentlyContinue
    return (Get-AzStorageTable -Name $tableName -Context $ctx).CloudTable
}

function Get-ActiveReleaseConfig {
    try {
        $table = Get-ConfigTable
    } catch { return $null }

    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve('config', 'activeRelease')
    $result = $table.Execute($op)
    if (-not $result.Result) { return $null }

    $entity = $result.Result
    return @{
        id    = $entity.Properties['releaseId'].StringValue
        title = $entity.Properties['releaseTitle'].StringValue
    }
}

function Save-ActiveReleaseConfig {
    param(
        [string]$Id,
        [string]$Title
    )

    $table = Get-ConfigTable
    $entity = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $entity.PartitionKey = 'config'
    $entity.RowKey = 'activeRelease'
    $entity.Properties['releaseId']    = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($Id)
    $entity.Properties['releaseTitle'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($Title)

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
    return $true
}

function Clear-ActiveReleaseConfig {
    try {
        $table = Get-ConfigTable
    } catch { return $false }

    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve('config', 'activeRelease')
    $result = $table.Execute($op)
    if (-not $result.Result) { return $true }   # already gone

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Delete($result.Result))
    return $true
}

# ─── Task Parent WI Config (GAConfig table, RowKey=taskParentWi) ──────────────
# Separate from Active Release — this WI is used as the parent for GA tasks
# created during GA-Initial. Changes every release month.

function Get-TaskParentWiConfig {
    try {
        $table = Get-ConfigTable
    } catch { return $null }

    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve('config', 'taskParentWi')
    $result = $table.Execute($op)
    if (-not $result.Result) { return $null }

    $entity = $result.Result
    return @{
        id    = $entity.Properties['wiId'].StringValue
        title = $entity.Properties['wiTitle'].StringValue
    }
}

function Save-TaskParentWiConfig {
    param([string]$Id, [string]$Title)

    $table  = Get-ConfigTable
    $entity = New-Object Microsoft.Azure.Cosmos.Table.DynamicTableEntity
    $entity.PartitionKey = 'config'
    $entity.RowKey       = 'taskParentWi'
    $entity.Properties['wiId']    = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($Id)
    $entity.Properties['wiTitle'] = [Microsoft.Azure.Cosmos.Table.EntityProperty]::GeneratePropertyForString($Title)

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::InsertOrReplace($entity))
    return $true
}

function Clear-TaskParentWiConfig {
    try {
        $table = Get-ConfigTable
    } catch { return $false }

    $op = [Microsoft.Azure.Cosmos.Table.TableOperation]::Retrieve('config', 'taskParentWi')
    $result = $table.Execute($op)
    if (-not $result.Result) { return $true }

    $null = $table.Execute([Microsoft.Azure.Cosmos.Table.TableOperation]::Delete($result.Result))
    return $true
}

function Get-EpicsFromRelease {
    <#
    .SYNOPSIS
        Returns all child Epics of the given Release work item that have
        Factory Status "70 GA Validation".
    #>
    param([Parameter(Mandatory)][string]$ReleaseId)

    $statusField = if ($env:ADO_GA_STATUS_FIELD) { $env:ADO_GA_STATUS_FIELD } else { 'Custom.FactoryStatus' }
    $statusValue = if ($env:ADO_GA_STATUS_VALUE)  { $env:ADO_GA_STATUS_VALUE  } else { '70 GA Validations' }

    $baseUrl = Get-AdoBaseUrl

    # 1. Fetch the Release WI with its child relations
    $releaseUrl = "$baseUrl/_apis/wit/workitems/$ReleaseId`?`$expand=relations"
    $releaseWi  = Invoke-AdoApi -Url $releaseUrl

    if (-not $releaseWi) {
        throw "Release work item $ReleaseId not found"
    }

    # 2. Extract child IDs (Hierarchy-Forward = parent→child)
    $childIds = @()
    if ($releaseWi.relations) {
        $childIds = $releaseWi.relations |
            Where-Object { $_.rel -eq 'System.LinkTypes.Hierarchy-Forward' } |
            ForEach-Object {
                # URL format: .../workItems/12345
                $_.url -replace '^.+/(\d+)$', '$1'
            }
    }

    if ($childIds.Count -eq 0) { return @() }

    # 3. Batch-fetch child details (max 200 per call; most releases have far fewer children)
    $batchIds   = ($childIds | Select-Object -First 200) -join ','
    $fields     = "System.Id,System.WorkItemType,System.Title,System.AreaPath,$statusField"
    $detailUrl  = "$baseUrl/_apis/wit/workitems?ids=$batchIds&fields=$fields"
    $details    = Invoke-AdoApi -Url $detailUrl

    # 4. Filter: type=Epic AND correct factory status
    return $details.value |
        Where-Object {
            $_.fields.'System.WorkItemType' -eq 'Epic' -and
            $_.fields.$statusField -eq $statusValue
        } |
        ForEach-Object {
            @{
                id       = $_.id
                title    = $_.fields.'System.Title'
                areaPath = $_.fields.'System.AreaPath'
            }
        }
}

Export-ModuleMember -Function *
