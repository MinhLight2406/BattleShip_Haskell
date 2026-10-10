# Windows PowerShell 5.1+; dot-source to test functions without starting Docker.
[CmdletBinding()]
param(
    [ValidateSet('Auto', 'Localhost', 'Manual')][string]$Mode = 'Auto',
    [string]$LanInterface,
    [string]$PublicPort,
    [string]$ConfigDir,
    [string]$PublicOrigin,
    [string]$EnvFile,
    [string]$ComposeFile,
    [string]$ProjectName = 'battleship',
    [string]$DockerCommand,
    [switch]$WatchOnly
)

function Get-LanHostInterfaces {
    foreach ($adapter in [Net.NetworkInformation.NetworkInterface]::GetAllNetworkInterfaces()) {
        [pscustomobject]@{
            Name = $adapter.Name
            IsUp = $adapter.OperationalStatus -eq [Net.NetworkInformation.OperationalStatus]::Up
            IsLoopback = $adapter.NetworkInterfaceType -eq [Net.NetworkInformation.NetworkInterfaceType]::Loopback
            Addresses = @($adapter.GetIPProperties().UnicastAddresses | ForEach-Object { $_.Address.ToString() })
        }
    }
}

function Test-LanIPv4([string]$Address) {
    $parsed = $null
    return [Net.IPAddress]::TryParse($Address, [ref]$parsed) -and
        $parsed.AddressFamily -eq [Net.Sockets.AddressFamily]::InterNetwork -and
        $parsed.ToString() -ceq $Address
}

function Assert-LanPort([string]$Value, [string]$Name = 'WEB_PUBLIC_PORT') {
    if ($Value -cnotmatch '^[1-9][0-9]{0,4}$' -or [int]$Value -gt 65535) {
        throw "$Name must be a canonical decimal port from 1 to 65535."
    }
}

function Get-LanOrigins {
    param([object[]]$Interfaces, [string]$InterfaceName, [string]$Port, [switch]$RequireInterface)
    Assert-LanPort $Port
    if ($InterfaceName -and $RequireInterface -and -not @($Interfaces | Where-Object Name -eq $InterfaceName).Count) {
        throw "LAN_INTERFACE does not exist on the Windows host: $InterfaceName"
    }
    $suffix = if ($Port -eq '80') { '' } else { ':' + $Port }
    $origins = @($Interfaces | Where-Object {
        $_.IsUp -and -not $_.IsLoopback -and (-not $InterfaceName -or $_.Name -eq $InterfaceName)
    } | ForEach-Object { $_.Addresses } | Where-Object {
        (Test-LanIPv4 $_) -and $_ -notmatch '^(127\.|169\.254\.)' -and $_ -notin @('0.0.0.0', '255.255.255.255')
    } | ForEach-Object { "http://$_$suffix" } | Sort-Object -Unique)
    if ($origins.Count -gt 16) { throw 'More than 16 LAN origins; select one LAN_INTERFACE.' }
    return $origins
}

