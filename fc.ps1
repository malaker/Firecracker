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
    [ValidateSet('setup', 'doctor', 'run', 'shell', 'start', 'ssh', 'put', 'get', 'list', 'stop', 'cleanup', 'mcp', 'help')]
    [string]$Command = 'help',

    # run-id for stop/ssh/put/get, followed by a command (ssh), a host path (put) or a guest path (get).
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
    [switch]$Yes,

    # put: guest folder (default /work/in). get: host folder (default runs\<run-id>\files).
    [string]$Dest,

    # run: write {"run_id","results_dir"} to this file as soon as the VM has an id.
    [string]$RunInfoFile,

    # mcp: folders whose files the agent may upload (default: the current folder),
    # allow networked mode, and the concurrent session limit (default 4).
    [string[]]$AllowRoot,
    [switch]$AllowNetworked,
    [int]$MaxSessions,

    # setup (Linux): skip the agent image; Ollama URL for the codex-ollama profile.
    [switch]$NoAgentImage,
    [string]$OllamaUrl,

    # run/shell: AI agent profile (claude, codex, codex-ollama), its task (run), model, direct mode
    # (key inside a networked VM, no gateway) and token budget. Linux guests only.
    [string]$Agent,
    [string]$Prompt,
    [string]$PromptFile,
    [string]$Model,
    [switch]$AgentDirect,
    [long]$AgentTokenBudget
)

$ErrorActionPreference = 'Stop'
$Distro = 'fc-host'
$Fcctl = '/opt/fc-sandbox/bin/fcctl'

function ConvertTo-WslPath([string]$Path) {
    $full = (Resolve-Path -LiteralPath $Path).Path
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

# Like ConvertTo-WslPath, for a path that may not exist yet (relative to the current folder).
function ConvertTo-WslPathAny([string]$Path) {
    if (-not [System.IO.Path]::IsPathRooted($Path)) { $Path = Join-Path (Get-Location).ProviderPath $Path }
    $full = [System.IO.Path]::GetFullPath($Path)
    '/mnt/' + $full.Substring(0, 1).ToLower() + ($full.Substring(2) -replace '\\', '/')
}

if ($Command -eq 'help') {
    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') help
    exit $LASTEXITCODE
}

# MCP server over stdio (spec: sandbox-mcp-tools). stdout belongs to the protocol: nothing
# else may be written there, so fc-mcp.exe is started with the inherited stdio handles.
if ($Command -eq 'mcp') {
    $exe = & (Join-Path $PSScriptRoot 'mcp\install-mcp.ps1') -CheckOnly
    if ($LASTEXITCODE -ne 0 -or -not $exe) {
        [Console]::Error.WriteLine("[fc] ERROR: the MCP server is not built or is out of date; run '.\fc.ps1 setup' (needs the .NET 10 SDK).")
        exit 125
    }
    $mcpArgs = [System.Collections.Generic.List[string]]::new()
    $mcpArgs.Add('--repo-root'); $mcpArgs.Add($PSScriptRoot)
    foreach ($r in @($AllowRoot | Where-Object { $_ })) {
        $full = if ([System.IO.Path]::IsPathRooted($r)) { $r } else { Join-Path (Get-Location).ProviderPath $r }
        $mcpArgs.Add('--allow-root'); $mcpArgs.Add($full)
    }
    if ($AllowNetworked) { $mcpArgs.Add('--allow-networked') }
    if ($MaxSessions) { $mcpArgs.Add('--max-sessions'); $mcpArgs.Add("$MaxSessions") }
    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = @($exe)[-1]
    $psi.Arguments = ($mcpArgs | ForEach-Object { '"' + ($_ -replace '(\\*)"', '$1$1\"' -replace '(\\+)$', '$1$1') + '"' }) -join ' '
    $psi.UseShellExecute = $false
    $psi.WorkingDirectory = (Get-Location).ProviderPath
    $proc = [System.Diagnostics.Process]::Start($psi)
    $proc.WaitForExit()
    exit $proc.ExitCode
}

if ($Guest -eq 'linux') {
    foreach ($winFlag in @('Flavour', 'WinRuntime', 'ImageRepo', 'BuildFromSource', 'SourceDir', 'NanoBase')) {
        if ($PSBoundParameters.ContainsKey($winFlag)) {
            [Console]::Error.WriteLine("[fc] ERROR: -$winFlag is only valid with '-Guest windows'.")
            exit 125
        }
    }
}

if ($Agent -and $Guest -eq 'windows') {
    [Console]::Error.WriteLine("[fc] ERROR: agents need Linux guests (-Guest linux); Windows guests are not supported for -Agent.")
    exit 125
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
        & (Join-Path $PSScriptRoot 'mcp\install-mcp.ps1')
        if ($LASTEXITCODE) { [Console]::Error.WriteLine("[fc] WARNING: the MCP server was not built; 'fc.ps1 mcp' will not start.") }
        & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') doctor @commonWin
        exit $LASTEXITCODE
    }

    $winParams = $commonWin.Clone()
    if ($Command -in @('put', 'get')) {
        if (-not $Rest -or $Rest.Count -ne 2) {
            $what = if ($Command -eq 'put') { 'host-path' } else { 'guest-path' }
            [Console]::Error.WriteLine("[fc] ERROR: usage: fc.ps1 $Command <run-id> <$what> -Guest windows [-Dest <folder>]")
            exit 125
        }
        if ($Command -eq 'get') {
            $hostDest = if ($Dest) { $Dest } else { Join-Path $PSScriptRoot "runs\$($Rest[0])\files" }
            $winParams.Dest = if ([System.IO.Path]::IsPathRooted($hostDest)) { $hostDest } else { Join-Path (Get-Location).ProviderPath $hostDest }
        } elseif ($Dest) {
            $winParams.Dest = $Dest
        }
    }
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
        if ($RunInfoFile) {
            $winParams.RunInfoFile = if ([System.IO.Path]::IsPathRooted($RunInfoFile)) { $RunInfoFile } else { Join-Path (Get-Location).ProviderPath $RunInfoFile }
        }
    }

    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') @winParams
    exit $LASTEXITCODE
}

