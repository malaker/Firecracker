<#
.SYNOPSIS
  Firecracker security sandbox: spin up disposable Linux (Firecracker) or Windows (Nano Server Hyper-V) microVMs.

.EXAMPLE
  .\fc.ps1 setup
  .\fc.ps1 setup -Guest windows -WinRuntime docker -ImageRepo malaker/nanoserver -Flavour aspnet-x86
  .\fc.ps1 doctor -Boot
  .\fc.ps1 doctor -Guest windows -Boot
  .\fc.ps1 run -Payload .\samples\hello -Cmd './in/hello.sh'
  .\fc.ps1 run -Guest windows -Payload .\samples\hello-win -Cmd '.\in\hello.cmd'
  .\fc.ps1 run -Payload .\tests -Cmd './in/scan.sh' -Net networked -Allow 203.0.113.0/24 -Timeout 10m
  .\fc.ps1 shell -Net networked
  .\fc.ps1 list
  .\fc.ps1 stop <run-id>
  .\fc.ps1 cleanup
#>
[CmdletBinding(PositionalBinding = $false)]
param(
    [Parameter(Position = 0)]
    [ValidateSet('setup', 'doctor', 'run', 'shell', 'start', 'ssh', 'list', 'stop', 'cleanup', 'help')]
    [string]$Command = 'help',

    # run-id for stop/ssh, optionally followed by a command for ssh.
    [Parameter(Position = 1, ValueFromRemainingArguments = $true)]
    [string[]]$Rest,

    [ValidateSet('linux', 'windows')]
    [string]$Guest = 'linux',

    [string]$Flavour,
    [ValidateSet('docker', 'containerd')]
    [string]$WinRuntime,
    [string]$ImageRepo,
    [switch]$BuildFromSource,
    [string]$SourceDir,
    [string]$NanoBase,

    [string]$Payload,
    [string]$Cmd,
    [ValidateSet('isolated', 'networked')]
    [string]$Net,
    [string[]]$Allow,
    [int]$Vcpu,
    [int]$MemMib,
    [string]$Timeout,
    [switch]$Keep,
    [switch]$Boot,
    [switch]$Yes
)

$ErrorActionPreference = 'Stop'
$Distro = 'fc-host'
$Fcctl = '/opt/fc-sandbox/bin/fcctl'

function ConvertTo-WslPath([string]$Path) {
    $full = (Resolve-Path -LiteralPath $Path).Path
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

if ($Command -eq 'help') {
    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') help
    exit $LASTEXITCODE
}

if ($Guest -eq 'linux') {
    foreach ($winFlag in @('Flavour', 'WinRuntime', 'ImageRepo', 'BuildFromSource', 'SourceDir', 'NanoBase')) {
        if ($PSBoundParameters.ContainsKey($winFlag)) {
            [Console]::Error.WriteLine("[fc] ERROR: -$winFlag is only valid with '-Guest windows'.")
            exit 125
        }
    }
}

if ($Guest -eq 'windows') {
    $commonWin = @{}
    if ($Flavour)    { $commonWin.Flavour    = $Flavour }
    if ($WinRuntime) { $commonWin.WinRuntime = $WinRuntime }
    if ($ImageRepo)  { $commonWin.ImageRepo  = $ImageRepo }

    if ($Command -eq 'setup') {
        $setupParams = $commonWin.Clone()
        $setupParams.Yes             = [bool]$Yes
        $setupParams.BuildFromSource = [bool]$BuildFromSource
        if ($SourceDir) { $setupParams.SourceDir = $SourceDir }
        if ($NanoBase)  { $setupParams.NanoBase  = $NanoBase }
        & (Join-Path $PSScriptRoot 'windows\setup-nanoserver.ps1') @setupParams
        if ($LASTEXITCODE) { exit $LASTEXITCODE }
        & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') doctor @commonWin
        exit $LASTEXITCODE
    }

    $winParams = $commonWin.Clone()
    $winParams.Command = $Command
    if ($Rest)    { $winParams.Rest    = $Rest }
    if ($Payload) { $winParams.Payload = $Payload }
    if ($PSBoundParameters.ContainsKey('Cmd')) { $winParams.Cmd = $Cmd }
    if ($Net)     { $winParams.Net     = $Net }
    if ($Allow)   { $winParams.Allow   = $Allow }
    if ($Vcpu)    { $winParams.Vcpu    = $Vcpu }
    if ($MemMib)  { $winParams.MemMib  = $MemMib }
    if ($Timeout) { $winParams.Timeout = $Timeout }
    if ($Keep)    { $winParams.Keep    = $true }
    if ($Boot)    { $winParams.Boot    = $true }
    if ($Command -eq 'run') {
        $runs = Join-Path $PSScriptRoot 'runs'
        New-Item -ItemType Directory -Force -Path $runs | Out-Null
        $winParams.ResultsDir = $runs
    }

    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') @winParams
    exit $LASTEXITCODE
}

if ($Command -eq 'setup') {
    & (Join-Path $PSScriptRoot 'windows\setup-host.ps1') -Yes:$Yes
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & $PSCommandPath doctor
    exit $LASTEXITCODE
}

$argv = [System.Collections.Generic.List[string]]::new()
$argv.Add($Command)
if ($Rest) { $argv.AddRange([string[]]$Rest) }
if ($Payload) {
    if (-not (Test-Path -LiteralPath $Payload -PathType Container)) {
        Write-Error "Payload folder '$Payload' not found." -ErrorAction Continue
        exit 125
    }
    $argv.Add('--payload'); $argv.Add((ConvertTo-WslPath $Payload))
}
if ($PSBoundParameters.ContainsKey('Cmd')) { $argv.Add('--cmd'); $argv.Add($Cmd) }
if ($Net)     { $argv.Add('--net'); $argv.Add($Net) }
if ($Allow)   { $argv.Add('--allow'); $argv.Add(($Allow -join ',')) }
if ($Vcpu)    { $argv.Add('--vcpu'); $argv.Add("$Vcpu") }
if ($MemMib)  { $argv.Add('--mem'); $argv.Add("$MemMib") }
if ($Timeout) { $argv.Add('--timeout'); $argv.Add($Timeout) }
if ($Keep)    { $argv.Add('--keep') }
if ($Boot)    { $argv.Add('--boot') }
if ($Command -eq 'run') {
    $runs = Join-Path $PSScriptRoot 'runs'
    New-Item -ItemType Directory -Force -Path $runs | Out-Null
    $argv.Add('--results-dir'); $argv.Add((ConvertTo-WslPath $runs))
}

# Pass arguments as one base64 blob of NUL-terminated values so wsl.exe can't
# mangle quotes or spaces inside -Cmd.
$blob = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((($argv | ForEach-Object { "$_`0" }) -join '')))
& wsl.exe -d $Distro -u root -e $Fcctl --argv-b64 $blob
$linuxRc = $LASTEXITCODE

# When cleanup is called without -Guest, also clean up Windows microVMs; fcctl-win.ps1 knows
# where their state lives and is a no-op when there is none.
if ($Command -eq 'cleanup' -and (-not $PSBoundParameters.ContainsKey('Guest'))) {
    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') cleanup
    if ($LASTEXITCODE -and -not $linuxRc) { $linuxRc = $LASTEXITCODE }
}

exit $linuxRc
