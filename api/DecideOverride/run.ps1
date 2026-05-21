using namespace System.Net

param($Request, $TriggerMetadata)


$id       = $Request.Query.id
$decision = $Request.Query.decision
$token    = $Request.Query.token

function Send-HtmlPage {
    param(
        [int]$StatusCode = 200,
        [string]$Title = 'GA Override',
        [string]$Heading,
        [string]$Detail,
        [string]$Color = '#0078d4'
    )
    $html = @"
<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><title>$Title</title>
<style>
body{font-family:'Segoe UI',sans-serif;background:#f3f4f6;display:flex;align-items:center;justify-content:center;min-height:100vh;margin:0}
.card{background:#fff;border-radius:8px;box-shadow:0 4px 12px rgba(0,0,0,.1);padding:32px 40px;max-width:520px;text-align:center}
h1{color:$Color;margin:0 0 12px;font-size:24px}
p{color:#444;line-height:1.5;margin:8px 0}
.id{font-family:Consolas,monospace;color:#666;font-size:13px;margin-top:16px}
</style></head><body>
<div class="card"><h1>$Heading</h1><p>$Detail</p>$(if ($id) { "<p class='id'>Override ID: $id</p>" })</div>
</body></html>
"@
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = $StatusCode
        Headers    = @{ 'Content-Type' = 'text/html; charset=utf-8' }
        Body       = $html
    })
}

if (-not $id -or -not $decision -or -not $token) {
    Send-HtmlPage -StatusCode 400 -Heading 'Invalid Link' -Detail 'Missing id, decision, or token.' -Color '#d13438'
    return
}

if ($decision -notin @('approve', 'reject')) {
    Send-HtmlPage -StatusCode 400 -Heading 'Invalid Decision' -Detail 'Decision must be approve or reject.' -Color '#d13438'
    return
}

if (-not (Test-OverrideHmacToken -Id $id -Decision $decision -Token $token)) {
    Send-HtmlPage -StatusCode 401 -Heading 'Invalid or Expired Link' -Detail 'The signature on this approval link could not be verified.' -Color '#d13438'
    return
}

$existing = Get-OverrideRequest -Id $id
if (-not $existing) {
    Send-HtmlPage -StatusCode 404 -Heading 'Not Found' -Detail "Override request $id was not found." -Color '#d13438'
    return
}

if ($existing.status -ne 'pending') {
    $when = if ($existing.decidedAt) { [datetime]::Parse($existing.decidedAt).ToString('yyyy-MM-dd HH:mm UTC') } else { 'previously' }
    Send-HtmlPage -Heading 'Already Decided' `
        -Detail "This override was already $($existing.status) $when." `
        -Color '#605e5c'
    return
}

$newStatus = if ($decision -eq 'approve') { 'approved' } else { 'rejected' }
$updated = Update-OverrideStatus -Id $id -Status $newStatus

if (-not $updated) {
    Send-HtmlPage -StatusCode 500 -Heading 'Error' -Detail 'Failed to record decision. Please try again.' -Color '#d13438'
    return
}

if ($newStatus -eq 'approved') {
    Send-HtmlPage `
        -Heading '✅ Override Approved' `
        -Detail "$($existing.submitterEmail) can now submit the late request for $($existing.targetMonth)." `
        -Color '#107c10'
} else {
    Send-HtmlPage `
        -Heading '❌ Override Rejected' `
        -Detail "$($existing.submitterEmail) has been notified that the late request for $($existing.targetMonth) was rejected." `
        -Color '#d13438'
}
