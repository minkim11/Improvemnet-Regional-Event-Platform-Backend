[CmdletBinding()]
param(
    [ValidateSet('Before', 'After')]
    [string] $Phase = 'Before',

    [int[]] $Rates = @(25, 50, 100),
    [ValidateRange(1, 10)]
    [int] $Repetitions = 1,
    [string] $WarmupDuration = '5m',
    [string] $MeasurementDuration = '8m',
    [ValidateRange(1, 10)]
    [int] $VuMultiplier = 10,
    [string] $BaseUrl = 'http://127.0.0.1:18080',
    [string] $K6Command = 'k6',
    [string] $ResultRoot = 'performance/k6/results/public-content-list-load',
    [switch] $ValidationOnly,
    [switch] $KeepStack
)

$ErrorActionPreference = 'Stop'
if ($PSVersionTable.PSVersion.Major -ge 7) {
    $PSNativeCommandUseErrorActionPreference = $false
}

$k6Root = $PSScriptRoot
$repositoryRoot = (Resolve-Path (Join-Path $k6Root '../..')).Path
$composeFile = Join-Path $k6Root 'compose.public-content-list-load.yaml'
$scenarioFile = Join-Path $k6Root 'scenarios/public-content-list-load.js'
$existingScenarioFile = Join-Path $k6Root 'scenarios/public-content-readonly.js'
$seedFile = Join-Path $k6Root 'seed/public-content-list-load.seed.sql'
$composeProject = 'regional-event-public-content-load'
$regionId = '990001'
$contentId = '992000'
$fixtureEmail = 'public-content-load@example.com'
$fixturePassword = 'Password1!'
$authOrigin = 'https://public-content-load.local'
$warmupRate = 25
$warmupCooldownSeconds = 30
$runTimestamp = [DateTimeOffset]::UtcNow.ToString('yyyyMMddTHHmmssZ')
$phaseDirectory = Join-Path (Join-Path $repositoryRoot $ResultRoot) "$runTimestamp-$($Phase.ToLowerInvariant())"

function Assert-Command {
    param([Parameter(Mandatory = $true)][string] $Name)

    if (-not (Get-Command $Name -ErrorAction SilentlyContinue)) {
        throw "Required command is not available: $Name"
    }
}

function Invoke-NativeCommand {
    param(
        [Parameter(Mandatory = $true)][scriptblock] $Command,
        [Parameter(Mandatory = $true)][string] $Description,
        [switch] $AllowFailure
    )

    $previousErrorActionPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & $Command
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousErrorActionPreference
    }
    if ($exitCode -ne 0 -and -not $AllowFailure) {
        throw "$Description failed with exit code $exitCode.`n$($output -join [Environment]::NewLine)"
    }
    return @($output)
}

function New-RandomSecret {
    param([ValidateRange(32, 256)][int] $ByteCount = 48)

    $bytes = [byte[]]::new($ByteCount)
    $randomNumberGenerator = [Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $randomNumberGenerator.GetBytes($bytes)
    } finally {
        $randomNumberGenerator.Dispose()
    }
    return [Convert]::ToBase64String($bytes)
}

function Set-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable] $Values)

    $previous = @{}
    foreach ($entry in $Values.GetEnumerator()) {
        $previous[$entry.Key] = [Environment]::GetEnvironmentVariable($entry.Key, 'Process')
        [Environment]::SetEnvironmentVariable($entry.Key, [string] $entry.Value, 'Process')
    }
    return $previous
}

function Restore-ProcessEnvironment {
    param([Parameter(Mandatory = $true)][hashtable] $Previous)

    foreach ($entry in $Previous.GetEnumerator()) {
        [Environment]::SetEnvironmentVariable($entry.Key, $entry.Value, 'Process')
    }
}

