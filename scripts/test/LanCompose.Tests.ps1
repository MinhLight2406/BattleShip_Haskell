$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$repo = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
. (Join-Path $repo 'scripts/Start-LanCompose.ps1')
$testRoot = Join-Path $repo ('.stack-work/dk06/unit-' + [guid]::NewGuid())
[IO.Directory]::CreateDirectory($testRoot) | Out-Null
Copy-Item -LiteralPath (Join-Path $repo '.env.example') -Destination (Join-Path $testRoot '.env.example')
$passed = [Collections.Generic.List[string]]::new()
function Assert($Condition, [string]$Message = 'Assertion failed') { if (-not $Condition) { throw $Message } }
function Equal($Actual, $Expected) { Assert ((ConvertTo-Json -InputObject $Actual -Compress -Depth 6) -ceq (ConvertTo-Json -InputObject $Expected -Compress -Depth 6)) "Actual differs: $Actual / $Expected" }
function Fails([scriptblock]$Action, [string]$Pattern) {
    try { & $Action | Out-Null } catch { Assert ($_.Exception.Message -match $Pattern) $_.Exception.Message; return }
    throw "Expected failure: $Pattern"
}
function Check([string]$Name, [scriptblock]$Action) { & $Action; $passed.Add($Name); Write-Host "PASS $Name" }
$interfaces = @(
    [pscustomobject]@{Name='Loopback'; IsUp=$true; IsLoopback=$true; Addresses=@('127.0.0.1', '192.168.99.99')},
    [pscustomobject]@{Name='Wi-Fi'; IsUp=$true; IsLoopback=$false; Addresses=@('192.168.1.20', '2001:db8::1', '169.254.1.2')},
    [pscustomobject]@{Name='VPN'; IsUp=$true; IsLoopback=$false; Addresses=@('10.8.0.2')},
    [pscustomobject]@{Name='Ethernet 2'; IsUp=$false; IsLoopback=$false; Addresses=@('192.168.4.2')}
)
try {
    Check 'mixed loopback/Wi-Fi/VPN/IPv6/link-local adapters' {
        Equal @(Get-LanOrigins $interfaces '' '8081') @('http://10.8.0.2:8081', 'http://192.168.1.20:8081')
    }
    Check 'explicit Wi-Fi excludes VPN' { Equal @(Get-LanOrigins $interfaces 'Wi-Fi' '8099') @('http://192.168.1.20:8099') }
    Check 'down Ethernet with spaces and offline host yield no origins' {
        Equal @(Get-LanOrigins $interfaces 'Ethernet 2' '8081' -RequireInterface) @()
        Equal @(Get-LanOrigins @() '' '8081') @()
    }
    Check 'missing selected adapter errors at startup, disappears safely while watching' {
        Fails { Get-LanOrigins $interfaces 'missing' '8081' -RequireInterface } 'LAN_INTERFACE'
        Equal @(Get-LanOrigins @() 'Wi-Fi' '8081') @()
    }
    Check 'invalid/abbreviated/leading-zero/broadcast addresses are excluded' {
        $invalid = @([pscustomobject]@{Name='Wi-Fi'; IsUp=$true; IsLoopback=$false; Addresses=@('127.1','192.168.01.2','0x7f000001','0.0.0.0','255.255.255.255','bad','::1')})
        Equal @(Get-LanOrigins $invalid '' '8081') @()
    }
    Check 'addresses deduplicate across adapters; port 80 is canonical' {
        Equal @(Get-LanOrigins @($interfaces[1], $interfaces[1]) '' '80') @('http://192.168.1.20')
    }
    Check '16 origins accepted, 17 rejected' {
        $many = [pscustomobject]@{Name='Wi-Fi'; IsUp=$true; IsLoopback=$false; Addresses=@(1..16 | ForEach-Object { "192.168.1.$_" })}
        Assert (@(Get-LanOrigins @($many) '' '8081').Count -eq 16)
        $many.Addresses += '192.168.1.17'
        Fails { Get-LanOrigins @($many) '' '8081' } '16'
    }
    Check 'invalid public ports reject before writing' {
        foreach ($value in @('', '0', '08081', '65536', '-1', ' 8081', '1.5')) { Fails { Get-LanOrigins $interfaces '' $value } 'WEB_PUBLIC_PORT' }
    }
    Check 'Auto prepares mutually exclusive file mode and absolute host mount' {
        $settings = Get-LanSettings $testRoot @{Mode='Auto'; ConfigDir='lan'} @{}
        Equal $settings.Values.PUBLIC_ORIGIN ''
        Equal $settings.Values.LAN_ORIGINS_FILE '/run/battleship-lan/origins.json'
        Assert ([IO.Path]::IsPathRooted($settings.Directory))
    }
    Check 'env-file then shell precedence; flag must not conflict with shell' {
        $envPath = Join-Path $testRoot '.env'
        [IO.File]::WriteAllText($envPath, "WEB_PUBLIC_PORT=8090`n", [Text.UTF8Encoding]::new($false))
        Equal (Get-LanSettings $testRoot @{} @{}).Values.WEB_PUBLIC_PORT '8090'
        Equal (Get-LanSettings $testRoot @{} @{WEB_PUBLIC_PORT='8091'}).Values.WEB_PUBLIC_PORT '8091'
        Fails { Get-LanSettings $testRoot @{PublicPort='8092'} @{WEB_PUBLIC_PORT='8091'} } 'Conflicting shell'
        [IO.File]::Delete($envPath)
    }
    Check 'Localhost uses selected public port and no LAN file' {
        $settings = Get-LanSettings $testRoot @{Mode='Localhost'; PublicPort='80'} @{}
        Equal $settings.Values.PUBLIC_ORIGIN 'http://localhost'
        Equal $settings.Values.LAN_ORIGINS_FILE ''
    }
    Check 'Manual origin normalizes trailing slash and validates public port/address' {
        Equal (Get-LanSettings $testRoot @{Mode='Manual'; PublicOrigin='http://192.168.2.30:8081/'} @{}).Values.PUBLIC_ORIGIN 'http://192.168.2.30:8081'
        foreach ($origin in @('http://haskell:8081', 'http://192.168.2.30:8080', 'http://0.0.0.0:8081', 'http://192.168.02.30:8081', 'http://localhost:8081/a', 'http://localhost:8081?x=1', 'https://localhost:8081')) {
            Fails { Convert-LanManualOrigin $origin '8081' } 'PUBLIC_ORIGIN'
        }
    }
    Check 'shell origin/file conflicts are never silently overwritten' {
        Fails { Get-LanSettings $testRoot @{} @{PUBLIC_ORIGIN='http://localhost:8081'} } 'Conflicting shell PUBLIC_ORIGIN'
        Fails { Get-LanSettings $testRoot @{} @{LAN_ORIGINS_FILE='/wrong.json'} } 'Conflicting shell LAN_ORIGINS_FILE'
        Fails { Get-LanSettings $testRoot @{Mode='Localhost'} @{LAN_ORIGINS_FILE='/run/battleship-lan/origins.json'} } 'Conflicting shell'
        Fails { Get-LanSettings $testRoot @{PublicOrigin='http://localhost:8081'} @{} } 'requires -Mode Manual'
    }
    Check 'empty required config, wrong container HOST and bad internal port fail' {
        foreach ($environment in @(@{LAN_CONFIG_DIR=''}, @{WEB_PUBLIC_PORT=''}, @{HOST='127.0.0.1'}, @{PORT='0'})) {
            Fails { Get-LanSettings $testRoot @{} $environment } 'path|port|HOST'
        }
    }
    Check 'env parser rejects duplicates, interpolation and incomplete quotes' {
        $path = Join-Path $testRoot 'bad.env'
        foreach ($text in @("PORT=8080`nPORT=8081", 'PORT=${PORT}', 'PORT="8080', 'bad line')) {
            [IO.File]::WriteAllText($path, $text)
            Fails { Read-LanEnvFile $path } 'env|PORT'
        }
    }
    Check 'producer writes valid UTF-8 without BOM and preserves array for empty/singleton' {
        $path = Join-Path $testRoot 'origins.json'
        foreach ($origins in @(@(), @('http://192.168.1.20:8081'))) {
            Write-LanOrigins $path $origins
            $bytes = [IO.File]::ReadAllBytes($path)
            Assert ($bytes[0] -eq 123)
            $data = [IO.File]::ReadAllText($path) | ConvertFrom-Json
            Equal @($data.PSObject.Properties.Name) @('version','updatedAt','origins')
            Assert ($data.updatedAt -gt 0 -and $data.version -eq 1)
            Equal @($data.origins) $origins
        }
    }
    Check 'exclusive writer lock rejects second helper, can be reacquired after release' {
        $lock = Open-LanWriterLock $testRoot
        try { Fails { Open-LanWriterLock $testRoot } 'already owns' } finally { $lock.Dispose() }
        (Open-LanWriterLock $testRoot).Dispose()
    }
    Check 'failed replacement keeps old file and removes only its temporary file' {
        $path = Join-Path $testRoot 'blocked.json'
        Write-LanAtomicFile $path 'original'
        $blocked = [IO.File]::Open($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try { Fails { Write-LanAtomicFile $path 'replacement' } 'used|sharing|access|process' } finally { $blocked.Dispose() }
        Equal ([IO.File]::ReadAllText($path)) 'original'
        Assert (-not @(Get-ChildItem -LiteralPath $testRoot -Filter '*.tmp' -Force).Count)
    }
    Check 'effective env quotes paths with spaces/apostrophe and contains no unrelated keys' {
        $settings = Get-LanSettings $testRoot @{ConfigDir="with space'quote"} @{UNRELATED_SECRET='do-not-copy'}
        [IO.Directory]::CreateDirectory($settings.Directory) | Out-Null
        Write-LanComposeEnv $settings
        $text = [IO.File]::ReadAllText($settings.EnvPath)
        Assert ($text.Contains("space\'quote"))
        Assert (-not $text.Contains('UNRELATED_SECRET'))
        Equal (Read-LanEnvFile $settings.EnvPath).LAN_CONFIG_DIR $settings.Values.LAN_CONFIG_DIR
    }
    Write-Output ('SUMMARY ' + (ConvertTo-Json -InputObject @{passed=$passed.Count; cases=@($passed)} -Compress))
} finally {
    $safeRoot = [IO.Path]::GetFullPath((Join-Path $repo '.stack-work/dk06')) + [IO.Path]::DirectorySeparatorChar
    if (-not $testRoot.StartsWith($safeRoot, [StringComparison]::OrdinalIgnoreCase)) { throw 'Test cleanup escapes DK-06 directory.' }
    [IO.Directory]::Delete($testRoot, $true)
}
