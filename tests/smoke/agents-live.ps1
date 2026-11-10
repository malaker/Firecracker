# agents-live.ps1 - Live check of agent runs against the real providers (in-sandbox-agents, task 6.2).
# Opt-in: does nothing unless FC_AGENT_LIVE=1. Uses the keys fc.ps1 finds (ANTHROPIC_API_KEY /
# OPENAI_API_KEY or %USERPROFILE%\.fc-sandbox\keys\<provider>.key) and spends a few cents of tokens.
# codex-ollama runs only when the Ollama server answers. Run from Windows PowerShell:
#   $env:FC_AGENT_LIVE = '1'; .\tests\smoke\agents-live.ps1
param([string[]]$Profiles = @('claude', 'codex', 'codex-ollama'))
$ErrorActionPreference = 'Continue'
if ($env:FC_AGENT_LIVE -ne '1') { Write-Host "agents-live.ps1: skipped (set FC_AGENT_LIVE=1)"; exit 0 }
$RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
$FcPs1 = Join-Path $RepoRoot 'fc.ps1'
$script:Fails = 0
function Expect([string]$Name, [bool]$Ok) {
    if ($Ok) { Write-Host "  ok   $Name" } else { Write-Host "  FAIL $Name"; $script:Fails++ }
}
$prompt = 'Run `uname -a` and `id`, then write the two outputs to /work/out/facts.txt and reply with one short sentence.'

Write-Host "== agents (live)"
foreach ($p in $Profiles) {
    if ($p -eq 'codex-ollama') {
        $url = (& wsl.exe -d fc-host -u root -e bash -c '. /opt/fc-sandbox/lib/common.sh 2>/dev/null; . /opt/fc-sandbox/lib/agent.sh; agent_ollama_url' 2>$null | Select-Object -Last 1)
        $up = & wsl.exe -d fc-host -u root -e curl -fsS -m 3 -o /dev/null -w '%{http_code}' "$url/api/version" 2>$null
        if ($up -ne '200') { Write-Host "  skip codex-ollama (no Ollama at '$url')"; continue }
    }
    $err = Join-Path ([IO.Path]::GetTempPath()) "fc-live-$p.err"
    $t0 = Get-Date
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $FcPs1 run -Agent $p -Prompt $prompt -Timeout 10m 2> $err | Out-Null
    $rc = $LASTEXITCODE
    $secs = [int]((Get-Date) - $t0).TotalSeconds
    $line = Select-String -LiteralPath $err -Pattern 'results: .*/([^/ ]+) \(exit code' | Select-Object -Last 1
    $run = if ($line) { $line.Matches[0].Groups[1].Value } else { '' }
    $dir = Join-Path $RepoRoot "runs\$run"
    Expect "$p finishes with exit code 0 ($secs s)" ($rc -eq 0 -and $run)
    if (-not $run) { Get-Content $err | Select-Object -Last 5 | ForEach-Object { Write-Host "       $_" }; continue }
    $tr = Join-Path $dir 'out\agent-transcript.jsonl'
    Expect "$p transcript collected" ((Test-Path $tr) -and (Get-Item $tr).Length -gt 0)
    Expect "$p wrote out\facts.txt" (Test-Path (Join-Path $dir 'out\facts.txt'))
    $log = Join-Path $dir 'llm.log'
    $fwd = if (Test-Path $log) { @(Select-String -LiteralPath $log -SimpleMatch 'decision=forwarded').Count } else { 0 }
    Expect "$p llm.log has forwarded calls ($fwd)" ($fwd -gt 0)
    $meta = Get-Content (Join-Path $dir 'meta.json') -Raw | ConvertFrom-Json
    Write-Host "       run $run, $($meta.agent.client) $($meta.agent.client_version), model $($meta.agent.model), requests $($meta.agent.requests), tokens $($meta.agent.tokens)"
    Remove-Item $err -ErrorAction SilentlyContinue
}
if ($script:Fails) { Write-Host "agents-live.ps1: $($script:Fails) check(s) failed"; exit 1 }
Write-Host "agents-live.ps1: all checks passed"
exit 0