if ($Command -eq 'setup') {
    $hostSetup = @{ Yes = [bool]$Yes; NoAgentImage = [bool]$NoAgentImage }
    if ($OllamaUrl) { $hostSetup.OllamaUrl = $OllamaUrl }
    & (Join-Path $PSScriptRoot 'windows\setup-host.ps1') @hostSetup
    if ($LASTEXITCODE) { exit $LASTEXITCODE }
    & (Join-Path $PSScriptRoot 'mcp\install-mcp.ps1')
    if ($LASTEXITCODE) { [Console]::Error.WriteLine("[fc] WARNING: the MCP server was not built; 'fc.ps1 mcp' will not start.") }
    & $PSCommandPath doctor
    exit $LASTEXITCODE
}

$argv = [System.Collections.Generic.List[string]]::new()
$argv.Add($Command)
if ($Command -in @('put', 'get')) {
    if (-not $Rest -or $Rest.Count -ne 2) {
        $what = if ($Command -eq 'put') { 'host-path' } else { 'guest-path' }
        [Console]::Error.WriteLine("[fc] ERROR: usage: fc.ps1 $Command <run-id> <$what> [-Dest <folder>]")
        exit 125
    }
    $argv.Add($Rest[0])
    if ($Command -eq 'put') {
        if (-not (Test-Path -LiteralPath $Rest[1])) {
            [Console]::Error.WriteLine("[fc] ERROR: host path '$($Rest[1])' not found.")
            exit 125
        }
        $argv.Add((ConvertTo-WslPath $Rest[1]))
        if ($Dest) { $argv.Add($Dest) }
    } else {
        $argv.Add($Rest[1])
        $hostDest = if ($Dest) { $Dest } else { Join-Path $PSScriptRoot "runs\$($Rest[0])\files" }
        $argv.Add((ConvertTo-WslPathAny $hostDest))
    }
    $Rest = $null
}
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
    if ($RunInfoFile) { $argv.Add('--run-info-file'); $argv.Add((ConvertTo-WslPathAny $RunInfoFile)) }
}

