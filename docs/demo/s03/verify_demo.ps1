$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

function Assert-Demo($condition, [string]$message) {
    if (-not $condition) { throw "S-03: $message" }
}

$s03Repo = (Resolve-Path (Join-Path $PSScriptRoot '../../..')).Path
$s03Manifest = @(Import-Csv (Join-Path $PSScriptRoot 'source_sha256.csv'))
foreach ($entry in $s03Manifest) {
    $target = [IO.Path]::GetFullPath((Join-Path $s03Repo $entry.File))
    Assert-Demo ($target.StartsWith($s03Repo + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) 'Source path escapes repository'
    Assert-Demo ((Get-FileHash -LiteralPath $target -Algorithm SHA256).Hash -eq $entry.SHA256) "Source changed: $($entry.File)"
}

$s03Capture = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'raw_console.json') -Raw -Encoding utf8 | ConvertFrom-Json
foreach ($surface in @('server', 'P1', 'P2')) {
    $chunks = @($s03Capture.records | Where-Object surface -eq $surface)
    Assert-Demo ($chunks[-1].result.exit_code -eq 0) "$surface did not exit 0"
    foreach ($chunk in $chunks) {
        Assert-Demo (-not $chunk.result.output.Contains('Warning: truncated output')) "$surface console capture truncated"
    }
}

# Literal expected ship cells and shot results for this new demo, independent
# of Board/Rules implementations. These are an observer's oracle, not a stub.
$s03Fleets = @(
    @{'CV'=@('J1','J2','J3','J4','J5'); 'BB'=@('I7','I8','I9','I10'); 'CR'=@('A1','B1','C1'); 'SB'=@('A3','A4','A5'); 'DD'=@('H6','I6')},
    @{'CV'=@('E10','F10','G10','H10','I10'); 'BB'=@('A7','A8','A9','A10'); 'CR'=@('B1','B2','B3'); 'SB'=@('D4','E4','F4'); 'DD'=@('I1','I2')}
)
$s03Expected = @(
    @('J10:o','B1:X','J9:o','I1:X','J8:o','E10:X','F10:X','G10:X','H10:X','I10:#','A7:X','A8:X','A9:X','A10:#','B2:X','B3:#','D4:X','E4:X','F4:#','I2:*'),
    @('J10:o','J1:X','H10:o','A1:X','H9:o')
)
$s03Turn = 'P1'; $s03TurnChanges = 0; $s03Resolved = 0; $s03Winner = ''
foreach ($record in $s03Capture.records) {
    foreach ($shot in [regex]::Matches($record.result.output, '(?m)^Bạn bắn ([A-J](?:10|[1-9])): (trượt|trúng|chìm [^\r\n]+|thắng)\.\r?$')) {
        Assert-Demo ($s03Winner -eq '') 'Shot arrived after victory'
        Assert-Demo ($record.surface -eq $s03Turn) "Wrong actor fired: $($record.surface) instead of $s03Turn"
        $s03Resolved++
        if ($shot.Groups[2].Value -eq 'trượt') {
            $s03Turn = if ($s03Turn -eq 'P1') { 'P2' } else { 'P1' }
            $s03TurnChanges++
        } elseif ($shot.Groups[2].Value -eq 'thắng') { $s03Winner = $record.surface }
    }
}
Assert-Demo ($s03Resolved -eq 25 -and $s03TurnChanges -eq 6 -and $s03Winner -eq 'P1') 'Turn trace or final winner differs'
$s03Summary = @()
$s03CellChecks = 0
for ($player = 0; $player -lt 2; $player++) {
    $ownCells = @{}
    foreach ($ship in $s03Fleets[$player].Keys) {
        foreach ($coord in $s03Fleets[$player][$ship]) { $ownCells[$coord] = $ship }
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
                $s03CellChecks += 2
            }
        }
    }
    Assert-Demo (($shots -join ',') -eq ($s03Expected[$player] -join ',')) "P$($player + 1) outgoing results differ"
    Assert-Demo (($received -join ',') -eq ($s03Expected[1 - $player] -join ',')) "P$($player + 1) incoming results differ"
    Assert-Demo ($boards -eq 27) "P$($player + 1) board redraws missing"
    Assert-Demo ($boardRows -eq 270) "P$($player + 1) board rows missing"
    $hidden = @($s03Fleets[1 - $player].Values | ForEach-Object { $_ } | Where-Object { -not $outgoing.ContainsKey($_) })
    $s03Summary += [pscustomobject]@{Player="P$($player + 1)";Shots=$shots.Count;Incoming=$received.Count;Boards=$boards;UnknownTargetCells=(100 - $outgoing.Count);UnshotEnemyFleetCells=$hidden.Count}
}
$s03P1 = Get-Content (Join-Path $PSScriptRoot 'player1.log') -Raw -Encoding utf8
$s03P2 = Get-Content (Join-Path $PSScriptRoot 'player2.log') -Raw -Encoding utf8
Assert-Demo ($s03P1.Contains('Bạn thắng!') -and $s03P2.Contains('Bạn thua.')) 'Final winner messages missing'
Assert-Demo ($s03P1.Contains('Tọa độ phải nằm trong A1..J10.') -and $s03P1.Contains('Lỗi: đã bắn B1.')) 'Local error cases missing'
Assert-Demo ($s03P1.Contains('Đang chờ đối thủ.') -and $s03P1.Contains('Lỗi: tàu sân bay vượt mép bàn.')) 'Placement/waiting cases missing'

[pscustomobject]@{Passed=$true;SourceFiles=$s03Manifest.Count;Port=$s03Capture.port;ResolvedShots=$s03Resolved;TurnChanges=$s03TurnChanges;Winner=$s03Winner;BoardSnapshots=54;BoardCellsChecked=$s03CellChecks;Players=$s03Summary} | ConvertTo-Json -Depth 4
