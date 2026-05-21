using namespace System.Net

param($Request, $TriggerMetadata)


try {
    $body = $Request.Body
    $requestId = $body.requestId
    $missing   = $body.missing

    if (-not $requestId) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ error = 'requestId is required' } | ConvertTo-Json)
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

    $submitter = $request.submitterEmail
    if (-not $submitter) {
        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::BadRequest
            Body       = (@{ error = 'Submitter email not found on request' } | ConvertTo-Json)
            Headers    = @{ 'Content-Type' = 'application/json' }
        })
        return
    }

    # Group missing entries by app for the email body
    $byApp = @{}
    foreach ($m in $missing) {
        $key = $m.appName
        if (-not $byApp.ContainsKey($key)) { $byApp[$key] = @() }
        $byApp[$key] += $m
    }

    $rows = ''
    foreach ($app in $byApp.Keys | Sort-Object) {
        $rows += "<tr><td colspan='4' style='background:#f1f5f9;padding:8px;font-weight:600;'>$app</td></tr>"
        foreach ($item in $byApp[$app]) {
            $rows += "<tr>"
            $rows += "<td style='padding:6px 8px;font-family:Consolas,monospace;font-size:12px;'>$($item.file):$($item.line)</td>"
            $rows += "<td style='padding:6px 8px;'>$($item.type)</td>"
            $rows += "<td style='padding:6px 8px;'>$($item.text)</td>"
            $rows += "</tr>"
        }
    }

    $countMissing = ($missing | Measure-Object).Count
    $subject = "Action required: missing translations block GA for request $requestId"
    $html = @"
<!DOCTYPE html>
<html><body style="font-family:'Segoe UI',sans-serif;color:#1e293b;max-width:720px;margin:0 auto;padding:20px;">
  <div style="background:linear-gradient(135deg,#dc2626 0%,#b91c1c 100%);padding:18px 24px;border-radius:8px 8px 0 0;color:#fff;">
    <h1 style="margin:0;font-size:20px;">⚠ Translation validation failed</h1>
  </div>
  <div style="border:1px solid #e5e7eb;border-top:none;border-radius:0 0 8px 8px;padding:20px 24px;">
    <p>Hi,</p>
    <p>Your GA release request <strong>$requestId</strong> ($($request.teamName), $($request.releaseType))
       could not be promoted because <strong>$countMissing</strong> caption / label / tooltip change(s)
       in your source branch have no entry in the translation files.</p>
    <p>Please add the missing texts to your <code>.xlf</code> files (or remove them from the source if not intended)
       and ask the GA team to re-run the GA process.</p>

    <table style="width:100%;border-collapse:collapse;font-size:13px;margin-top:16px;border:1px solid #e5e7eb;">
      <thead>
        <tr style="background:#1e293b;color:#fff;">
          <th style="padding:8px;text-align:left;">File : Line</th>
          <th style="padding:8px;text-align:left;">Type</th>
          <th style="padding:8px;text-align:left;">Text</th>
        </tr>
      </thead>
      <tbody>$rows</tbody>
    </table>

    <p style="color:#64748b;font-size:12px;margin-top:20px;">
      This email was sent automatically by the GA Release Portal. Please respond to the GA team once translations are added.
    </p>
  </div>
</body></html>
"@

    $sent = Send-NotificationEmail -To $submitter -Subject $subject -HtmlBody $html -From 'ga-release-portal@aptean.com'

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{
            requestId   = $requestId
            notified    = $sent
            recipient   = $submitter
            count       = $countMissing
        } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Error "NotifyMissingTranslations failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