function Write-LanAtomicFile([string]$Path, [string]$Contents) {
    if (-not ('Battleship.LanAtomic' -as [type])) {
        Add-Type -TypeDefinition @'
using System.Runtime.InteropServices;
namespace Battleship {
    public static class LanAtomic {
        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        [return: MarshalAs(UnmanagedType.Bool)]
        public static extern bool MoveFileExW(string source, string destination, uint flags);
    }
}
'@
    }
    $temporary = Join-Path ([IO.Path]::GetDirectoryName($Path)) ('.' + [IO.Path]::GetFileName($Path) + '.' + [guid]::NewGuid() + '.tmp')
    try {
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($Contents)
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
        # Same-directory rename with REPLACE_EXISTING | WRITE_THROUGH; no delete-first gap.
        for ($attempt = 0; ; $attempt++) {
            if ([Battleship.LanAtomic]::MoveFileExW($temporary, $Path, 9)) { break }
            $nativeError = [Runtime.InteropServices.Marshal]::GetLastWin32Error()
            # Antivirus/readers can hold a Windows handle briefly; never retry indefinitely.
            if ($attempt -ge 9 -or $nativeError -notin @(5, 32, 33)) { throw [ComponentModel.Win32Exception]::new($nativeError) }
            Start-Sleep -Milliseconds 20
        }
    } finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Write-LanOrigins([string]$Path, [AllowEmptyCollection()][string[]]$Origins) {
    $data = [ordered]@{ version = 1; updatedAt = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds(); origins = @($Origins) }
    $json = ConvertTo-Json -InputObject $data -Compress -Depth 3
    if ([Text.Encoding]::UTF8.GetByteCount($json) -gt 8192) { throw 'LAN origins exceed 8 KiB.' }
    Write-LanAtomicFile $Path $json
}

function Open-LanWriterLock([string]$Directory) {
    try { return [IO.File]::Open((Join-Path $Directory '.helper.lock'), [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw 'A LAN helper already owns this directory, or its lock cannot be opened.' }
}

function Read-LanEnvFile([string]$Path) {
    $values = @{}
    foreach ($raw in [IO.File]::ReadAllLines($Path, [Text.Encoding]::UTF8)) {
        $line = $raw.Trim()
        if (-not $line -or $line.StartsWith('#')) { continue }
        if ($line -cnotmatch '^([A-Z][A-Z0-9_]*)=(.*)$') { throw "Invalid env declaration in $Path" }
        $key = $Matches[1]; $value = $Matches[2].Trim()
        if ($values.ContainsKey($key)) { throw "Duplicate env key: $key" }
        if ($value.StartsWith("'")) {
            if ($value.Length -lt 2 -or -not $value.EndsWith("'")) { throw "Unterminated env value: $key" }
            $value = $value.Substring(1, $value.Length - 2).Replace("\'", "'")
        } elseif ($value.StartsWith('"')) {
            if ($value.Length -lt 2 -or -not $value.EndsWith('"')) { throw "Unterminated env value: $key" }
            $value = $value.Substring(1, $value.Length - 2)
        }
        if ($value.Contains('$') -or $value.Contains("`r") -or $value.Contains("`n") -or $value.Contains([char]0)) {
            throw "Use a literal single-line env value for $key; interpolation is not supported by the LAN helper."
        }
        $values[$key] = $value
    }
    return $values
}

function Resolve-LanPath([string]$Root, [string]$Value) {
    if (-not $Value -or $Value.Contains("`n") -or $Value.Contains("`r") -or $Value.Contains([char]0)) { throw 'Invalid LAN configuration path.' }
    if (-not [IO.Path]::IsPathRooted($Value)) { $Value = Join-Path $Root $Value }
    return [IO.Path]::GetFullPath($Value)
}

function Convert-LanManualOrigin([string]$Value, [string]$Port) {
    if ($Value -notmatch '^http://(localhost|[0-9.]+)(?::([1-9][0-9]{0,4}))?/?$') { throw 'PUBLIC_ORIGIN must be a bare HTTP IPv4/localhost origin.' }
    $hostname = $Matches[1].ToLowerInvariant()
    $originPort = if ($Matches[2]) { $Matches[2] } else { '80' }
    Assert-LanPort $originPort 'PUBLIC_ORIGIN port'
    if ($originPort -ne $Port -or ($hostname -ne 'localhost' -and -not (Test-LanIPv4 $hostname)) -or
        $hostname -in @('0.0.0.0', '255.255.255.255')) { throw 'PUBLIC_ORIGIN must use a canonical address and match WEB_PUBLIC_PORT.' }
    if ($Port -eq '80') { return "http://$hostname" }
    return "http://${hostname}:$Port"
}

function Get-LanSettings {
    param([string]$Root, [hashtable]$Options, [Collections.IDictionary]$Environment)
    $values = Read-LanEnvFile (Join-Path $Root '.env.example')
    $source = if ($Options.ContainsKey('EnvFile')) { Resolve-LanPath $Root $Options.EnvFile }
        elseif ([IO.File]::Exists((Join-Path $Root '.env'))) { Join-Path $Root '.env' } else { $null }
    if ($source) {
        $fileValues = Read-LanEnvFile $source
        foreach ($key in @($values.Keys)) { if ($fileValues.ContainsKey($key)) { $values[$key] = $fileValues[$key] } }
    }
    foreach ($key in @($values.Keys)) { if ($Environment.Contains($key)) { $values[$key] = [string]$Environment[$key] } }
    foreach ($pair in @(@('PublicPort', 'WEB_PUBLIC_PORT'), @('ConfigDir', 'LAN_CONFIG_DIR'), @('LanInterface', 'LAN_INTERFACE'))) {
        if ($Options.ContainsKey($pair[0])) {
            if ($Environment.Contains($pair[1]) -and [string]$Environment[$pair[1]] -ne [string]$Options[$pair[0]]) {
                throw "Conflicting shell $($pair[1]); clear it before using -$($pair[0])."
            }
            $values[$pair[1]] = [string]$Options[$pair[0]]
        }
    }
    foreach ($key in @('WEB_PUBLIC_PORT', 'PORT', 'BATTLESHIP_TCP_PORT')) { Assert-LanPort $values[$key] $key }
    $directory = Resolve-LanPath $Root $values.LAN_CONFIG_DIR
    $values.LAN_CONFIG_DIR = $directory.Replace('\', '/')
    $mode = if ($Options.ContainsKey('Mode')) { $Options.Mode } else { 'Auto' }
    if ($mode -notin @('Auto', 'Localhost', 'Manual')) { throw 'Unknown LAN mode.' }
    if ($mode -ne 'Manual' -and $Options.ContainsKey('PublicOrigin')) { throw '-PublicOrigin requires -Mode Manual.' }
    if ($mode -eq 'Auto') { $origin = ''; $originFile = '/run/battleship-lan/origins.json' }
    else {
        $originFile = ''
        $candidate = if ($mode -eq 'Localhost') {
            if ($values.WEB_PUBLIC_PORT -eq '80') { 'http://localhost' } else { 'http://localhost:' + $values.WEB_PUBLIC_PORT }
        } elseif ($Options.ContainsKey('PublicOrigin')) { $Options.PublicOrigin } else { $values.PUBLIC_ORIGIN }
        $origin = Convert-LanManualOrigin $candidate $values.WEB_PUBLIC_PORT
    }
    foreach ($pair in @(@('PUBLIC_ORIGIN', $origin), @('LAN_ORIGINS_FILE', $originFile))) {
        if ($Environment.Contains($pair[0]) -and [string]$Environment[$pair[0]] -ne $pair[1]) {
            throw "Conflicting shell $($pair[0]); clear it before selecting $mode mode."
        }
        $values[$pair[0]] = $pair[1]
    }
    if ($values.HOST -ne '0.0.0.0') { throw 'Docker HOST must be 0.0.0.0; container loopback cannot serve the published port.' }
    return @{ Mode = $mode; Values = $values; Directory = $directory; EnvPath = (Join-Path $directory 'compose.env'); OriginPath = (Join-Path $directory 'origins.json') }
}

function Write-LanComposeEnv($Settings) {
    $lines = foreach ($key in ($Settings.Values.Keys | Sort-Object)) {
        $value = [string]$Settings.Values[$key]
        if ($value.Contains("`n") -or $value.Contains("`r") -or $value.Contains([char]0)) { throw "Invalid env value for $key" }
        $key + "='" + $value.Replace("'", "\'") + "'"
    }
    Write-LanAtomicFile $Settings.EnvPath (($lines -join "`n") + "`n")
}

function Invoke-LanCompose {
    param([string]$ProjectRoot, [hashtable]$Options)
    $ErrorActionPreference = 'Stop'
    Set-StrictMode -Version Latest
    if ([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT) { throw 'Run this helper on the Windows host, not inside a container.' }
    $settings = Get-LanSettings $ProjectRoot $Options ([Environment]::GetEnvironmentVariables('Process'))
    $compose = if ($Options.ContainsKey('ComposeFile')) { Resolve-LanPath $ProjectRoot $Options.ComposeFile } else { Join-Path $ProjectRoot 'compose.yaml' }
    $project = if ($Options.ContainsKey('ProjectName')) { $Options.ProjectName } else { 'battleship' }
    if ($project -cnotmatch '^[a-z0-9][a-z0-9_-]*$') { throw 'ProjectName must use lowercase letters, digits, underscore or hyphen.' }
    $watchOnly = $Options.ContainsKey('WatchOnly') -and $Options.WatchOnly
    if (-not $watchOnly) {
        if (-not [IO.File]::Exists($compose)) { throw 'Compose file is missing (DK-07). Use -WatchOnly to prepare and monitor LAN without starting Compose.' }
        $command = if ($Options.ContainsKey('DockerCommand')) { $Options.DockerCommand } else {
            $found = Get-Command docker -ErrorAction SilentlyContinue
            if ($found) { $found.Source } else {
                @((Join-Path $env:LOCALAPPDATA 'Programs/DockerDesktop/resources/bin/docker.exe'),
                  (Join-Path $env:ProgramFiles 'Docker/Docker/resources/bin/docker.exe')) | Where-Object { [IO.File]::Exists($_) } | Select-Object -First 1
            }
        }
        if (-not $command) { throw 'Docker CLI is missing; install/start Docker Desktop or use -DockerCommand.' }
    }
    $origins = @(if ($settings.Mode -eq 'Auto') {
        Get-LanOrigins -Interfaces @(Get-LanHostInterfaces) -InterfaceName $settings.Values.LAN_INTERFACE -Port $settings.Values.WEB_PUBLIC_PORT -RequireInterface
    } else { $settings.Values.PUBLIC_ORIGIN })
    [IO.Directory]::CreateDirectory($settings.Directory) | Out-Null
    $lock = Open-LanWriterLock $settings.Directory
    $job = $null
    try {
        if ($settings.Mode -eq 'Auto') { Write-LanOrigins $settings.OriginPath $origins }
        Write-LanComposeEnv $settings
        Write-Host ('Local UI: http://localhost' + $(if ($settings.Values.WEB_PUBLIC_PORT -eq '80') { '' } else { ':' + $settings.Values.WEB_PUBLIC_PORT }))
        Write-Host "Compose env: $($settings.EnvPath)"
        if (-not $watchOnly) {
            $arguments = @('compose', '--project-directory', $ProjectRoot, '--env-file', $settings.EnvPath, '-f', $compose, '-p', $project, 'up', '-d', '--wait', '--wait-timeout', '60')
            # Keep the host heartbeat fresh while Compose builds or waits for health.
            $job = Start-Job -ArgumentList $command,$arguments -ScriptBlock {
                param($executable, $arguments)
                & $executable @arguments 2>&1 | ForEach-Object { $_.ToString() }
                if ($LASTEXITCODE -ne 0) { throw "Docker Compose up failed (exit $LASTEXITCODE)." }
            }
        }
        $previous = $null
        do {
            $signature = $origins -join ','
            if ($signature -ne $previous) {
                foreach ($url in $origins) { Write-Host "Player URL: $url" }
                if (-not $origins.Count) { Write-Host 'No eligible LAN IPv4; localhost remains available.' }
                if ($settings.Mode -eq 'Auto' -and -not $settings.Values.LAN_INTERFACE -and $origins.Count -gt 1) {
                    Write-Host 'Several host addresses (possibly VPN/virtual adapters); select -LanInterface Wi-Fi or Ethernet.'
                }
                $previous = $signature
            }
            if ($job) {
                Receive-Job $job -ErrorAction Stop | ForEach-Object { Write-Host $_ }
                if ($job.State -in @('Failed', 'Stopped')) { throw 'Docker Compose startup failed or was interrupted.' }
                if ($job.State -eq 'Completed') { Remove-Job $job; $job = $null }
            }
            if ($settings.Mode -ne 'Auto' -and -not $job) { break }
            Start-Sleep -Milliseconds 2000
            if ($settings.Mode -eq 'Auto') {
                try {
                    $origins = @(Get-LanOrigins -Interfaces @(Get-LanHostInterfaces) -InterfaceName $settings.Values.LAN_INTERFACE -Port $settings.Values.WEB_PUBLIC_PORT)
                } catch { Write-Warning "LAN discovery failed; publishing an empty allowlist: $($_.Exception.Message)"; $origins = @() }
                Write-LanOrigins $settings.OriginPath $origins
            }
        } while ($true)
    } finally {
        if ($job) { Stop-Job $job; Remove-Job $job }
        $lock.Dispose()
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-LanCompose -ProjectRoot ([IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))) -Options $PSBoundParameters }
    catch { [Console]::Error.WriteLine("Battleship LAN helper: $($_.Exception.Message)"); exit 1 }
}