function Invoke-Compose {
    param(
        [Parameter(Mandatory = $true)]
        [string[]] $Arguments,
        [switch] $AllowFailure
    )

    return Invoke-NativeCommand `
        -Command { & docker compose --file $composeFile --project-name $composeProject @Arguments 2>&1 } `
        -Description "docker compose $($Arguments -join ' ')" `
        -AllowFailure:$AllowFailure
}

function Invoke-MySql {
    param(
        [Parameter(Mandatory = $true)][string] $Sql,
        [switch] $Root
    )

    $credential = if ($Root) {
        'MYSQL_PWD="$MYSQL_ROOT_PASSWORD" mysql --batch --raw --skip-column-names -uroot "$MYSQL_DATABASE"'
    } else {
        'MYSQL_PWD="$MYSQL_PASSWORD" mysql --batch --raw --skip-column-names -u"$MYSQL_USER" "$MYSQL_DATABASE"'
    }
    return Invoke-NativeCommand `
        -Command {
            $Sql | & docker compose --file $composeFile --project-name $composeProject `
                exec -T mysql sh -c $credential 2>&1
        } `
        -Description 'MySQL command'
}

function Invoke-Redis {
    param([Parameter(Mandatory = $true)][string] $Command)

    $shellCommand = 'export REDISCLI_AUTH="$REDIS_PASSWORD"; ' + $Command
    return Invoke-NativeCommand `
        -Command {
            & docker compose --file $composeFile --project-name $composeProject `
                exec -T redis sh -c $shellCommand 2>&1
        } `
        -Description 'Redis command'
}

function Wait-ForApi {
    $healthUrl = "$($BaseUrl.TrimEnd('/'))/actuator/health"
    $deadline = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        try {
            $response = Invoke-RestMethod -Uri $healthUrl -Method Get -TimeoutSec 5
            if ($response.status -eq 'UP') {
                return
            }
        } catch {
            Start-Sleep -Seconds 2
        }
    } while ([DateTimeOffset]::UtcNow -lt $deadline)

    throw "API did not become healthy within five minutes: $healthUrl"
}

function Install-Fixture {
    param([Parameter(Mandatory = $true)][string] $OutputPath)

    $output = Invoke-MySql -Sql (Get-Content -Raw -Encoding UTF8 $seedFile)
    $output | Set-Content -Encoding UTF8 $OutputPath
    $rows = @($output | Where-Object { $_ -match "\t" })
    if ($rows.Count -ne 6) {
        throw "Fixture verification returned $($rows.Count) rows instead of 6."
    }
    foreach ($row in $rows) {
        $columns = $row -split "\t"
        if ($columns.Count -ne 3 -or [int] $columns[1] -ne [int] $columns[2]) {
            throw "Fixture verification failed: $row"
        }
    }
}

function Assert-PublicContentResponses {
    $cases = @(
        @{ Name = 'region-only'; Query = "regionId=$regionId"; Count = 200; Availability = $null },
        @{ Name = 'content-type'; Query = "regionId=$regionId&contentType=EVENT_EXPERIENCE"; Count = 200; Availability = $null },
        @{ Name = 'available'; Query = "regionId=$regionId&reservationAvailable=true"; Count = 100; Availability = $true },
        @{ Name = 'unavailable'; Query = "regionId=$regionId&reservationAvailable=false"; Count = 100; Availability = $false }
    )
    $results = @()
    foreach ($case in $cases) {
        $response = Invoke-RestMethod `
            -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/contents?$($case.Query)" `
            -Method Get `
            -Headers @{ Accept = 'application/json' }
        $contents = @($response.data.contents)
        if ($response.statusCode -ne 200 -or $response.code -ne 'SUCCESS' -or $contents.Count -ne $case.Count) {
            throw "HTTP fixture verification failed for $($case.Name): expected $($case.Count), actual $($contents.Count)."
        }
        $availabilityMismatchCount = @(
            $contents | Where-Object { $_.reservationAvailable -ne $case.Availability }
        ).Count
        if ($null -ne $case.Availability -and $availabilityMismatchCount -gt 0) {
            throw "HTTP fixture availability verification failed for $($case.Name)."
        }
        $results += [pscustomobject]@{
            variant = $case.Name
            statusCode = $response.statusCode
            contentCount = $contents.Count
        }
    }
    return $results
}

function Get-AccessToken {
    $body = @{ email = $fixtureEmail; password = $fixturePassword } | ConvertTo-Json -Compress
    $response = Invoke-RestMethod `
        -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/auth/login" `
        -Method Post `
        -ContentType 'application/json' `
        -Headers @{ Accept = 'application/json'; Origin = $authOrigin } `
        -Body $body
    if ([string]::IsNullOrWhiteSpace([string] $response.data.accessToken)) {
        throw 'Actuator observer login did not return an access token.'
    }
    return "Bearer $($response.data.accessToken)"
}

function Invoke-K6 {
    param(
        [Parameter(Mandatory = $true)][string] $Script,
        [Parameter(Mandatory = $true)][hashtable] $Environment,
        [string] $SummaryExport,
        [string] $LogPath,
        [switch] $Inspect,
        [switch] $AllowThresholdFailure
    )

    $previous = Set-ProcessEnvironment -Values $Environment
    try {
        [string[]] $arguments = @()
        if ($Inspect) {
            $arguments = @('inspect', '--include-system-env-vars', $Script)
        } else {
            $arguments = @('run')
            if ($SummaryExport) {
                $arguments += @('--summary-export', $SummaryExport)
            }
            $arguments += $Script
        }
        $previousErrorActionPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            if ($LogPath) {
                & $K6Command @arguments 2>&1 |
                    ForEach-Object { $_.ToString() } |
                    Tee-Object -FilePath $LogPath
            } else {
                & $K6Command @arguments
            }
            $exitCode = $LASTEXITCODE
        } finally {
            $ErrorActionPreference = $previousErrorActionPreference
        }
        if ($exitCode -eq 99 -and $AllowThresholdFailure) {
            Write-Warning "k6가 목표 처리량 또는 오류 기준을 충족하지 못했습니다. 다음 RPS 측정을 계속합니다."
        } elseif ($exitCode -ne 0) {
            throw "k6 failed with exit code ${exitCode}: $Script"
        }
    } finally {
        Restore-ProcessEnvironment -Previous $previous
    }
}

function Clear-AndReloadPublicCache {
    Invoke-Redis -Command 'redis-cli --scan --pattern "public-content:*" | xargs -r redis-cli del' | Out-Null
    $contentKeyCount = 0
    $reloadAttempts = 0
    while ($contentKeyCount -lt 200 -and $reloadAttempts -lt 10) {
        $reloadAttempts++
        Invoke-RestMethod `
            -Uri "$($BaseUrl.TrimEnd('/'))/api/v1/contents?regionId=$regionId" `
            -Method Get `
            -Headers @{ Accept = 'application/json' } | Out-Null
        $contentKeyCount = [int] (@(Invoke-Redis -Command `
            'redis-cli --scan --pattern "public-content:*" | wc -l')[-1])
    }
    if ($contentKeyCount -ne 200) {
        throw "Cache reload expected 200 public-content keys but found $contentKeyCount."
    }
    $minimumTtl = [long] (@(Invoke-Redis -Command `
        'for key in $(redis-cli --scan --pattern "public-content:*"); do redis-cli pttl "$key"; done | sort -n | head -1')[-1])
    if ($minimumTtl -le 0) {
        throw "Cache reload produced a non-positive minimum TTL: $minimumTtl"
    }
    return [pscustomobject]@{
        contentKeyCount = $contentKeyCount
        minimumTtlMs = $minimumTtl
        reloadAttempts = $reloadAttempts
    }
}

