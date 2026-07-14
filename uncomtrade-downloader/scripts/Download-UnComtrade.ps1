[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9,\s]+$')]
    [string]$HsCode,

    [Parameter(Mandatory = $true)]
    [ValidatePattern('^[0-9,\s]+$')]
    [string]$Period,

    [ValidateSet('A', 'M')]
    [string]$Frequency = 'A',

    [string]$Reporters = 'all',

    [string]$Partners = 'all',

    [string]$Flows = 'M,X',

    [ValidateSet('all', 'reported', 'reported-nonaggregate')]
    [string]$QualityFilter = 'reported-nonaggregate',

    [string]$TimeSeriesReporter,

    [switch]$IncludeLatestChinaValidationPeriod,

    [string]$OutputDir,

    [int]$RetryCount = 3,

    [ValidateRange(0, 10000)]
    [int]$RequestPauseMilliseconds = 500,

    [ValidateRange(0, 3)]
    [int]$EmptyResponseRetryCount = 1,

    [ValidateRange(1, 100)]
    [int]$CsrfRefreshEveryRequests = 20,

    [switch]$AvailabilityOnly
)

$ErrorActionPreference = 'Stop'

function Get-TokenList {
    param([string]$Value)
    return @($Value -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}

function Assert-PeriodInput {
    param([string[]]$Periods, [string]$Frequency)
    $pattern = if ($Frequency -eq 'A') { '^\d{4}$' } else { '^\d{6}$' }
    $invalid = @($Periods | Where-Object { $_ -notmatch $pattern })
    if ($invalid.Count -gt 0) {
        $example = if ($Frequency -eq 'A') { '2024,2025' } else { '202501,202502' }
        throw "Invalid period(s): $($invalid -join ', '). For frequency $Frequency, use $example."
    }
}

function ConvertTo-FlowCodes {
    param([string]$Value)
    $map = @{ 'M' = 'M'; 'IMPORT' = 'M'; 'IMPORTS' = 'M'; 'X' = 'X'; 'EXPORT' = 'X'; 'EXPORTS' = 'X' }
    $codes = New-Object System.Collections.Generic.List[string]
    foreach ($token in (Get-TokenList $Value)) {
        $key = $token.ToUpperInvariant()
        if (-not $map.ContainsKey($key)) {
            throw "Unknown flow '$token'. Use M, X, Imports, or Exports."
        }
        if (-not $codes.Contains($map[$key])) { $codes.Add($map[$key]) }
    }
    if ($codes.Count -eq 0) { throw 'Choose at least one trade flow.' }
    return $codes.ToArray()
}

function Encode-QueryValue {
    param([string]$Value)
    return [uri]::EscapeDataString($Value)
}

function Invoke-JsonRequest {
    param(
        [Parameter(Mandatory = $true)][string]$Uri,
        [ValidateSet('Get', 'Post')][string]$Method = 'Get',
        [object]$Body = $null,
        [int]$TimeoutSec = 180
    )
    if ($Method -eq 'Post') {
        $jsonBody = $Body | ConvertTo-Json -Depth 8 -Compress
        $response = Invoke-WebRequest -Uri $Uri -Method Post -Body $jsonBody -ContentType 'application/json' -UseBasicParsing -Headers $script:Headers -WebSession $script:Session -TimeoutSec $TimeoutSec
    } else {
        $response = Invoke-WebRequest -Uri $Uri -UseBasicParsing -Headers $script:Headers -WebSession $script:Session -TimeoutSec $TimeoutSec
    }
    return ($response.Content | ConvertFrom-Json)
}

function Get-CsrfToken {
    $tokenResponse = Invoke-JsonRequest -Uri 'https://comtradeplus.un.org/api/Trade/GetCsrfToken'
    if ([string]::IsNullOrWhiteSpace([string]$tokenResponse.csrfToken)) {
        throw 'UN Comtrade Plus did not return a CSRF token.'
    }
    $script:Headers['X-CSRF-TOKEN'] = $tokenResponse.csrfToken
}

function Resolve-CountrySelection {
    param(
        [string]$Value,
        [object[]]$Availability,
        [string]$Dimension
    )
    if ([string]::IsNullOrWhiteSpace($Value) -or $Value.Trim().ToLowerInvariant() -eq 'all') { return 'all' }

    $specialCodes = @{ 'WORLD' = '0'; 'W00' = '0' }
    $aliases = @{ 'EU' = 'EUR'; 'EU27' = 'EUR' }
    $resolved = New-Object System.Collections.Generic.List[string]
    foreach ($token in (Get-TokenList $Value)) {
        $upper = $token.ToUpperInvariant()
        $lookup = if ($aliases.ContainsKey($upper)) { $aliases[$upper] } else { $upper }
        $matches = @($Availability | Where-Object {
            ([string]$_.reporterISO).ToUpperInvariant() -eq $lookup -or
            ([string]$_.reporterCode) -eq $token -or
            ([string]$_.reporterDesc).Trim().ToUpperInvariant() -eq $lookup
        } | Sort-Object reporterCode -Unique)
        $code = $null
        if ($specialCodes.ContainsKey($upper)) {
            $code = $specialCodes[$upper]
        } elseif ($token -match '^\d+$') {
            $code = $token
        } elseif ($matches.Count -eq 1) {
            $code = [string]$matches[0].reporterCode
        } elseif ($matches.Count -gt 1) {
            throw "Ambiguous $Dimension selection '$token'. Use its ISO3 or M49 code."
        } else {
            throw "Cannot resolve $Dimension '$token' from the selected data availability. Use an ISO3 code that has data in the requested period or an M49 code."
        }
        if (-not $resolved.Contains($code)) { $resolved.Add($code) }
    }
    return ($resolved -join ',')
}

function Test-QualityRow {
    param([object]$Row, [string]$Filter)
    if ($Filter -eq 'all') { return $true }
    $reported = ($Row.isReported -eq $true -or [string]$Row.isReported -eq 'True')
    if ($Filter -eq 'reported') { return $reported }
    $nonAggregate = ($Row.isAggregate -eq $false -or [string]$Row.isAggregate -eq 'False')
    return ($reported -and $nonAggregate)
}

function Get-MetricValue {
    param([object]$Row, [ValidateSet('QuantityTonnes', 'PrimaryValueUSD')][string]$Metric)
    if ($Metric -eq 'PrimaryValueUSD') {
        if ($null -eq $Row.primaryValue -or [string]$Row.primaryValue -eq '') { return 0.0 }
        return [double]$Row.primaryValue
    }
    $weight = if ($null -ne $Row.netWgt -and [string]$Row.netWgt -ne '') { [double]$Row.netWgt } elseif ($null -ne $Row.qty -and [string]$Row.qty -ne '') { [double]$Row.qty } else { 0.0 }
    return ($weight / 1000.0)
}

function ConvertTo-Label {
    param([double]$Value, [ValidateSet('QuantityTonnes', 'PrimaryValueUSD')][string]$Metric)
    if ($Metric -eq 'QuantityTonnes') {
        if ([math]::Abs($Value) -ge 1000000) { return ('{0:N2} Mt' -f ($Value / 1000000)) }
        if ([math]::Abs($Value) -ge 1000) { return ('{0:N1} kt' -f ($Value / 1000)) }
        return ('{0:N0} t' -f $Value)
    }
    if ([math]::Abs($Value) -ge 1000000000) { return ('${0:N2} bn' -f ($Value / 1000000000)) }
    if ([math]::Abs($Value) -ge 1000000) { return ('${0:N1} m' -f ($Value / 1000000)) }
    return ('${0:N0}' -f $Value)
}

function Escape-Xml {
    param([string]$Value)
    return [System.Security.SecurityElement]::Escape([string]$Value)
}

function Write-BarChart {
    param(
        [object[]]$Rows,
        [string]$Title,
        [ValidateSet('QuantityTonnes', 'PrimaryValueUSD')][string]$Metric,
        [string]$Path,
        [string]$Color,
        [string]$Note
    )
    $width = 1200; $height = 700; $left = 320; $right = 130; $top = if ([string]::IsNullOrWhiteSpace($Note)) { 95 } else { 115 }; $bottom = 75
    $plotWidth = $width - $left - $right; $plotHeight = $height - $top - $bottom
    $max = [double](($Rows | Measure-Object -Property Value -Maximum).Maximum)
    if ($max -le 0) { $max = 1 }
    $barHeight = [math]::Min(38, [math]::Floor($plotHeight / [math]::Max($Rows.Count, 1) * 0.62))
    $gap = [math]::Max(10, [math]::Floor(($plotHeight / [math]::Max($Rows.Count, 1)) - $barHeight))
    $svg = New-Object System.Collections.Generic.List[string]
    $svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
    $svg.Add("<title id=`"title`">$(Escape-Xml $Title)</title>")
    $svg.Add("<desc id=`"desc`">Top ten countries ranked by $(if ($Metric -eq 'QuantityTonnes') { 'trade quantity in tonnes' } else { 'trade value in US dollars' }).</desc>")
    $svg.Add('<rect width="100%" height="100%" fill="white"/>')
    $svg.Add("<text x=`"$left`" y=`"45`" font-family=`"Arial, sans-serif`" font-size=`"26`" font-weight=`"600`" fill=`"#1f2937`">$(Escape-Xml $Title)</text>")
    if (-not [string]::IsNullOrWhiteSpace($Note)) {
        $svg.Add("<text x=`"$left`" y=`"70`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#9a3412`">$(Escape-Xml $Note)</text>")
    }
    for ($tick = 0; $tick -le 4; $tick++) {
        $value = $max * $tick / 4
        $x = $left + $plotWidth * $tick / 4
        $svg.Add("<line x1=`"$([math]::Round($x,1))`" y1=`"$top`" x2=`"$([math]::Round($x,1))`" y2=`"$($top + $plotHeight)`" stroke=`"#d1d5db`" stroke-width=`"1`"/>")
        $svg.Add("<text x=`"$([math]::Round($x,1))`" y=`"$($height - 35)`" text-anchor=`"middle`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#4b5563`">$(Escape-Xml (ConvertTo-Label -Value $value -Metric $Metric))</text>")
    }
    for ($index = 0; $index -lt $Rows.Count; $index++) {
        $row = $Rows[$index]
        $y = $top + $index * ($barHeight + $gap) + [math]::Floor($gap / 2)
        $barWidth = $plotWidth * ([double]$row.Value / $max)
        $label = if ($row.ISO3) { "$($row.Country) ($($row.ISO3))" } else { [string]$row.Country }
        $svg.Add("<text x=`"$($left - 18)`" y=`"$([math]::Round($y + $barHeight * 0.72,1))`" text-anchor=`"end`" font-family=`"Arial, sans-serif`" font-size=`"16`" fill=`"#1f2937`">$(Escape-Xml $label)</text>")
        $svg.Add("<rect x=`"$left`" y=`"$([math]::Round($y,1))`" width=`"$([math]::Round($barWidth,1))`" height=`"$barHeight`" fill=`"$Color`" rx=`"2`"/>")
        $valueX = [math]::Min($left + $barWidth + 10, $width - 8)
        $anchor = if ($valueX -ge ($width - 9)) { 'end' } else { 'start' }
        $svg.Add("<text x=`"$([math]::Round($valueX,1))`" y=`"$([math]::Round($y + $barHeight * 0.72,1))`" text-anchor=`"$anchor`" font-family=`"Arial, sans-serif`" font-size=`"15`" fill=`"#374151`">$(Escape-Xml (ConvertTo-Label -Value ([double]$row.Value) -Metric $Metric))</text>")
    }
    $svg.Add('</svg>')
    [System.IO.File]::WriteAllLines($Path, $svg, [System.Text.UTF8Encoding]::new($false))
}

function Write-TimeSeriesChart {
    param(
        [object[]]$Rows,
        [string]$Reporter,
        [ValidateSet('QuantityTonnes', 'PrimaryValueUSD')][string]$Metric,
        [string]$Path,
        [string[]]$ExpectedPeriods,
        [string]$ValidationNote
    )
    $width = 1200; $height = 660; $left = 115; $right = 50; $top = 140; $bottom = 100
    $plotWidth = $width - $left - $right; $plotHeight = $height - $top - $bottom
    $periods = if ($ExpectedPeriods.Count -gt 0) { @($ExpectedPeriods | Sort-Object) } else { @($Rows | Select-Object -ExpandProperty Period -Unique | Sort-Object) }
    $max = [double](($Rows | Measure-Object -Property Value -Maximum).Maximum)
    if ($max -le 0) { $max = 1 }
    $unit = if ($Metric -eq 'QuantityTonnes') { 'Quantity (tonnes)' } else { 'Primary value (USD)' }
    $svg = New-Object System.Collections.Generic.List[string]
    $svg.Add("<svg xmlns=`"http://www.w3.org/2000/svg`" width=`"$width`" height=`"$height`" viewBox=`"0 0 $width $height`" role=`"img`" aria-labelledby=`"title desc`">")
    $svg.Add("<title id=`"title`">$(Escape-Xml "$Reporter imports and exports over time")</title>")
    $svg.Add("<desc id=`"desc`">Import and export series for $Reporter using UN Comtrade reporter World totals.</desc>")
    $svg.Add('<rect width="100%" height="100%" fill="white"/>')
    $svg.Add("<text x=`"$left`" y=`"45`" font-family=`"Arial, sans-serif`" font-size=`"26`" font-weight=`"600`" fill=`"#1f2937`">$(Escape-Xml "$Reporter imports and exports: $unit")</text>")
    $svg.Add("<text x=`"$left`" y=`"70`" font-family=`"Arial, sans-serif`" font-size=`"15`" fill=`"#4b5563`">Reporter total: World aggregate where usable, otherwise reported bilateral sum</text>")
    if (-not [string]::IsNullOrWhiteSpace($ValidationNote)) {
        $svg.Add("<text x=`"$left`" y=`"94`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#9a3412`">$(Escape-Xml $ValidationNote)</text>")
    }
    $missingPeriods = @(
        foreach ($candidatePeriod in $periods) {
            if (@($Rows | Where-Object { $_.Period -eq $candidatePeriod }).Count -eq 0) { $candidatePeriod }
        }
    )
    if ($missingPeriods.Count -gt 0) {
        $svg.Add("<text x=`"$left`" y=`"118`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#9a3412`">No reporter-total record returned: $($missingPeriods -join ', ')</text>")
    }
    for ($tick = 0; $tick -le 4; $tick++) {
        $value = $max * $tick / 4
        $y = $top + $plotHeight - ($plotHeight * $tick / 4)
        $svg.Add("<line x1=`"$left`" y1=`"$([math]::Round($y,1))`" x2=`"$($left + $plotWidth)`" y2=`"$([math]::Round($y,1))`" stroke=`"#d1d5db`" stroke-width=`"1`"/>")
        $svg.Add("<text x=`"$($left - 12)`" y=`"$([math]::Round($y + 5,1))`" text-anchor=`"end`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#4b5563`">$(Escape-Xml (ConvertTo-Label -Value $value -Metric $Metric))</text>")
    }
    for ($i = 0; $i -lt $periods.Count; $i++) {
        $x = if ($periods.Count -eq 1) { $left + $plotWidth / 2 } else { $left + $plotWidth * $i / ($periods.Count - 1) }
        $svg.Add("<text x=`"$([math]::Round($x,1))`" y=`"$($height - 45)`" text-anchor=`"middle`" font-family=`"Arial, sans-serif`" font-size=`"14`" fill=`"#4b5563`">$($periods[$i])</text>")
    }
    $series = @(
        [pscustomobject]@{ Code = 'M'; Label = 'Imports'; Color = '#2563eb' },
        [pscustomobject]@{ Code = 'X'; Label = 'Exports'; Color = '#d97706' }
    )
    foreach ($seriesItem in $series) {
        $segments = New-Object System.Collections.Generic.List[object]
        $points = New-Object System.Collections.Generic.List[string]
        foreach ($i in 0..($periods.Count - 1)) {
            $periodValue = $periods[$i]
            $item = @($Rows | Where-Object { $_.Period -eq $periodValue -and $_.FlowCode -eq $seriesItem.Code } | Select-Object -First 1)
            if ($item.Count -eq 0) {
                if ($points.Count -gt 0) { $segments.Add($points.ToArray()) | Out-Null; $points = New-Object System.Collections.Generic.List[string] }
                continue
            }
            $x = if ($periods.Count -eq 1) { $left + $plotWidth / 2 } else { $left + $plotWidth * $i / ($periods.Count - 1) }
            $y = $top + $plotHeight - ($plotHeight * ([double]$item[0].Value / $max))
            $points.Add([string]::Format([System.Globalization.CultureInfo]::InvariantCulture, '{0:F1},{1:F1}', $x, $y))
        }
        if ($points.Count -gt 0) { $segments.Add($points.ToArray()) | Out-Null }
        foreach ($segment in $segments) {
            $svg.Add("<polyline fill=`"none`" stroke=`"$($seriesItem.Color)`" stroke-width=`"3`" points=`"$($segment -join ' ')`"/>")
            foreach ($point in $segment) {
                $coordinates = $point -split ','
                $svg.Add("<circle cx=`"$($coordinates[0])`" cy=`"$($coordinates[1])`" r=`"4.5`" fill=`"$($seriesItem.Color)`"/>")
            }
        }
    }
    $legendX = $left; $legendY = $height - 18
    $svg.Add("<line x1=`"$legendX`" y1=`"$legendY`" x2=`"$($legendX + 30)`" y2=`"$legendY`" stroke=`"#2563eb`" stroke-width=`"3`"/><text x=`"$($legendX + 40)`" y=`"$($legendY + 5)`" font-family=`"Arial, sans-serif`" font-size=`"15`" fill=`"#1f2937`">Imports</text>")
    $svg.Add("<line x1=`"$($legendX + 125)`" y1=`"$legendY`" x2=`"$($legendX + 155)`" y2=`"$legendY`" stroke=`"#d97706`" stroke-width=`"3`"/><text x=`"$($legendX + 165)`" y=`"$($legendY + 5)`" font-family=`"Arial, sans-serif`" font-size=`"15`" fill=`"#1f2937`">Exports</text>")
    $svg.Add('</svg>')
    [System.IO.File]::WriteAllLines($Path, $svg, [System.Text.UTF8Encoding]::new($false))
}

$periods = Get-TokenList $Period
Assert-PeriodInput -Periods $periods -Frequency $Frequency
$hsCodes = Get-TokenList $HsCode
$flowCodes = ConvertTo-FlowCodes $Flows

if ([string]::IsNullOrWhiteSpace($OutputDir)) {
    $stamp = Get-Date -Format 'yyyyMMdd_HHmmss'
    $OutputDir = Join-Path (Get-Location) ("uncomtrade_{0}_{1}_{2}_{3}" -f ($hsCodes -join '-'), $Frequency, ($periods -join '-'), $stamp)
}
New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null

$script:Headers = @{
    'Accept' = 'application/json, text/plain, */*'
    'Referer' = 'https://comtradeplus.un.org/TradeFlow'
    'User-Agent' = 'UN-Comtrade-Downloader-Skill/1.0'
}
$script:Session = New-Object Microsoft.PowerShell.Commands.WebRequestSession

$availabilityUrl = 'https://comtradeplus.un.org/api/DataAvailability/getDataAvailibilty?' + (@(
    'selectedProductOptions=C'
    "selectedFrequencyOptions=$Frequency"
    'selectedClassificationOptions=HS'
    'selectValueReportersModified=all'
    "selectValuePeriodsModified=$(Encode-QueryValue ($periods -join ','))"
) -join '&')

Write-Host "Fetching UN Comtrade data availability for $Frequency $($periods -join ', ')..."
$availabilityResponse = Invoke-JsonRequest -Uri $availabilityUrl
$availability = @($availabilityResponse.data)
$availabilityPath = Join-Path $OutputDir 'data_availability.csv'
$availability | Export-Csv -LiteralPath $availabilityPath -NoTypeInformation -Encoding UTF8

$reporterSelection = Resolve-CountrySelection -Value $Reporters -Availability $availability -Dimension 'reporter'
$partnerSelection = Resolve-CountrySelection -Value $Partners -Availability $availability -Dimension 'partner'
$selectedReporterCodes = if ($reporterSelection -eq 'all') { @($availability | Select-Object -ExpandProperty reporterCode -Unique) } else { @($reporterSelection -split ',') }
$selectedReporters = @($availability | Where-Object { $selectedReporterCodes -contains [string]$_.reporterCode } | Sort-Object reporterCode -Unique)
$downloadTargets = @($availability | Where-Object { $selectedReporterCodes -contains [string]$_.reporterCode } | Sort-Object reporterCode, period)

if ($selectedReporters.Count -eq 0) { throw 'No available reporters match the requested selection.' }
if ($AvailabilityOnly) {
    [pscustomobject]@{ OutputDir = $OutputDir; AvailabilityCsv = $availabilityPath; AvailableReporters = $availability.Count; SelectedReporters = $selectedReporters.Count } | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'run_metadata.json') -Encoding UTF8
    Write-Host "Availability saved to $availabilityPath"
    return
}

Get-CsrfToken
$requestsSinceCsrfRefresh = 0
$allRows = New-Object System.Collections.Generic.List[object]
$errors = New-Object System.Collections.Generic.List[object]
$emptyResults = New-Object System.Collections.Generic.List[object]
foreach ($reporter in $downloadTargets) {
    $reporterCode = [string]$reporter.reporterCode
    $reporterIso = [string]$reporter.reporterISO
    $reporterDesc = [string]$reporter.reporterDesc
    $targetPeriod = [string]$reporter.period
    Write-Host "Downloading $reporterDesc ($reporterIso), $targetPeriod..."
    if ($requestsSinceCsrfRefresh -ge $CsrfRefreshEveryRequests) {
        Get-CsrfToken
        $requestsSinceCsrfRefresh = 0
    }
    $body = @{
        selectedProductOptionsModified = 'C'
        selectedFrequencyOptionsModified = $Frequency
        selectedClassificationOptionsModified = 'HS'
        selectValuePeriodsModified = $targetPeriod
        selectValueReportersModified = $reporterCode
        selectValuePartnersModified = $partnerSelection
        selectValueTradeflowsModified = ($flowCodes -join ',')
        selectValueCommodityCodesModified = ($hsCodes -join ',')
        selectValueCustomsCodesModified = 'all'
        selectValueTransportCodesModified = 'all'
        selectValueSecondPartnersModified = 'all'
        selectValueAggregateByModified = 'none'
        selectValueBreakdownModeModified = 'classic'
        selectValueincludeDescModified = 'True'
        selectValuecountOnlyModified = 'False'
    }
    $query = @(
        'selectedProductOptionsModified=C'
        "selectedFrequencyOptionsModified=$Frequency"
        'selectedClassificationOptionsModified=HS'
        "selectValuePeriodsModified=$(Encode-QueryValue $targetPeriod)"
        "selectValueReportersModified=$(Encode-QueryValue $reporterCode)"
        "selectValuePartnersModified=$(Encode-QueryValue $partnerSelection)"
        "selectValueTradeflowsModified=$(Encode-QueryValue ($flowCodes -join ','))"
        "selectValueCommodityCodesModified=$(Encode-QueryValue ($hsCodes -join ','))"
        'selectValueCustomsCodesModified=all'
        'selectValueTransportCodesModified=all'
        'selectValueSecondPartnersModified=all'
        'selectValueAggregateByModified=none'
        'selectValueBreakdownModeModified=classic'
        'selectValueincludeDescModified=True'
        'selectValuecountOnlyModified=False'
    ) -join '&'
    $url = "https://comtradeplus.un.org/api/Trade/getDataComtrade?$query"
    $completed = $false
    $emptyResponseAttempts = 0
    for ($attempt = 1; $attempt -le $RetryCount -and -not $completed; $attempt++) {
        try {
            $response = Invoke-JsonRequest -Uri $url -Method Post -Body $body
            $requestsSinceCsrfRefresh++
            if ($response.error) { throw ([string]$response.error) }
            $responseRows = @($response.data | Where-Object { $null -ne $_ })
            if ($responseRows.Count -eq 0) {
                if ($emptyResponseAttempts -lt $EmptyResponseRetryCount -and $attempt -lt $RetryCount) {
                    $emptyResponseAttempts++
                    Get-CsrfToken
                    $requestsSinceCsrfRefresh = 0
                    Start-Sleep -Milliseconds ([math]::Max($RequestPauseMilliseconds, 1500))
                    continue
                }
                $emptyResults.Add([pscustomobject]@{ period = $targetPeriod; reporterCode = $reporterCode; reporterISO = $reporterIso; reporterDesc = $reporterDesc; attempts = $attempt }) | Out-Null
                $completed = $true
                if ($RequestPauseMilliseconds -gt 0) { Start-Sleep -Milliseconds $RequestPauseMilliseconds }
                continue
            }
            foreach ($row in $responseRows) { $allRows.Add($row) | Out-Null }
            $completed = $true
            if ($RequestPauseMilliseconds -gt 0) { Start-Sleep -Milliseconds $RequestPauseMilliseconds }
        } catch {
            if ($attempt -lt $RetryCount) { Start-Sleep -Seconds ([math]::Min(6 * $attempt, 15)) } else {
                $errors.Add([pscustomobject]@{ period = $targetPeriod; reporterCode = $reporterCode; reporterISO = $reporterIso; reporterDesc = $reporterDesc; error = $_.Exception.Message }) | Out-Null
            }
        }
    }
}

$rawPath = Join-Path $OutputDir 'uncomtrade_raw_records.csv'
$allRows | Export-Csv -LiteralPath $rawPath -NoTypeInformation -Encoding UTF8
$standardRows = @($allRows | ForEach-Object {
    [pscustomobject]@{
        Period = [string]$_.period
        ReporterM49 = [string]$_.reporterCode
        ReporterISO3 = [string]$_.reporterISO
        Reporter = [string]$_.reporterDesc
        FlowCode = [string]$_.flowCode
        Flow = if ([string]$_.flowCode -eq 'M') { 'Imports' } elseif ([string]$_.flowCode -eq 'X') { 'Exports' } else { [string]$_.flowDesc }
        PartnerM49 = [string]$_.partnerCode
        PartnerISO3 = [string]$_.partnerISO
        Partner = [string]$_.partnerDesc
        HSCode = [string]$_.cmdCode
        Commodity = [string]$_.cmdDesc
        Quantity = $_.qty
        QuantityUnit = [string]$_.qtyUnitAbbr
        NetWeightKg = $_.netWgt
        QuantityTonnes = Get-MetricValue -Row $_ -Metric QuantityTonnes
        PrimaryValueUSD = $_.primaryValue
        IsReported = $_.isReported
        IsAggregate = $_.isAggregate
    }
})
$standardPath = Join-Path $OutputDir 'uncomtrade_standardized_records.csv'
$standardRows | Export-Csv -LiteralPath $standardPath -NoTypeInformation -Encoding UTF8

$qualityRows = @($allRows | Where-Object { Test-QualityRow -Row $_ -Filter $QualityFilter } | ForEach-Object {
    [pscustomobject]@{
        Period = [string]$_.period; ReporterM49 = [string]$_.reporterCode; ReporterISO3 = [string]$_.reporterISO; Reporter = [string]$_.reporterDesc
        FlowCode = [string]$_.flowCode; Flow = if ([string]$_.flowCode -eq 'M') { 'Imports' } elseif ([string]$_.flowCode -eq 'X') { 'Exports' } else { [string]$_.flowDesc }
        PartnerM49 = [string]$_.partnerCode; PartnerISO3 = [string]$_.partnerISO; Partner = [string]$_.partnerDesc
        HSCode = [string]$_.cmdCode; Commodity = [string]$_.cmdDesc; Quantity = $_.qty; QuantityUnit = [string]$_.qtyUnitAbbr; NetWeightKg = $_.netWgt
        QuantityTonnes = Get-MetricValue -Row $_ -Metric QuantityTonnes; PrimaryValueUSD = $_.primaryValue; IsReported = $_.isReported; IsAggregate = $_.isAggregate
    }
})

# UN Comtrade usually labels the partner=World total as an aggregate/derived record.
# Preserve it, but fall back to the sum of quality-filtered bilateral records when
# the World total is absent or zero for a particular metric.
$worldRows = @($standardRows | Where-Object { [string]$_.PartnerM49 -eq '0' })
$worldSummary = @($worldRows | Group-Object Period, ReporterISO3, Reporter, FlowCode, Flow | ForEach-Object {
    $first = $_.Group[0]
    [pscustomobject]@{
        Period = $first.Period; ReporterM49 = $first.ReporterM49; ReporterISO3 = $first.ReporterISO3; Reporter = $first.Reporter; FlowCode = $first.FlowCode; Flow = $first.Flow
        QuantityTonnes = [math]::Round((($_.Group | Measure-Object -Property QuantityTonnes -Sum).Sum), 6)
        PrimaryValueUSD = [math]::Round((($_.Group | Measure-Object -Property PrimaryValueUSD -Sum).Sum), 2)
        IsReported = (($_.Group | Select-Object -ExpandProperty IsReported -Unique) -join ';')
        IsAggregate = (($_.Group | Select-Object -ExpandProperty IsAggregate -Unique) -join ';')
        RecordCount = $_.Count
    }
})
$worldSummaryPath = Join-Path $OutputDir 'reporter_world_total_summary.csv'
$worldSummary | Export-Csv -LiteralPath $worldSummaryPath -NoTypeInformation -Encoding UTF8

$bilateralSummary = @($qualityRows | Where-Object { [string]$_.PartnerM49 -ne '0' } | Group-Object Period, ReporterM49, ReporterISO3, Reporter, FlowCode, Flow | ForEach-Object {
    $first = $_.Group[0]
    [pscustomobject]@{
        Period = $first.Period; ReporterM49 = $first.ReporterM49; ReporterISO3 = $first.ReporterISO3; Reporter = $first.Reporter; FlowCode = $first.FlowCode; Flow = $first.Flow
        QuantityTonnes = [math]::Round((($_.Group | Measure-Object -Property QuantityTonnes -Sum).Sum), 6)
        PrimaryValueUSD = [math]::Round((($_.Group | Measure-Object -Property PrimaryValueUSD -Sum).Sum), 2)
        RecordCount = $_.Count
    }
})
$worldByKey = @{}
foreach ($row in $worldSummary) { $worldByKey["$($row.Period)|$($row.ReporterM49)|$($row.FlowCode)"] = $row }
$bilateralByKey = @{}
foreach ($row in $bilateralSummary) { $bilateralByKey["$($row.Period)|$($row.ReporterM49)|$($row.FlowCode)"] = $row }
$reporterTotalSummary = @(
    foreach ($key in @($worldByKey.Keys + $bilateralByKey.Keys | Select-Object -Unique)) {
        $world = if ($worldByKey.ContainsKey($key)) { $worldByKey[$key] } else { $null }
        $bilateral = if ($bilateralByKey.ContainsKey($key)) { $bilateralByKey[$key] } else { $null }
        $basis = if ($null -ne $world) { $world } else { $bilateral }
        $worldQuantity = if ($null -ne $world) { [double]$world.QuantityTonnes } else { 0.0 }
        $bilateralQuantity = if ($null -ne $bilateral) { [double]$bilateral.QuantityTonnes } else { 0.0 }
        $worldValue = if ($null -ne $world) { [double]$world.PrimaryValueUSD } else { 0.0 }
        $bilateralValue = if ($null -ne $bilateral) { [double]$bilateral.PrimaryValueUSD } else { 0.0 }
        $quantityUsesWorld = ($null -ne $world -and ($worldQuantity -gt 0 -or $bilateralQuantity -le 0))
        $valueUsesWorld = ($null -ne $world -and ($worldValue -gt 0 -or $bilateralValue -le 0))
        [pscustomobject]@{
            Period = $basis.Period; ReporterM49 = $basis.ReporterM49; ReporterISO3 = $basis.ReporterISO3; Reporter = $basis.Reporter; FlowCode = $basis.FlowCode; Flow = $basis.Flow
            QuantityTonnes = if ($quantityUsesWorld) { $worldQuantity } else { $bilateralQuantity }
            QuantityMethod = if ($quantityUsesWorld) { 'World total' } else { 'Sum of quality-filtered bilateral records' }
            PrimaryValueUSD = if ($valueUsesWorld) { $worldValue } else { $bilateralValue }
            ValueMethod = if ($valueUsesWorld) { 'World total' } else { 'Sum of quality-filtered bilateral records' }
            WorldQuantityTonnes = $worldQuantity; ReportedBilateralQuantityTonnes = $bilateralQuantity
            WorldPrimaryValueUSD = $worldValue; ReportedBilateralPrimaryValueUSD = $bilateralValue
        }
    }
)
$reporterTotalSummaryPath = Join-Path $OutputDir 'reporter_total_summary.csv'
$reporterTotalSummary | Export-Csv -LiteralPath $reporterTotalSummaryPath -NoTypeInformation -Encoding UTF8

$coverageNote = if ($emptyResults.Count -gt 0) { "Coverage caution: $($emptyResults.Count) reporter-period requests returned empty after retry; see empty_result_reporter_periods.csv" } else { '' }
$charts = New-Object System.Collections.Generic.List[object]
$chinaValidationExcludedPeriod = ''
foreach ($flow in @('M', 'X')) {
    $flowName = if ($flow -eq 'M') { 'importers' } else { 'exporters' }
    $flowRows = @($reporterTotalSummary | Where-Object { $_.FlowCode -eq $flow })
    foreach ($metric in @('QuantityTonnes', 'PrimaryValueUSD')) {
        $ranking = @($flowRows | Group-Object ReporterISO3, Reporter | ForEach-Object {
            $first = $_.Group[0]
            [pscustomobject]@{ ISO3 = $first.ReporterISO3; Country = $first.Reporter; Value = [double](($_.Group | Measure-Object -Property $metric -Sum).Sum) }
        } | Sort-Object Value -Descending | Select-Object -First 10)
        $rankingPath = Join-Path $OutputDir ("top10_{0}_{1}.csv" -f $flowName, $metric.ToLowerInvariant())
        $ranking | Export-Csv -LiteralPath $rankingPath -NoTypeInformation -Encoding UTF8
        if ($ranking.Count -gt 0) {
            $chartPath = Join-Path $OutputDir ("top10_{0}_{1}.svg" -f $flowName, $metric.ToLowerInvariant())
            $title = "Top 10 $flowName, HS $($hsCodes -join ', '), $($periods -join ', ')"
            $color = if ($flow -eq 'M') { '#2563eb' } else { '#d97706' }
            Write-BarChart -Rows $ranking -Title $title -Metric $metric -Path $chartPath -Color $color -Note $coverageNote
            $charts.Add([pscustomobject]@{ Chart = [System.IO.Path]::GetFileName($chartPath); Type = "Top 10 $flowName"; Metric = $metric }) | Out-Null
        }
    }
}

if (-not [string]::IsNullOrWhiteSpace($TimeSeriesReporter)) {
    $timeReporterCode = Resolve-CountrySelection -Value $TimeSeriesReporter -Availability $availability -Dimension 'time-series reporter'
    if ($timeReporterCode -match ',') { throw 'TimeSeriesReporter must name exactly one country.' }
    $timeSeriesPeriods = @($periods | Sort-Object)
    $validationNote = ''
    if ($timeReporterCode -eq '156' -and -not $IncludeLatestChinaValidationPeriod -and $timeSeriesPeriods.Count -gt 1) {
        $chinaValidationExcludedPeriod = $timeSeriesPeriods[$timeSeriesPeriods.Count - 1]
        $timeSeriesPeriods = @($timeSeriesPeriods | Where-Object { $_ -ne $chinaValidationExcludedPeriod })
        $validationNote = "Validation excludes latest requested period ($chinaValidationExcludedPeriod); raw download retains it."
    }
    $timeSeriesRows = @($reporterTotalSummary | Where-Object { $_.ReporterM49 -eq $timeReporterCode -and $timeSeriesPeriods -contains $_.Period })
    if ($timeSeriesRows.Count -eq 0) {
        Write-Warning "No reporter-total records were returned for $TimeSeriesReporter."
    } else {
        $timeSeriesPath = Join-Path $OutputDir 'selected_reporter_import_export_validation_timeseries.csv'
        $timeSeriesRows | Export-Csv -LiteralPath $timeSeriesPath -NoTypeInformation -Encoding UTF8
        $reporterName = $timeSeriesRows[0].Reporter
        foreach ($metric in @('QuantityTonnes', 'PrimaryValueUSD')) {
            $timePoints = @($timeSeriesRows | ForEach-Object { [pscustomobject]@{ Period = $_.Period; FlowCode = $_.FlowCode; Value = [double]$_.$metric } })
            $chartPath = Join-Path $OutputDir ("$($timeSeriesRows[0].ReporterISO3.ToLowerInvariant())_import_export_validation_timeseries_$($metric.ToLowerInvariant()).svg")
            Write-TimeSeriesChart -Rows $timePoints -Reporter $reporterName -Metric $metric -Path $chartPath -ExpectedPeriods $timeSeriesPeriods -ValidationNote $validationNote
            $charts.Add([pscustomobject]@{ Chart = [System.IO.Path]::GetFileName($chartPath); Type = "$reporterName import/export validation time series"; Metric = $metric }) | Out-Null
        }
    }
}

if ($errors.Count -gt 0) { $errors | Export-Csv -LiteralPath (Join-Path $OutputDir 'download_errors.csv') -NoTypeInformation -Encoding UTF8 }
if ($emptyResults.Count -gt 0) { $emptyResults | Export-Csv -LiteralPath (Join-Path $OutputDir 'empty_result_reporter_periods.csv') -NoTypeInformation -Encoding UTF8 }
$charts | Export-Csv -LiteralPath (Join-Path $OutputDir 'chart_manifest.csv') -NoTypeInformation -Encoding UTF8
$metadata = [pscustomobject]@{
    RetrievedAt = (Get-Date).ToString('o')
    Source = 'UN Comtrade Plus TradeFlow service'
    HSCode = ($hsCodes -join ',')
    Frequency = $Frequency
    Period = ($periods -join ',')
    ReporterSelection = $Reporters
    PartnerSelection = $Partners
    FlowSelection = ($flowCodes -join ',')
    QualityFilter = $QualityFilter
    TotalRule = 'Use World total when positive for a metric; otherwise sum quality-filtered bilateral records for the same reporter-period-flow'
    ChinaValidationLatestPeriodExcluded = $chinaValidationExcludedPeriod
    AvailableReporters = $availability.Count
    DownloadedRows = $allRows.Count
    QualityFilteredRows = $qualityRows.Count
    WorldTotalRows = $worldRows.Count
    ErrorCount = $errors.Count
    EmptyResultReporterPeriodCount = $emptyResults.Count
}
$metadata | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDir 'run_metadata.json') -Encoding UTF8
Write-Host "Completed. Results: $OutputDir"
