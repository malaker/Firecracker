# state.ps1 - Per-VM state management and detached timeout watchdog for Windows microVMs.
# Change: nanoserver-windows-microvm
Set-StrictMode -Version Latest

function Get-FcWinVmDir([string]$RunId) {
    Join-Path (Get-FcWinVmsDir) $RunId
}

function Get-FcWinVmMetaPath([string]$RunId) {
    Join-Path (Get-FcWinVmDir $RunId) 'meta.json'
}

function Test-FcWinVmExists([string]$RunId) {
    if ([string]::IsNullOrWhiteSpace($RunId)) { return $false }
    return (Test-Path -LiteralPath (Get-FcWinVmMetaPath $RunId))
}

function Get-FcWinVmMeta([string]$RunId) {
    $path = Get-FcWinVmMetaPath $RunId
    if (-not (Test-Path -LiteralPath $path)) { return $null }
    try {
        return (Get-Content -LiteralPath $path -Raw | ConvertFrom-Json)
    } catch {
        return $null
    }
}

function Save-FcWinVmMeta([string]$RunId, $MetaObj) {
    $dir = Get-FcWinVmDir $RunId
    New-Item -ItemType Directory -Force -Path $dir | Out-Null
    $path = Get-FcWinVmMetaPath $RunId
    $tmp  = "$path.tmp"
    $MetaObj | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $tmp -Encoding utf8
    Move-Item -LiteralPath $tmp -Destination $path -Force
}

function Set-FcWinVmMetaProperty([string]$RunId, [string]$Key, $Value) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta) { return }
    $ht = [ordered]@{}
    foreach ($prop in $meta.PSObject.Properties) {
        $ht[$prop.Name] = $prop.Value
    }
    $ht[$Key] = $Value
    Save-FcWinVmMeta -RunId $RunId -MetaObj $ht
}

function Get-FcWinVmIds {
    $vmsDir = Get-FcWinVmsDir
    if (-not (Test-Path -LiteralPath $vmsDir)) { return @() }
    $dirs = Get-ChildItem -LiteralPath $vmsDir -Directory -ErrorAction SilentlyContinue | Sort-Object Name
    $ids = @()
    foreach ($d in $dirs) {
        if (Test-Path -LiteralPath (Join-Path $d.FullName 'meta.json')) {
            $ids += $d.Name
        }
    }
    return $ids
}

if (-not ('FcStdHandles' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;

public static class FcStdHandles
{
    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern IntPtr GetStdHandle(int which);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool GetHandleInformation(IntPtr handle, out uint flags);

    [DllImport("kernel32.dll", SetLastError = true)]
    public static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags);
}
'@
}

# Clears HANDLE_FLAG_INHERIT on this process's stdin/stdout/stderr and returns what to restore.
function Disable-FcStdHandleInheritance {
    $saved = @()
    foreach ($which in @(-10, -11, -12)) {
        $h = [FcStdHandles]::GetStdHandle($which)
        if ($h -eq [IntPtr]::Zero -or $h -eq [IntPtr]::new(-1)) { continue }
        [uint32]$flags = 0
        if ([FcStdHandles]::GetHandleInformation($h, [ref]$flags) -and ($flags -band 1)) {
            [void][FcStdHandles]::SetHandleInformation($h, 1, 0)
            $saved += $h
        }
    }
    return ,$saved
}

function Restore-FcStdHandleInheritance($Saved) {
    foreach ($h in @($Saved)) { [void][FcStdHandles]::SetHandleInformation($h, 1, 1) }
}

function Start-FcWinWatchdog([string]$RunId, [int]$LifetimeSec, [string]$ControllerScriptPath) {
    $b64Path = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($ControllerScriptPath))
    $b64Base = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((Get-FcWinBaseDir)))
    $script = @"
`$env:FC_WIN_BASE = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64Base'))
Start-Sleep -Seconds $LifetimeSec
`$ctrl = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$b64Path'))
& `$ctrl _expire '$RunId'
"@
    $encoded = [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($script))
    # The watchdog outlives this process. If it inherited our stdout/stderr pipes, a caller
    # capturing 'fc.ps1 start' output would wait for the watchdog, i.e. the VM's whole lifetime.
    $saved = Disable-FcStdHandleInheritance
    try {
        $proc = Start-Process -FilePath 'powershell.exe' `
            -ArgumentList @('-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-EncodedCommand', $encoded) `
            -PassThru
    } finally {
        Restore-FcStdHandleInheritance $saved
    }
    if ($proc -and $proc.Id) {
        Set-FcWinVmMetaProperty -RunId $RunId -Key 'watchdog_pid' -Value $proc.Id
    }
}

function Stop-FcWinWatchdog([string]$RunId) {
    $meta = Get-FcWinVmMeta $RunId
    if (-not $meta -or -not $meta.PSObject.Properties['watchdog_pid'] -or -not $meta.watchdog_pid) { return }
    $wpid = [int]$meta.watchdog_pid
    # Don't kill ourselves when the watchdog is the one destroying the VM (_expire).
    if ($wpid -eq $PID) { return }
    try {
        $p = Get-Process -Id $wpid -ErrorAction SilentlyContinue
        if ($p -and $p.ProcessName -match '^powershell|pwsh$') {
            Stop-Process -Id $wpid -Force -ErrorAction SilentlyContinue
        }
    } catch {}
}

# Writes runs\<run-id>\meta.json directly from the VM state object so callers
# don't duplicate field lists.
function Write-FcWinRunResultMeta {
    param(
        [Parameter(Mandatory = $true)][string]$ResultsDir,
        [Parameter(Mandatory = $true)][string]$RunId,
        [Parameter(Mandatory = $true)][string]$CommandText,
        [Parameter(Mandatory = $true)][string]$PayloadPath,
        $ExitCode = $null,
        [bool]$TimedOut = $false,
        [string]$ErrorMessage = ''
    )
    $vmMeta = Get-FcWinVmMeta $RunId
    if (-not $vmMeta) { return }

    New-Item -ItemType Directory -Force -Path $ResultsDir | Out-Null
    $endedAt = if ($null -eq $ExitCode) { $null } else { Get-IsoTimestamp }
    $errVal  = if ([string]::IsNullOrWhiteSpace($ErrorMessage)) { $null } else { $ErrorMessage }
    # PowerShell 7's ConvertFrom-Json turns ISO timestamps into DateTime; keep the ISO form.
    $startedAt = $vmMeta.started_at
    if ($startedAt -is [datetime]) { $startedAt = $startedAt.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ') }
    $meta = [ordered]@{
        run_id      = $RunId
        guest       = 'windows'
        flavour     = [string]$vmMeta.flavour
        image_repo  = [string]$vmMeta.image_repo
        win_runtime = [string]$vmMeta.win_runtime
        command     = $CommandText
        payload     = $PayloadPath
        net         = [string]$vmMeta.net
        allow       = [string]$vmMeta.allow
        vcpu        = [int]$vmMeta.vcpu
        mem_mib     = [int]$vmMeta.mem_mib
        timeout_sec = [int]$vmMeta.timeout_sec
        started_at  = [string]$startedAt
        ended_at    = $endedAt
        exit_code   = $ExitCode
        timed_out   = $TimedOut
        error       = $errVal
        keep_disk   = [bool]$vmMeta.keep_disk
    }
    $metaPath = Join-Path $ResultsDir 'meta.json'
    $tmpPath  = "$metaPath.tmp"
    $meta | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $tmpPath -Encoding utf8
    Move-Item -LiteralPath $tmpPath -Destination $metaPath -Force
}
