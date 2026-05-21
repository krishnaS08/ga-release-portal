using namespace System.Net

param($Request, $TriggerMetadata)

# Backend proxy for people search.
#
# Strategy:
#   1) If the caller forwards an MSAL-acquired Graph token via the Authorization
#      header (Bearer …), use it to call Microsoft Graph /users with $filter.
#      This is what the SPA does — no CSP/CORS hassle because the browser only
#      talks to /api/SearchUsers (same origin).
#   2) Fallback for headless callers / tests: query Azure DevOps User
#      Entitlements with the server-side PAT (the original behaviour).


# --- Pull query and bearer token from request ---
$query = $null
if ($Request.Query.q) { $query = $Request.Query.q }
elseif ($Request.Body -and $Request.Body.q) { $query = $Request.Body.q }

if (-not $query -or [string]$query.Length -lt 2) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = '[]'
    })
    return
}

$bearer = $null
if ($Request.Headers -and $Request.Headers['Authorization']) {
    $auth = [string]$Request.Headers['Authorization']
    if ($auth.StartsWith('Bearer ', [StringComparison]::OrdinalIgnoreCase)) {
        $bearer = $auth.Substring(7).Trim()
    }
}

# --- Route 1: Microsoft Graph (delegated token forwarded by the SPA) ---
if ($bearer) {
    try {
        $q = $query -replace "'", "''"   # OData escapes single quotes
        $filter = "startswith(displayName,'$q') or startswith(givenName,'$q') or startswith(surname,'$q') or startswith(mail,'$q') or startswith(userPrincipalName,'$q')"
        $url = 'https://graph.microsoft.com/v1.0/users' +
               '?$filter=' + [uri]::EscapeDataString($filter) +
               '&$count=true' +
               '&$top=25' +
               '&$select=displayName,mail,userPrincipalName'

        $headers = @{
            'Authorization'    = "Bearer $bearer"
            'ConsistencyLevel' = 'eventual'
        }

        $resp = Invoke-RestMethod -Method GET -Uri $url -Headers $headers -ErrorAction Stop

        $users = @()
        foreach ($u in @($resp.value)) {
            $email = $u.mail
            if (-not $email) { $email = $u.userPrincipalName }
            if ($email) {
                $users += @{
                    name  = [string]$u.displayName
                    email = ([string]$email).ToLower()
                }
            }
        }

        Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
            StatusCode = [HttpStatusCode]::OK
            Headers    = @{ 'Content-Type' = 'application/json' }
            Body       = ($users | ConvertTo-Json -Depth 3 -AsArray)
        })
        return
    }
    catch {
        $errMsg = $_.Exception.Message
        $errBody = $null
        try { $errBody = $_.ErrorDetails.Message } catch {}
        Write-Warning "SearchUsers (Graph) failed, falling back to ADO: $errMsg $errBody"
        # fall through to ADO
    }
}

# --- Route 2: Azure DevOps User Entitlements (PAT-based fallback) ---
try {
    $org = $env:ADO_ORG_URL.TrimEnd('/')
    if ($org -match 'dev\.azure\.com/([^/]+)') { $orgName = $matches[1] }
    elseif ($org -match '(https?://)([^.]+)\.visualstudio\.com') { $orgName = $matches[2] }
    else { $orgName = $org -replace '.*/(.*)$', '$1' }

    $pat = $env:ADO_PAT
    $base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    $headers = @{
        'Authorization' = "Basic $base64Auth"
        'Content-Type'  = 'application/json'
    }
    $filter = [uri]::EscapeDataString("name co '$query' or email co '$query'")
    $url = "https://vsaex.dev.azure.com/$orgName/_apis/userentitlements?`$filter=$filter&`$top=15&api-version=7.1-preview.3"

    $result = Invoke-RestMethod -Uri $url -Headers $headers -Method GET -ErrorAction Stop

    $users = @()
    foreach ($member in $result.members) {
        $u = $member.user
        if ($u.mailAddress -and $u.mailAddress -like '*@aptean.com') {
            $users += @{
                name  = $u.displayName
                email = $u.mailAddress.ToLower()
            }
        }
    }
    $users = $users | Sort-Object { $_.name } | Select-Object -Unique -Property name, email

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = ($users | ConvertTo-Json -Depth 3 -AsArray)
    })
}
catch {
    Write-Error "SearchUsers (ADO fallback) failed: $($_.Exception.Message)"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Headers    = @{ 'Content-Type' = 'application/json' }
        Body       = (@{ error = $_.Exception.Message } | ConvertTo-Json)
    })
}
