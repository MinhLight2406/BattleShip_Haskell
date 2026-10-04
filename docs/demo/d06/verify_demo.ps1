param([string]$Checkout = (Join-Path $PSScriptRoot '../../../.stack-work/d06-validation-20261005/checkout'))
$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Demo($condition, [string]$message) {
    if (-not $condition) { throw "D-06: $message" }
}

$d06Repo = (Resolve-Path -LiteralPath $Checkout).Path
$d06Metadata = Get-Content (Join-Path $PSScriptRoot 'checkout.json') -Raw -Encoding utf8 | ConvertFrom-Json
Assert-Demo ((& git -C $d06Repo rev-parse HEAD).Trim() -eq $d06Metadata.Snapshot) 'Wrong snapshot checkout'
Assert-Demo ((Get-FileHash (Join-Path $PSScriptRoot 'source.bundle')).Hash -eq $d06Metadata.BundleSHA256) 'Bundle hash differs'
$d06Manifest = @(Import-Csv (Join-Path $PSScriptRoot 'source_sha256.csv'))
foreach ($entry in $d06Manifest) {
    $target = [IO.Path]::GetFullPath((Join-Path $d06Repo $entry.File))
    Assert-Demo ($target.StartsWith($d06Repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Source path escapes repository'
    Assert-Demo ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $entry.SHA256) "Source changed: $($entry.File)"
}

$d06Capture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'raw_console.json') -Raw -Encoding utf8 | ConvertFrom-Json
foreach ($surface in @('server', 'P1', 'P2')) {
    $chunks = @($d06Capture.records | Where-Object surface -eq $surface)
    Assert-Demo ($chunks[-1].result.exit_code -eq 0) "$surface did not exit 0"
    foreach ($chunk in $chunks) {
        Assert-Demo (-not $chunk.result.output.Contains('Warning: truncated output')) "$surface console capture truncated"
    }
}