function Save-DatabaseSnapshot {
    param([Parameter(Mandatory = $true)][string] $Path)

    $query = @'
SELECT
    COALESCE(DIGEST, 'NO_DIGEST'),
    COUNT_STAR,
    ROUND(SUM_TIMER_WAIT / 1000000000, 3),
    ROUND(AVG_TIMER_WAIT / 1000000000, 3),
    SUM_ROWS_EXAMINED,
    SUM_ROWS_SENT,
    REPLACE(REPLACE(DIGEST_TEXT, CHAR(10), ' '), CHAR(13), ' ')
FROM performance_schema.events_statements_summary_by_digest
WHERE SCHEMA_NAME = DATABASE()
    AND (DIGEST_TEXT LIKE '%CONTENT%' OR DIGEST_TEXT LIKE '%IMAGE_OBJECT%')
ORDER BY SUM_TIMER_WAIT DESC
LIMIT 50;
'@
    Invoke-MySql -Sql $query -Root | Set-Content -Encoding UTF8 $Path
}

function Start-RuntimeCollector {
    param(
        [Parameter(Mandatory = $true)][string] $Authorization,
        [Parameter(Mandatory = $true)][int] $DurationSeconds,
        [Parameter(Mandatory = $true)][string] $Directory
    )

    $containerIds = @(Invoke-Compose -Arguments @('ps', '--quiet'))
    return Start-Job -ScriptBlock {
        param($CollectorBaseUrl, $CollectorAuthorization, $CollectorDuration, $CollectorDirectory, $ContainerIds)

        $actuatorPath = Join-Path $CollectorDirectory 'actuator.ndjson'
        $dockerPath = Join-Path $CollectorDirectory 'docker-stats.ndjson'
        $metrics = @(
            'process.cpu.usage',
            'system.cpu.usage',
            'jvm.memory.used',
            'jvm.gc.pause',
            'hikaricp.connections.active',
            'hikaricp.connections.pending',
            'hikaricp.connections.timeout'
        )
        $deadline = [DateTimeOffset]::UtcNow.AddSeconds($CollectorDuration)
        while ([DateTimeOffset]::UtcNow -lt $deadline) {
            $timestamp = [DateTimeOffset]::UtcNow.ToString('o')
            foreach ($metric in $metrics) {
                try {
                    $value = Invoke-RestMethod `
                        -Uri "$($CollectorBaseUrl.TrimEnd('/'))/actuator/metrics/$metric" `
                        -Headers @{ Authorization = $CollectorAuthorization } `
                        -TimeoutSec 3
                    $record = [pscustomobject]@{ timestamp = $timestamp; metric = $metric; data = $value }
                    [IO.File]::AppendAllText(
                        $actuatorPath,
                        ($record | ConvertTo-Json -Depth 8 -Compress) + [Environment]::NewLine
                    )
                } catch {
                    $record = [pscustomobject]@{ timestamp = $timestamp; metric = $metric; error = $_.Exception.Message }
                    [IO.File]::AppendAllText(
                        $actuatorPath,
                        ($record | ConvertTo-Json -Compress) + [Environment]::NewLine
                    )
                }
            }
            if ($ContainerIds.Count -gt 0) {
                $stats = & docker stats --no-stream --format '{{json .}}' @ContainerIds 2>&1
                foreach ($stat in $stats) {
                    [IO.File]::AppendAllText($dockerPath, "$timestamp`t$stat$([Environment]::NewLine)")
                }
            }
            Start-Sleep -Seconds 5
        }
    } -ArgumentList $BaseUrl, $Authorization, ($DurationSeconds + 5), $Directory, (,$containerIds)
}

