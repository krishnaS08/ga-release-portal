using namespace System.Net

param($Request, $TriggerMetadata)


$org = $env:ADO_ORG_URL        # https://schouw.visualstudio.com
$project = $env:ADO_PROJECT    # Foodware 365 BC
$pat = $env:ADO_PAT

if (-not $org -or -not $project -or -not $pat) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = "ADO configuration missing" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$encodedProject = [Uri]::EscapeDataString($project)
$base64Auth = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $base64Auth" }

try {
    # Fetch all teams in the project
    # API: GET https://dev.azure.com/{organization}/_{apis}/projects/{projectId}/teams?api-version=7.1
    $url = "$org/_apis/projects/$encodedProject/teams?`$top=500&api-version=7.1"
    Write-Host "Fetching teams from: $url"

    $response = Invoke-RestMethod -Uri $url -Headers $headers -Method Get -ContentType 'application/json'

    $teams = @()
    foreach ($team in $response.value) {
        $teams += @{
            id   = $team.id
            name = $team.name
        }
    }

    # Sort alphabetically
    $teams = $teams | Sort-Object { $_.name }

    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::OK
        Body       = (@{ teams = $teams } | ConvertTo-Json -Depth 5)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
catch {
    Write-Host "Error fetching teams: $_"
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::InternalServerError
        Body       = (@{ error = "Failed to fetch teams: $($_.Exception.Message)" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
}
