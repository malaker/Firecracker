# Tasks

## 1. Analysis tools in the agent image

- [x] 1.1 Spike (design D5): in a scratch copy of the agent image, unpack the candidate `.deb` files for `file`, binutils and YARA with `dpkg-deb -x`, run `ldconfig -r`, and install pip from a wheel; verify in a booted VM that `file`, `strings`, `readelf`, `objdump`, `yara`, `pip` and `npm` each run and that `yara` matches a test rule. Record the package closure, versions, snapshot timestamp and any fallback decision in design.md
- [x] 1.2 Add `images/agent/tools.lock` and the pip wheel pin in `host/versions.env`; make `host/provision.sh` download and verify them and include them in the agent image stamp; make `images/build-agent-rootfs.sh` unpack them and link `npm`/`npx`. Verify setup rebuilds the image once, a second setup does not, and a wrong checksum stops setup naming the file and keeps the old image
- [x] 1.3 Add a check to `tests/smoke/agents.sh` that every analysis tool reports a version in an agent VM, and list the tools in the README's agent image description; verify the check passes

## 2. Recipe command

- [x] 2.1 Add `host/lib/recipe.sh` with manifest loading and validation (design D2) and `fcctl recipe list [--json]`; sync `recipes/` in `host/provision.sh`; add the recipes check to `host/lib/doctor.sh`. Verify with a fixture folder (`FC_RECIPES_DIR` test override) that a valid recipe is listed and an invalid manifest is named by `list` and `doctor`
- [x] 2.2 Add `fcctl recipe <name>`: options from the manifest, the extra uploads and `recipe.env` (design D3, D4), the `recipe` object in `meta.json`, and every refusal (unknown recipe, fixed settings, missing or unaccepted input, bad package spec, bad entry, missing agent image). Verify with fixture recipes in a new `tests/smoke/recipes.sh` that a run produces results and each refusal exits 125 without starting a VM
- [x] 2.3 Add `recipe` to `fc.ps1` with `-Sample`, `-Package`, `-Rules`, `-Entry` and the `-Guest windows` refusal; reuse the agent key hand-over for agent recipes. Verify from both `powershell.exe` and `pwsh` that a sample path with spaces arrives as `/work/in/<name>` and that no extra host copy is made
- [x] 2.4 Document the `recipe` command, its options, the manifest and how to add a recipe in the README; verify each documented command runs as written

## 3. Sandbox self-test recipes

- [x] 3.1 Write `recipes/probe` and `recipes/probe-net` with the host facts hand-over (design D7) and their reports. Verify `probe` exits 0 with only loopback, `probe-net` exits 0 with host and private ranges blocked, and a fixture check expected `blocked` against an open port makes the run exit 1
- [x] 3.2 Add both probes to `tests/smoke/recipes.sh` and document them (what is tested, which hosts are contacted) in the README; verify the smoke part passes

## 4. Triage and detonation recipes

- [x] 4.1 Write `recipes/_lib/tracelib.py` (design D6) and a benign test sample under `tests/smoke/samples/` that drops a file, starts a process and attempts a connection. Verify the report built from its trace lists all three
- [x] 4.2 Write `recipes/triage-static` with optional rules. Verify on an ELF file, a PE file and a text file, with and without a rules folder, that `report.md` and `report.json` contain the hash, type, headers and matches the spec names
- [x] 4.3 Write `recipes/detonate` including the time limit, the folder sample with `-Entry`, and the not-runnable case. Verify with the test sample, a sample that never ends, and a sample exiting 7 that the run exits 0 and the report is as specified
- [x] 4.4 Add both recipes to `tests/smoke/recipes.sh` and document them, with the evidence limits and the antivirus note, in the README; verify the smoke part passes

## 5. Package check recipes

- [x] 5.1 Write `recipes/npm-check` and a local test package with a `postinstall` script. Verify the report names the script, its process and the file it wrote outside the install folder, for both `-Sample <folder>` and `-Package <name@version>`
- [x] 5.2 Write `recipes/pip-check` and a local test project with install-time code. Verify the report shows the process and file from that code, for both `-Sample <folder>` and `-Package <name==version>`
- [x] 5.3 Add both recipes to `tests/smoke/recipes.sh` and document them, with the guest-side evidence note, in the README; verify the smoke part passes

## 6. Agent recipes

- [x] 6.1 Write `recipes/agent-escape` and `recipes/agent-triage` with their prompts (design D9). Verify against the fake provider that the prompt, the sample and the rules folder arrive in the guest, the run is in gateway mode, and a missing profile or `-AgentDirect` exits 125
- [x] 6.2 Add both recipes to `tests/smoke/recipes.sh` and document them, with the best-effort report note, in the README; verify the smoke part passes

## 7. MCP tools

- [x] 7.1 Add `sandbox_recipes` and `sandbox_recipe` (with `entry`) to `mcp/FcMcp` (design D11) with unit tests for name validation, path confinement of sample and rules, the networked opt-in, the agent profile check, and that refusals call nothing; verify `dotnet test mcp` passes
- [x] 7.2 Add an opt-in integration test (`probe`, and `agent-triage` against the fake provider) and extend `tests/smoke-mcp/mcp.ps1` (nine tools listed, `sandbox_recipes`, a `probe` run, a networked recipe refused); verify both pass
- [x] 7.3 Document the two tools in the README's MCP section and add the recipe risks to "Security considerations and limitations"; verify the tool table matches `tools/list`

## 8. Integration

- [x] 8.1 Run the full Linux smoke suite, `dotnet test` for `gateway`, `mcp` and `airlock`, `dotnet test mcp` again with `FC_MCP_INTEGRATION=1` (the recipe integration tests from 7.2), the MCP smoke script and `openspec validate sandbox-recipes --strict`; verify all pass on a host set up from scratch with `.\fc.ps1 setup`. `dotnet test windows\egress` is not part of this check because the change does not touch the egress proxy

## Workflow follow-up

- Live check of the agent recipes with a real model (API keys or a local Ollama), together with the deferred live check from in-sandbox-agents.
- Archive the change after review.
