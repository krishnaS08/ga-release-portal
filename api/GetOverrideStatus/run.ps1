using namespace System.Net

param($Request, $TriggerMetadata)


$id = $Request.Query.id

if (-not $id) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::BadRequest
        Body       = (@{ message = "Missing 'id' query parameter" } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

$override = Get-OverrideRequest -Id $id
if (-not $override) {
    Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
        StatusCode = [HttpStatusCode]::NotFound
        Body       = (@{ message = "Override request not found"; id = $id } | ConvertTo-Json)
        Headers    = @{ 'Content-Type' = 'application/json' }
    })
    return
}

Push-OutputBinding -Name Response -Value ([HttpResponseContext]@{
    StatusCode = [HttpStatusCode]::OK
    Body       = (@{
        id          = $override.id
        status      = $override.status
        decidedAt   = $override.decidedAt
        decidedBy   = $override.decidedBy
        targetMonth = $override.targetMonth
    } | ConvertTo-Json)
    Headers    = @{ 'Content-Type' = 'application/json' }
})