# Agent runs (spec: sandbox-agents). The API key never goes on a command line: it is sent on the
# stdin of a separate wsl.exe call and referenced by a random, single-use name.
$keyRef = $null
$promptTemp = $null
if ($Agent) {
    if ($Command -notin @('run', 'shell')) {
        [Console]::Error.WriteLine("[fc] ERROR: -Agent works with run and shell.")
        exit 125
    }
    $profiles = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'host\agents\profiles.json') -Raw | ConvertFrom-Json
    $prof = $profiles.profiles.PSObject.Properties[$Agent]
    if (-not $prof) {
        [Console]::Error.WriteLine("[fc] ERROR: unknown agent profile '$Agent' (available: $(($profiles.profiles.PSObject.Properties.Name) -join ', ')).")
        exit 125
    }
    $prof = $prof.Value
    if ($Command -eq 'run') {
        if ([bool]$Prompt -eq [bool]$PromptFile) {
            [Console]::Error.WriteLine("[fc] ERROR: an agent run needs exactly one of -Prompt or -PromptFile.")
            exit 125
        }
        if ($Prompt) {
            $promptTemp = Join-Path ([System.IO.Path]::GetTempPath()) "fc-prompt-$([guid]::NewGuid().ToString('N')).md"
            [System.IO.File]::WriteAllText($promptTemp, $Prompt, (New-Object System.Text.UTF8Encoding($false)))
            $promptPath = $promptTemp
        } else {
            if (-not (Test-Path -LiteralPath $PromptFile -PathType Leaf)) {
                [Console]::Error.WriteLine("[fc] ERROR: prompt file '$PromptFile' not found.")
                exit 125
            }
            $promptPath = $PromptFile
        }
        $argv.Add('--prompt-file'); $argv.Add((ConvertTo-WslPath $promptPath))
    }
    if ($prof.auth -ne 'none') {
        $key = [Environment]::GetEnvironmentVariable([string]$prof.key_env)
        $keyFile = Join-Path $env:USERPROFILE ".fc-sandbox\keys\$($prof.provider).key"
        if (-not $key -and (Test-Path -LiteralPath $keyFile)) { $key = (Get-Content -LiteralPath $keyFile -TotalCount 1) }
        if (-not $key -or -not $key.Trim()) {
            [Console]::Error.WriteLine("[fc] ERROR: no API key for profile '$Agent': set $($prof.key_env) or put the key in $keyFile.")
            if ($promptTemp) { Remove-Item -LiteralPath $promptTemp -Force -ErrorAction SilentlyContinue }
            exit 125
        }
        $keyRef = [guid]::NewGuid().ToString('N')
        # Windows PowerShell 5.1 can prefix piped native input with a UTF-8 BOM, which would end up in
        # the auth header; pipe without one.
        $savedOutputEncoding = $OutputEncoding
        $OutputEncoding = New-Object System.Text.UTF8Encoding($false)
        $key.Trim() | & wsl.exe -d $Distro -u root -e $Fcctl _stash-key $keyRef
        $OutputEncoding = $savedOutputEncoding
        $key = $null
        if ($LASTEXITCODE -ne 0) {
            [Console]::Error.WriteLine("[fc] ERROR: could not hand the API key to fc-host.")
            exit 125
        }
        $argv.Add('--key-ref'); $argv.Add($keyRef)
    }
    $argv.Add('--agent'); $argv.Add($Agent)
    if ($Model) { $argv.Add('--model'); $argv.Add($Model) }
    if ($AgentTokenBudget) { $argv.Add('--token-budget'); $argv.Add("$AgentTokenBudget") }
    if ($AgentDirect) {
        # fcctl prints the warning that the key is inside the VM.
        $argv.Add('--agent-direct')
    }
} elseif ($Prompt -or $PromptFile -or $Model -or $AgentDirect -or $AgentTokenBudget) {
    [Console]::Error.WriteLine("[fc] ERROR: -Prompt, -PromptFile, -Model, -AgentDirect and -AgentTokenBudget need -Agent.")
    exit 125
}

# Pass arguments as one base64 blob of NUL-terminated values so wsl.exe can't
# mangle quotes or spaces inside -Cmd.
$blob = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((($argv | ForEach-Object { "$_`0" }) -join '')))
& wsl.exe -d $Distro -u root -e $Fcctl --argv-b64 $blob
$linuxRc = $LASTEXITCODE
# A stashed key is deleted once the gateway or guest has it; this catches runs that failed earlier.
if ($keyRef) { & wsl.exe -d $Distro -u root -e $Fcctl _drop-key $keyRef 2>$null | Out-Null }
if ($promptTemp) { Remove-Item -LiteralPath $promptTemp -Force -ErrorAction SilentlyContinue }

# When cleanup is called without -Guest, also clean up Windows microVMs; fcctl-win.ps1 knows
# where their state lives and is a no-op when there is none.
if ($Command -eq 'cleanup' -and (-not $PSBoundParameters.ContainsKey('Guest'))) {
    & (Join-Path $PSScriptRoot 'windows\fcctl-win.ps1') cleanup
    if ($LASTEXITCODE -and -not $linuxRc) { $linuxRc = $LASTEXITCODE }
}

exit $linuxRc