# Literal expected ship cells and shot results for this new demo, independent
# of Board/Rules implementations. These are an observer's oracle, not a stub.
$d06Fleets = @(
    @{'CV'=@('B6','C6','D6','E6','F6'); 'BB'=@('J2','J3','J4','J5'); 'CR'=@('D8','E8','F8'); 'SB'=@('A1','A2','A3'); 'DD'=@('H9','H10')},
    @{'CV'=@('E2','E3','E4','E5','E6'); 'BB'=@('F10','G10','H10','I10'); 'CR'=@('B1','C1','D1'); 'SB'=@('J6','J7','J8'); 'DD'=@('A9','B9')}
)
$d06Expected = @(
    @('E2:X','J10:o','E3:X','I9:o','E4:X','I8:o'),
    @('B6:X','J10:o','A1:X','J9:o','C6:X','D6:X','E6:X','F6:#','J2:X','J3:X','J4:X','J5:#','D8:X','E8:X','F8:#','A2:X','A3:#','H9:X','H10:*')
)
$d06Turn = 'P1'; $d06TurnChanges = 0; $d06Resolved = 0; $d06Winner = ''
foreach ($record in $d06Capture.records) {
    foreach ($shot in [regex]::Matches($record.result.output, '(?m)^Bạn bắn ([A-J](?:10|[1-9])): (trượt|trúng|chìm [^\r\n]+|thắng)\.\r?$')) {
        Assert-Demo ($d06Winner -eq '') 'Shot arrived after victory'
        Assert-Demo ($record.surface -eq $d06Turn) "Wrong actor fired: $($record.surface) instead of $d06Turn"
        $d06Resolved++
        if ($shot.Groups[2].Value -eq 'trượt') {
            $d06Turn = if ($d06Turn -eq 'P1') { 'P2' } else { 'P1' }
            $d06TurnChanges++
        } elseif ($shot.Groups[2].Value -eq 'thắng') { $d06Winner = $record.surface }
    }
}
Assert-Demo ($d06Resolved -eq 25 -and $d06TurnChanges -eq 5 -and $d06Winner -eq 'P2') 'Turn trace or final winner differs'
$d06Summary = @()
$d06CellChecks = 0
for ($player = 0; $player -lt 2; $player++) {
    $ownCells = @{}
    foreach ($ship in $d06Fleets[$player].Keys) {
        foreach ($coord in $d06Fleets[$player][$ship]) { $ownCells[$coord] = $ship }
    }
    $outgoing = @{}; $incoming = @{}; $shots = @(); $received = @(); $boards = 0; $boardRows = 0
    $lines = @(Get-Content -LiteralPath (Join-Path $PSScriptRoot "player$($player + 1).log") -Encoding utf8)
    foreach ($line in $lines) {
        if ($line -match '^(Bạn bắn|Đối thủ bắn) ([A-J](?:10|[1-9])): (.+)\.$') {
            $direction = $Matches[1]; $coord = $Matches[2]; $outcome = $Matches[3]
            $symbol = switch -Regex ($outcome) { '^trượt$' {'o'}; '^trúng$' {'X'}; '^chìm ' {'#'}; '^thắng$' {'*'}; default {throw "Unknown outcome $outcome"} }
            if ($direction -eq 'Bạn bắn') { $outgoing[$coord] = $symbol; $shots += "${coord}:$symbol" }
            else { $incoming[$coord] = $symbol; $received += "${coord}:$symbol" }
        }
        # Every live board row must exactly match only events already printed.
        if ($line.Length -ge 65 -and $line -match '^\s*(10|[1-9]) ') {
            $left = @($line.Substring(0, 32).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            $right = @($line.Substring(36).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
            Assert-Demo ($left.Count -eq 11 -and $right.Count -eq 11) 'Malformed board row'
            $row = [int]$left[0]
            $boardRows++
            Assert-Demo ($right[0] -eq $left[0]) 'Board rows do not align'
            if ($row -eq 1) { $boards++ }
            for ($column = 1; $column -le 10; $column++) {
                $coord = "$([char](64 + $column))$row"
                $expectedOwn = if ($incoming.ContainsKey($coord)) { $incoming[$coord] } elseif ($ownCells.ContainsKey($coord)) { $ownCells[$coord] } else { '.' }
                $expectedTarget = if ($outgoing.ContainsKey($coord)) { $outgoing[$coord] } else { '?' }
                Assert-Demo ($left[$column] -eq $expectedOwn) "P$($player + 1) own $coord is wrong"
                Assert-Demo ($right[$column] -eq $expectedTarget) "P$($player + 1) target $coord leaked or changed"
                $d06CellChecks += 2
            }
        }
    }
    Assert-Demo (($shots -join ',') -eq ($d06Expected[$player] -join ',')) "P$($player + 1) outgoing results differ"
    Assert-Demo (($received -join ',') -eq ($d06Expected[1 - $player] -join ',')) "P$($player + 1) incoming results differ"
    Assert-Demo ($boards -eq 27) "P$($player + 1) board redraws missing"
    Assert-Demo ($boardRows -eq 270) "P$($player + 1) board rows missing"
    $hidden = @($d06Fleets[1 - $player].Values | ForEach-Object { $_ } | Where-Object { -not $outgoing.ContainsKey($_) })
    $d06Summary += [pscustomobject]@{Player="P$($player + 1)";Shots=$shots.Count;Incoming=$received.Count;Boards=$boards;UnknownTargetCells=(100 - $outgoing.Count);UnshotEnemyFleetCells=$hidden.Count}
}
$d06P1 = Get-Content (Join-Path $PSScriptRoot 'player1.log') -Raw -Encoding utf8
$d06P2 = Get-Content (Join-Path $PSScriptRoot 'player2.log') -Raw -Encoding utf8
Assert-Demo ($d06P1.Contains('Bạn thua.') -and $d06P2.Contains('Bạn thắng!')) 'Final winner messages missing'
Assert-Demo ($d06P1.Contains('Tọa độ phải nằm trong A1..J10.') -and $d06P2.Contains('Lỗi: đã bắn B6.')) 'Local error cases missing'
Assert-Demo ($d06P1.Contains('SUA DD') -and $d06P1.Contains('Lỗi: tàu khu trục vượt mép bàn.') -and $d06P1.Contains('Đang chờ đối thủ.') -and $d06P1.Contains('Lỗi: tàu sân bay vượt mép bàn.')) 'Placement/waiting cases missing'

[pscustomobject]@{Passed=$true;SourceFiles=$d06Manifest.Count;Port=$d06Capture.port;ResolvedShots=$d06Resolved;TurnChanges=$d06TurnChanges;Winner=$d06Winner;BoardSnapshots=54;BoardCellsChecked=$d06CellChecks;Players=$d06Summary} | ConvertTo-Json -Depth 4

