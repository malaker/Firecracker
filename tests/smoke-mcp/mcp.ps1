# mcp.ps1 - End-to-end smoke test of the sandbox MCP server over stdio (spec: sandbox-mcp-tools).
# Launches '.\fc.ps1 mcp' the way an MCP client does, talks JSON-RPC to it, then closes stdin and
# checks that the server destroyed its sessions. -Guest windows needs an elevated prompt.
param([ValidateSet('linux', 'windows')][string]$Guest = 'linux')
$ErrorActionPreference = 'Stop'
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1 = Join-Path $RepoRoot 'fc.ps1'
$script:Fails = 0
function Expect([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name"; $script:Fails++ }
}

Write-Host "== mcp ($Guest)"
$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = 'powershell.exe'
$psi.Arguments = "-NoProfile -ExecutionPolicy Bypass -File `"$FcPs1`" mcp"
$psi.WorkingDirectory = $RepoRoot
$psi.UseShellExecute = $false
$psi.RedirectStandardInput = $true
$psi.RedirectStandardOutput = $true
$psi.RedirectStandardError = $true
$psi.StandardOutputEncoding = New-Object System.Text.UTF8Encoding($false)
$server = [System.Diagnostics.Process]::Start($psi)
$errTask = $server.StandardError.ReadToEndAsync()
$stdin = New-Object System.IO.StreamWriter($server.StandardInput.BaseStream, (New-Object System.Text.UTF8Encoding($false)))
$stdin.AutoFlush = $true
$script:NextId = 0

function Send-Rpc([string]$Method, $Params, [switch]$Notify) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $Method }
    if ($null -ne $Params) { $msg.params = $Params }
    if (-not $Notify) { $script:NextId++; $msg.id = $script:NextId }
    $stdin.WriteLine(($msg | ConvertTo-Json -Depth 20 -Compress))
    if ($Notify) { return $null }
    while ($true) {
        $line = $server.StandardOutput.ReadLine()
        if ($null -eq $line) { throw "server closed stdout while waiting for '$Method'" }
        $resp = $line | ConvertFrom-Json
        if ($resp.PSObject.Properties['id'] -and $resp.id -eq $script:NextId) { return $resp }
    }
}
function Call-Tool([string]$Name, $Arguments) {
    (Send-Rpc 'tools/call' @{ name = $Name; arguments = $Arguments }).result
}

try {
    $init = Send-Rpc 'initialize' @{ protocolVersion = '2025-06-18'; capabilities = @{}; clientInfo = @{ name = 'fc-smoke'; version = '1.0' } }
    Expect "initialize answers with server info" ($init.result.serverInfo.name -eq 'fc-sandbox')
    Send-Rpc 'notifications/initialized' $null -Notify | Out-Null

    $tools = @((Send-Rpc 'tools/list' @{}).result.tools | ForEach-Object { $_.name } | Sort-Object)
    $want = @('sandbox_exec', 'sandbox_get', 'sandbox_list', 'sandbox_put', 'sandbox_run', 'sandbox_start', 'sandbox_stop')
    Expect "tools/list has exactly the seven sandbox tools" ((($tools -join ',') -eq ($want -join ',')))

    $payload = if ($Guest -eq 'linux') { 'samples\hello' } else { 'samples\hello-win' }
    $cmd = if ($Guest -eq 'linux') { 'sh ./in/hello.sh' } else { '.\in\hello.cmd' }
    $run = Call-Tool 'sandbox_run' @{ payload_path = (Join-Path $RepoRoot $payload); command = $cmd; guest = $Guest }
    Expect "sandbox_run succeeds" ($run.isError -ne $true -and $run.structuredContent.exit_code -eq 0)
    Expect "sandbox_run output is marked untrusted" ($run.content[0].text -match 'untrusted output produced inside a sandbox VM')

    $start = Call-Tool 'sandbox_start' @{ guest = $Guest; vcpu = 1; mem_mib = 256; timeout = '10m' }
    $sid = $start.structuredContent.session_id
    Expect "sandbox_start returns a session id" ($sid -match '^\d{8}-\d{6}-[0-9a-f]{4}$')
    # Windows VMs start with C:\work\out already there (a failing mkdir would leave errorlevel 1).
    $mk = if ($Guest -eq 'linux') { 'mkdir -p out && echo e2e > out/e2e.txt' } else { 'echo e2e> out\e2e.txt' }
    $exec = Call-Tool 'sandbox_exec' @{ session_id = $sid; command = $mk }
    Expect "sandbox_exec succeeds" ($exec.structuredContent.exit_code -eq 0)
    $outPath = if ($Guest -eq 'linux') { '/work/out' } else { 'C:\work\out' }
    $get = Call-Tool 'sandbox_get' @{ session_id = $sid; guest_path = $outPath }
    $file = @($get.structuredContent.files)[0]
    Expect "sandbox_get copies the file out" ($file -and (Get-Content -LiteralPath $file -Raw).Trim() -eq 'e2e')

    $foreign = Call-Tool 'sandbox_exec' @{ session_id = '20200101-000000-0000'; command = 'true' }
    Expect "unknown session id is refused" ($foreign.isError -eq $true)
    $net = Call-Tool 'sandbox_start' @{ net = 'networked' }
    Expect "networked mode is refused without -AllowNetworked" ($net.isError -eq $true -and $net.content[0].text -match 'networked mode is disabled')

    # Disconnect with the session still running: the server must destroy it before exiting.
    $stdin.Close()
    $exited = $server.WaitForExit(60000)
    Expect "server exits after stdin closes" $exited
    $list = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest $Guest 2>$null | Out-String
    Expect "no session VM left after disconnect" (-not ($list -match [regex]::Escape($sid)))
} finally {
    if (-not $server.HasExited) { $server.Kill() }
    $err = $errTask.Result
    if ($script:Fails) { Write-Host "server stderr:`n$err" }
}

if ($script:Fails) { Write-Host "mcp.ps1: $($script:Fails) check(s) failed"; exit 1 }
Write-Host "mcp.ps1: all checks passed"