function ConvertFrom-K6Duration {
    param([Parameter(Mandatory = $true)][string] $Value)

    if ($Value -notmatch '^(?<amount>\d+)(?<unit>ms|s|m|h)$') {
        throw "Unsupported k6 duration: $Value"
    }
    $amount = [double] $Matches.amount
    $seconds = switch ($Matches.unit) {
        'ms' { $amount / 1000 }
        's' { $amount }
        'm' { $amount * 60 }
        'h' { $amount * 3600 }
    }
    return $seconds
}

function Get-SummaryMetric {
    param(
        [Parameter(Mandatory = $true)] $Summary,
        [Parameter(Mandatory = $true)][string] $MetricName,
        [Parameter(Mandatory = $true)][string] $ValueName
    )

    $metric = $Summary.metrics.$MetricName
    if ($null -eq $metric) {
        throw "k6 summary is missing metric $MetricName."
    }
    $source = if ($null -ne $metric.values) { $metric.values } else { $metric }
    return [double] $source.$ValueName
}

function Save-StabilityDecision {
    param(
        [Parameter(Mandatory = $true)][string] $SummaryPath,
        [Parameter(Mandatory = $true)][double] $DurationSeconds,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $summary = Get-Content -Raw -Encoding UTF8 $SummaryPath | ConvertFrom-Json
    $firstP95 = Get-SummaryMetric -Summary $summary -MetricName 'public_content_first_half_duration' -ValueName 'p(95)'
    $secondP95 = Get-SummaryMetric -Summary $summary -MetricName 'public_content_second_half_duration' -ValueName 'p(95)'
    $firstCount = Get-SummaryMetric -Summary $summary -MetricName 'public_content_first_half_requests' -ValueName 'count'
    $secondCount = Get-SummaryMetric -Summary $summary -MetricName 'public_content_second_half_requests' -ValueName 'count'
    $halfSeconds = $DurationSeconds / 2
    $firstThroughput = $firstCount / $halfSeconds
    $secondThroughput = $secondCount / $halfSeconds
    $p95DifferencePercent = if ($firstP95 -eq 0) { 0 } else { [Math]::Abs($secondP95 - $firstP95) / $firstP95 * 100 }
    $throughputDifferencePercent = if ($firstThroughput -eq 0) { 0 } else {
        [Math]::Abs($secondThroughput - $firstThroughput) / $firstThroughput * 100
    }
    $decision = [pscustomobject]@{
        firstHalfP95Ms = $firstP95
        secondHalfP95Ms = $secondP95
        p95DifferencePercent = $p95DifferencePercent
        firstHalfThroughputRps = $firstThroughput
        secondHalfThroughputRps = $secondThroughput
        throughputDifferencePercent = $throughputDifferencePercent
        p95Stable = $p95DifferencePercent -le 10
        throughputStable = $throughputDifferencePercent -le 5
    }
    $decision | ConvertTo-Json | Set-Content -Encoding UTF8 $OutputPath
    if (-not $decision.p95Stable -or -not $decision.throughputStable) {
        Write-Warning "Stability warning: P95 difference=$([Math]::Round($p95DifferencePercent, 2))%, throughput difference=$([Math]::Round($throughputDifferencePercent, 2))%." `
            -WarningAction Continue
    }
}

function Get-ActuatorMetricValues {
    param(
        [Parameter(Mandatory = $true)][string] $Path,
        [Parameter(Mandatory = $true)][string] $MetricName
    )

    if (-not (Test-Path $Path)) {
        return @()
    }
    return @(Get-Content -Encoding UTF8 $Path | ForEach-Object {
        $record = $_ | ConvertFrom-Json
        if ($record.metric -eq $MetricName -and $null -ne $record.data.measurements) {
            $measurement = $record.data.measurements | Where-Object { $_.statistic -eq 'VALUE' } | Select-Object -First 1
            if ($null -ne $measurement) {
                [double] $measurement.value
            }
        }
    })
}

function Get-BottleneckCandidates {
    param([Parameter(Mandatory = $true)][string] $RunDirectory)

    $actuatorPath = Join-Path $RunDirectory 'actuator.ndjson'
    $cpuValues = @(Get-ActuatorMetricValues -Path $actuatorPath -MetricName 'process.cpu.usage')
    $pendingValues = @(Get-ActuatorMetricValues -Path $actuatorPath -MetricName 'hikaricp.connections.pending')
    $candidates = @()
    if ($cpuValues.Count -gt 0 -and ($cpuValues | Measure-Object -Average).Average -ge 0.85) {
        $candidates += 'API CPU'
    }
    if ($pendingValues.Count -gt 0 -and ($pendingValues | Measure-Object -Maximum).Maximum -gt 0) {
        $candidates += 'Hikari 연결 풀'
    }
    if ($candidates.Count -eq 0) {
        return '자동 감지 없음'
    }
    return $candidates -join ', '
}

function Get-ExplorationResult {
    param(
        [Parameter(Mandatory = $true)][string] $SummaryPath,
        [Parameter(Mandatory = $true)][string] $RunDirectory,
        [Parameter(Mandatory = $true)][int] $TargetRate,
        [Parameter(Mandatory = $true)][int] $Repetition
    )

    $summary = Get-Content -Raw -Encoding UTF8 $SummaryPath | ConvertFrom-Json
    $actualRate = Get-SummaryMetric -Summary $summary -MetricName 'http_reqs' -ValueName 'rate'
    $httpErrorRate = Get-SummaryMetric -Summary $summary -MetricName 'http_req_failed' -ValueName 'value'
    $contractErrorRate = Get-SummaryMetric -Summary $summary -MetricName 'public_content_contract_error_rate' -ValueName 'value'
    $p95 = Get-SummaryMetric -Summary $summary -MetricName 'http_req_duration' -ValueName 'p(95)'
    $droppedCount = Get-SummaryMetric -Summary $summary -MetricName 'dropped_iterations' -ValueName 'count'
    return [pscustomobject]@{
        targetRate = $TargetRate
        repetition = $Repetition
        actualRate = $actualRate
        attainmentPercent = $actualRate / $TargetRate * 100
        p95Ms = $p95
        droppedCount = [long] $droppedCount
        httpErrorPercent = $httpErrorRate * 100
        contractErrorPercent = $contractErrorRate * 100
        normal = $httpErrorRate -eq 0 -and $contractErrorRate -eq 0 -and $actualRate -ge ($TargetRate * 0.95)
        candidates = Get-BottleneckCandidates -RunDirectory $RunDirectory
    }
}

function Save-ExplorationSummary {
    param(
        [Parameter(Mandatory = $true)][object[]] $Results,
        [Parameter(Mandatory = $true)][string] $OutputPath
    )

    $orderedResults = @($Results | Sort-Object targetRate, repetition)
    $firstFailed = $orderedResults | Where-Object { -not $_.normal } | Select-Object -First 1
    $highestNormal = $orderedResults | Where-Object { $_.normal } | Sort-Object targetRate -Descending | Select-Object -First 1
    if ($null -eq $firstFailed) {
        $limitRange = "$($orderedResults[-1].targetRate) RPS 초과 — 더 높은 RPS 측정 필요"
    } else {
        $previousNormal = $orderedResults |
            Where-Object { $_.normal -and $_.targetRate -lt $firstFailed.targetRate } |
            Sort-Object targetRate -Descending |
            Select-Object -First 1
        $limitRange = if ($null -eq $previousNormal) {
            "$($firstFailed.targetRate) RPS 이하"
        } else {
            "$($previousNormal.targetRate)~$($firstFailed.targetRate) RPS 사이"
        }
    }
    $verifiedRate = if ($null -eq $highestNormal) { '확인되지 않음' } else { "$($highestNormal.targetRate) RPS" }
    $previousP95 = $null
    $rows = foreach ($result in $orderedResults) {
        $latencySpike = $null -ne $previousP95 -and $result.p95Ms -ge ($previousP95 * 2)
        if ($result.normal) {
            $status = '정상'
            $previousP95 = $result.p95Ms
        } elseif ($result.targetRate -eq $firstFailed.targetRate) {
            $status = '한계'
        } else {
            $status = '과부하'
        }
        $latency = if ($latencySpike) { '급증' } else { '-' }
        "| $($result.targetRate) | $([Math]::Round($result.actualRate, 2)) | $([Math]::Round($result.attainmentPercent, 2))% | $([Math]::Round($result.p95Ms, 2))ms | $($result.droppedCount) | $([Math]::Round($result.httpErrorPercent, 2))% | $([Math]::Round($result.contractErrorPercent, 2))% | $status | $latency | $($result.candidates) |"
    }
    @(
        '# 공개 콘텐츠 목록 처리 한계 탐색 결과'
        ''
        '## 결론'
        ''
        "- 단계 판정: 목표 RPS의 95% 이상 처리하고 HTTP·계약 오류가 없으면 정상"
        "- 검증된 최고 처리량: **$verifiedRate**"
        "- 처리 한계 위치: **$limitRange**"
        '- 캐시 효과: 같은 RPS로 After를 실행한 뒤 검증된 최고 처리량이 상승했는지 비교'
        ''
        '## 단계별 결과'
        ''
        '| 목표 RPS | 실제 RPS | 목표 달성률 | P95 | drop | HTTP 오류 | 계약 오류 | 판정 | P95 변화 | 병목 후보 |'
        '| ---: | ---: | ---: | ---: | ---: | ---: | ---: | --- | --- | --- |'
        $rows
        ''
        '병목 후보는 자동 확정값이 아닙니다. 해당 단계의 actuator.ndjson, docker-stats.ndjson, MySQL·Redis 전후 파일로 교차 확인합니다.'
    ) | Set-Content -Encoding UTF8 $OutputPath
}

function Save-EnvironmentEvidence {
    param([Parameter(Mandatory = $true)][string] $Directory)

    $evidence = [ordered]@{
        capturedAt = [DateTimeOffset]::UtcNow.ToString('o')
        phase = $Phase
        gitCommit = (& git -C $repositoryRoot rev-parse HEAD)
        os = [Environment]::OSVersion.VersionString
        processorCount = [Environment]::ProcessorCount
        dotnetRuntime = [Environment]::Version.ToString()
        rates = $Rates
        repetitions = $Repetitions
        warmupRate = $warmupRate
        warmupDuration = $WarmupDuration
        warmupCooldownSeconds = $warmupCooldownSeconds
        measurementDuration = $MeasurementDuration
        vuMultiplier = $VuMultiplier
        minimumTargetAttainmentPercent = 95
        apiJava = '21 (Dockerfile amazoncorretto:21-al2023-headless)'
        mysqlImage = 'mysql:8.0.42'
        redisImage = 'redis:7.2.16-alpine'
        resourceLimits = @{ api = '2 CPU / 1024 MiB'; mysql = '1.5 CPU / 1536 MiB'; redis = '0.5 CPU / 256 MiB' }
        dockerVersion = ((Invoke-NativeCommand `
            -Command { & docker version --format '{{json .}}' 2>&1 } `
            -Description 'docker version') -join [Environment]::NewLine)
        dockerComposeVersion = ((Invoke-NativeCommand `
            -Command { & docker compose version 2>&1 } `
            -Description 'docker compose version') -join [Environment]::NewLine)
        k6Version = ((Invoke-NativeCommand `
            -Command { & $K6Command version 2>&1 } `
            -Description 'k6 version') -join [Environment]::NewLine)
    }
    $evidence | ConvertTo-Json -Depth 6 | Set-Content -Encoding UTF8 (Join-Path $Directory 'environment.json')
    Invoke-Compose -Arguments @('images') | Set-Content -Encoding UTF8 (Join-Path $Directory 'compose-images.txt')
}

function Reset-RunStack {
    Invoke-Compose -Arguments @('stop', 'api') | Out-Null
    Invoke-Compose -Arguments @('restart', 'mysql', 'redis') | Out-Null
    Invoke-Compose -Arguments @('up', '-d', '--wait', 'mysql', 'redis') | Out-Null
    Invoke-Compose -Arguments @('up', '-d', 'api') | Out-Null
    Wait-ForApi
}

Assert-Command -Name 'docker'
Assert-Command -Name $K6Command
foreach ($rateValue in $Rates) {
    if ($rateValue -le 0) {
        throw "Rates must contain only positive integers: $rateValue"
    }
}
$measurementSeconds = ConvertFrom-K6Duration -Value $MeasurementDuration
$runtimeEnvironment = @{
    PERF_MYSQL_ROOT_PASSWORD = New-RandomSecret
    PERF_MYSQL_DATABASE = 'regional_event_perf'
    PERF_MYSQL_USER = 'perf'
    PERF_MYSQL_PASSWORD = New-RandomSecret
    PERF_REDIS_PASSWORD = New-RandomSecret
    PERF_JWT_ACCESS_KEY = New-RandomSecret -ByteCount 64
    PERF_JWT_REFRESH_KEY = New-RandomSecret -ByteCount 64
    PERF_QR_KEY = New-RandomSecret -ByteCount 64
    PERF_API_PORT = ([Uri] $BaseUrl).Port
}
$previousRuntimeEnvironment = Set-ProcessEnvironment -Values $runtimeEnvironment
$stackStarted = $false
$explorationResults = @()

try {
    New-Item -ItemType Directory -Force -Path $phaseDirectory | Out-Null

    Invoke-Compose -Arguments @('config', '--quiet') | Out-Null
    Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') -AllowFailure | Out-Null
    Invoke-Compose -Arguments @('up', '-d', '--build', '--wait') | Out-Null
    $stackStarted = $true
    Wait-ForApi
    Save-EnvironmentEvidence -Directory $phaseDirectory

    Install-Fixture -OutputPath (Join-Path $phaseDirectory 'fixture-counts.tsv')
    Assert-PublicContentResponses |
        ConvertTo-Json |
        Set-Content -Encoding UTF8 (Join-Path $phaseDirectory 'fixture-http.json')

    $commonK6Environment = @{
        PERF_BASE_URL = $BaseUrl.TrimEnd('/')
        PERF_REGION_ID = $regionId
        PERF_CONTENT_ID = $contentId
        PERF_RESERVATION_AVAILABLE = 'true'
    }
    Invoke-K6 `
        -Script $scenarioFile `
        -Environment $commonK6Environment `
        -Inspect `
        -LogPath (Join-Path $phaseDirectory 'k6-inspect.txt')

    $smokeDirectory = Join-Path $phaseDirectory 'smoke'
    New-Item -ItemType Directory -Force -Path $smokeDirectory | Out-Null
    Invoke-K6 `
        -Script $scenarioFile `
        -Environment ($commonK6Environment + @{
            PERF_RATE = '1'
            PERF_PRE_ALLOCATED_VUS = '5'
            PERF_DURATION = '30s'
            PERF_SUMMARY_DIRECTORY = $smokeDirectory
            PERF_SUMMARY_BASENAME = 'public-content-list-load-smoke'
        }) `
        -SummaryExport (Join-Path $smokeDirectory 'public-content-list-load-smoke.json') `
        -LogPath (Join-Path $smokeDirectory 'public-content-list-load-smoke.log')
    Invoke-K6 `
        -Script $existingScenarioFile `
        -Environment ($commonK6Environment + @{
            PERF_PUBLIC_CONTENT_READONLY_VUS = '1'
            PERF_PUBLIC_CONTENT_READONLY_DURATION = '30s'
            PERF_SUMMARY_DIRECTORY = $smokeDirectory
            PERF_SUMMARY_BASENAME = 'public-content-readonly-smoke'
        }) `
        -SummaryExport (Join-Path $smokeDirectory 'public-content-readonly-smoke.json') `
        -LogPath (Join-Path $smokeDirectory 'public-content-readonly-smoke.log')

    if (-not $ValidationOnly) {
        foreach ($rateValue in $Rates) {
            foreach ($repetition in 1..$Repetitions) {
                $runDirectory = Join-Path $phaseDirectory "rps-$rateValue-run-$repetition"
                New-Item -ItemType Directory -Force -Path $runDirectory | Out-Null
                Reset-RunStack
                Install-Fixture -OutputPath (Join-Path $runDirectory 'fixture-counts.tsv')

                $warmupPreAllocatedVUs = [Math]::Max(20, $warmupRate * $VuMultiplier)
                $measurementPreAllocatedVUs = [Math]::Max(20, $rateValue * $VuMultiplier)
                Invoke-K6 `
                    -Script $scenarioFile `
                    -Environment ($commonK6Environment + @{
                        PERF_RATE = [string] $warmupRate
                        PERF_PRE_ALLOCATED_VUS = [string] $warmupPreAllocatedVUs
                        PERF_DURATION = $WarmupDuration
                        PERF_REQUIRE_TARGET_RATE = 'false'
                        PERF_SUMMARY_DIRECTORY = $runDirectory
                        PERF_SUMMARY_BASENAME = 'warmup'
                    }) `
                    -SummaryExport (Join-Path $runDirectory 'warmup.json') `
                    -LogPath (Join-Path $runDirectory 'warmup.log')

                Write-Host "워밍업이 완료되었습니다. 캐시 재적재 전 $warmupCooldownSeconds초 동안 대기합니다."
                Start-Sleep -Seconds $warmupCooldownSeconds
                Clear-AndReloadPublicCache |
                    ConvertTo-Json |
                    Set-Content -Encoding UTF8 (Join-Path $runDirectory 'cache-reload.json')
                $authorization = Get-AccessToken
                Save-DatabaseSnapshot -Path (Join-Path $runDirectory 'mysql-before.tsv')
                Invoke-Redis -Command 'redis-cli INFO' |
                    Set-Content -Encoding UTF8 (Join-Path $runDirectory 'redis-before.txt')

                $collector = Start-RuntimeCollector `
                    -Authorization $authorization `
                    -DurationSeconds ([int] $measurementSeconds) `
                    -Directory $runDirectory
                $summaryPath = Join-Path $runDirectory 'measurement.json'
                try {
                    Invoke-K6 `
                        -Script $scenarioFile `
                        -Environment ($commonK6Environment + @{
                            PERF_RATE = [string] $rateValue
                            PERF_PRE_ALLOCATED_VUS = [string] $measurementPreAllocatedVUs
                            PERF_DURATION = $MeasurementDuration
                            PERF_SUMMARY_DIRECTORY = $runDirectory
                            PERF_SUMMARY_BASENAME = 'measurement'
                        }) `
                        -SummaryExport $summaryPath `
                        -LogPath (Join-Path $runDirectory 'measurement.log') `
                        -AllowThresholdFailure
                } finally {
                    Wait-Job -Job $collector -Timeout 30 | Out-Null
                    if ($collector.State -eq 'Running') {
                        Stop-Job -Job $collector
                    }
                    Receive-Job -Job $collector -ErrorAction SilentlyContinue | Out-Null
                    Remove-Job -Job $collector -Force
                    Save-DatabaseSnapshot -Path (Join-Path $runDirectory 'mysql-after.tsv')
                    Invoke-Redis -Command 'redis-cli INFO' |
                        Set-Content -Encoding UTF8 (Join-Path $runDirectory 'redis-after.txt')
                    Invoke-Compose -Arguments @('logs', '--no-color', '--timestamps', 'api') |
                        Set-Content -Encoding UTF8 (Join-Path $runDirectory 'api.log')
                }

                Save-StabilityDecision `
                    -SummaryPath $summaryPath `
                    -DurationSeconds $measurementSeconds `
                    -OutputPath (Join-Path $runDirectory 'stability.json')
                $explorationResults += Get-ExplorationResult `
                    -SummaryPath $summaryPath `
                    -RunDirectory $runDirectory `
                    -TargetRate $rateValue `
                    -Repetition $repetition
            }
        }
        Save-ExplorationSummary `
            -Results $explorationResults `
            -OutputPath (Join-Path $phaseDirectory 'result-summary.md')
        Write-Host "결과 요약: $(Join-Path $phaseDirectory 'result-summary.md')"
    }

    Write-Host "Public content list load test completed: $phaseDirectory"
} finally {
    if ($stackStarted -and -not $KeepStack) {
        Invoke-Compose -Arguments @('down', '--volumes', '--remove-orphans') -AllowFailure | Out-Null
    }
    Restore-ProcessEnvironment -Previous $previousRuntimeEnvironment
}
