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
# Linux: an agent run against the smoke tests' fake provider (no real API). The server inherits
# the test upstream (passed into WSL with WSLENV) and a fake key.
$fakeProvider = $null
$fpPort = 18092
$fpLog = "/tmp/fc-mcp-smoke-fp-$([guid]::NewGuid().ToString('N')).jsonl"
if ($Guest -eq 'linux') {
    $repoWsl = '/mnt/' + $RepoRoot.Substring(0, 1).ToLowerInvariant() + $RepoRoot.Substring(2).Replace('\', '/')
    $fakeProvider = Start-Process wsl.exe -ArgumentList @('-d', 'fc-host', '-u', 'root', '-e', 'python3', "$repoWsl/tests/smoke/fake-provider.py", "$fpPort", $fpLog) -WindowStyle Hidden -PassThru
    Start-Sleep -Seconds 2
    $env:FC_GATEWAY_TEST_UPSTREAM = "http://127.0.0.1:$fpPort"
    $env:WSLENV = if ($env:WSLENV) { "$($env:WSLENV):FC_GATEWAY_TEST_UPSTREAM" } else { 'FC_GATEWAY_TEST_UPSTREAM' }
    $env:ANTHROPIC_API_KEY = 'sk-mcp-smoke-fake'
}
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
    $want = @('sandbox_exec', 'sandbox_get', 'sandbox_list', 'sandbox_put', 'sandbox_recipe', 'sandbox_recipes', 'sandbox_run', 'sandbox_start', 'sandbox_stop')
    Expect "tools/list has exactly the nine sandbox tools" ((($tools -join ',') -eq ($want -join ',')))

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

    $both = Call-Tool 'sandbox_run' @{ command = 'true'; agent = 'claude'; prompt = 'x' }
    Expect "command and agent together are refused" ($both.isError -eq $true -and $both.content[0].text -match 'either command or agent')
    if ($Guest -eq 'linux') {
        $ag = Call-Tool 'sandbox_run' @{ agent = 'claude'; prompt = "Say hello; it's a `"test`""; timeout = '4m' }
        $agS = $ag.structuredContent
        Expect "agent run succeeds in gateway mode" ($ag.isError -ne $true -and $agS.exit_code -eq 0 -and $agS.agent.mode -eq 'gateway')
        Expect "agent transcript has the provider's reply" ($agS.transcript_path -and (Select-String -LiteralPath $agS.transcript_path -SimpleMatch 'FAKE-PROVIDER-REPLY' -Quiet))
        Expect "llm.log path is returned" ($agS.llm_log_path -and (Select-String -LiteralPath $agS.llm_log_path -SimpleMatch 'decision=forwarded' -Quiet))
        Expect "agent run output is marked untrusted" ($ag.content[0].text -match 'untrusted output produced inside a sandbox VM')

        # Recipes (Linux guests only): the list, a self-test, and the refusals.
        $recipes = (Call-Tool 'sandbox_recipes' @{}).structuredContent.recipes
        $rnames = @($recipes | ForEach-Object { $_.name } | Sort-Object) -join ','
        Expect "sandbox_recipes lists the eight starter recipes" ($rnames -eq 'agent-escape,agent-triage,detonate,npm-check,pip-check,probe,probe-net,triage-static')
        $npm = $recipes | Where-Object { $_.name -eq 'npm-check' }
        Expect "sandbox_recipes says networked recipes are not available here" ($npm.net -eq 'networked' -and $npm.available -match '^no: networked')
        $probe = Call-Tool 'sandbox_recipe' @{ name = 'probe' }
        $pS = $probe.structuredContent
        Expect "sandbox_recipe runs probe (exit 0, isolated)" ($probe.isError -ne $true -and $pS.exit_code -eq 0 -and $pS.recipe.name -eq 'probe' -and $pS.net -eq 'isolated')
        Expect "sandbox_recipe returns the report paths" ($pS.report_path -and (Select-String -LiteralPath $pS.report_path -SimpleMatch 'Sandbox self-test' -Quiet) -and (Test-Path -LiteralPath $pS.report_json_path))
        Expect "sandbox_recipe output is marked untrusted" ($probe.content[0].text -match 'untrusted output produced inside a sandbox VM')
        $tri = Call-Tool 'sandbox_recipe' @{ name = 'triage-static'; sample_path = (Join-Path $RepoRoot 'samples\hello\hello.sh') }
        Expect "sandbox_recipe uploads a sample from an allowed root" ($tri.isError -ne $true -and $tri.structuredContent.exit_code -eq 0 -and $tri.structuredContent.recipe.sample -eq 'hello.sh')
        $rnet = Call-Tool 'sandbox_recipe' @{ name = 'npm-check'; package = 'left-pad@1.3.0' }
        Expect "a networked recipe is refused without -AllowNetworked" ($rnet.isError -eq $true -and $rnet.content[0].text -match 'networked mode is disabled')
        $rout = Call-Tool 'sandbox_recipe' @{ name = 'triage-static'; sample_path = (Join-Path $env:SystemRoot 'System32\whoami.exe') }
        Expect "a sample outside the allowed roots is refused" ($rout.isError -eq $true -and $rout.content[0].text -match 'outside the allowed roots')
        $runk = Call-Tool 'sandbox_recipe' @{ name = 'nope' }
        Expect "an unknown recipe is refused, naming the recipes" ($runk.isError -eq $true -and $runk.content[0].text -match "unknown recipe 'nope' \(available: .*probe")
    }

    # Disconnect with the session still running: the server must destroy it before exiting.
    $stdin.Close()
    $exited = $server.WaitForExit(60000)
    Expect "server exits after stdin closes" $exited
    $list = & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 list -Guest $Guest 2>$null | Out-String
    Expect "no session VM left after disconnect" (-not ($list -match [regex]::Escape($sid)))
} finally {
    if (-not $server.HasExited) { $server.Kill() }
    if ($fakeProvider) {
        if (-not $fakeProvider.HasExited) { $fakeProvider.Kill() }
        & wsl.exe -d fc-host -u root -e sh -c "pkill -f 'fake-provider.py $fpPort ' ; rm -f $fpLog" 2>$null | Out-Null
    }
    $err = $errTask.Result
    if ($script:Fails) { Write-Host "server stderr:`n$err" }
}

if ($script:Fails) { Write-Host "mcp.ps1: $($script:Fails) check(s) failed"; exit 1 }
Write-Host "mcp.ps1: all checks passed"
exit 0
