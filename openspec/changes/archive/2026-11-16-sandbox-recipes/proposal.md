# Proposal

## Why

The sandbox ships two samples that only print facts about the guest. For any real test the user assembles the payload, command, network mode and timeout by hand, and the guest image lacks the tools for looking at a suspicious file. Now that agents can run inside the sandbox, ready-made recipes would make the common security tasks one command each: check that the sandbox holds, examine or detonate a sample, check what a package install does, or hand any of these to an agent.

## What Changes

- **Recipes.** A recipe is a folder under `recipes/` with a manifest (`recipe.json`) that fixes the command or agent prompt, the image, the network mode and the default resources, plus its scripts.
- **`fc.ps1 recipe` command.** `fc.ps1 recipe list` shows the recipes; `fc.ps1 recipe <name> [-Sample <path>] [-Package <spec>] [-Rules <dir>] [-Agent <profile>]` runs one as an ordinary run. The user's sample is uploaded straight from where it lies; it is never copied into the repository.
- **Eight starter recipes** (Linux guests only):
  - `probe` and `probe-net`: self-tests of the sandbox from inside, isolated and networked. They fail when the VM can reach something it should not.
  - `agent-escape`: an agent looks for ways out of the VM and reports its findings.
  - `agent-triage`: an agent examines a sample with the analysis tools, without running it.
  - `triage-static`: hashes, file type, strings, headers and optional YARA matches for a sample.
  - `detonate`: runs a sample under `strace` in an isolated VM and reports processes, changed files and connection attempts.
  - `npm-check` and `pip-check`: run a package install in a networked VM and report what it executed, wrote and connected to.
- **Analysis tools in the agent image.** The agent image gains `file`, binutils (`strings`, `readelf`, `objdump`), YARA, pip and `npm` on the path, pinned and checksum-verified like the rest of the image. Recipes that need the tools boot that image without an agent. The base image is unchanged.
- **MCP tools.** `sandbox_recipes` lists the recipes and `sandbox_recipe` runs one, under the existing path, network and agent rules.
- **Recipe results.** Every recipe writes `out/report.md` and `out/report.json`, and `meta.json` records the recipe.

Not in this change:

- A host-side connection log for Linux networked mode. `npm-check` and `pip-check` report connections from `strace` inside the guest, which is best-effort because the install runs as root there.
- Detonating Windows samples. Windows executables can go through `triage-static` and `agent-triage` only.
- Bundled YARA rules. The user supplies a rules folder.
- Direct-mode agents in recipes.

## Capabilities

### New Capabilities

- `sandbox-recipes`: named, ready-to-run test recipes: the manifest, the `recipe` command, how user input reaches the guest, the starter recipes and their reports.

### Modified Capabilities

- `sandbox-agents`: the agent image also contains the analysis tools, and recipe runs may boot it without an agent.
- `kvm-host-setup`: setup pins and verifies the analysis tool packages when building the agent image, installs the recipes into the controller, and `doctor` reports them.
- `sandbox-mcp-tools`: two new tools (`sandbox_recipes`, `sandbox_recipe`); the tool inventory and the host path confinement cover them.

## Impact

- **New files:** `recipes/<name>/` (manifest, scripts, prompts) for the eight recipes; `host/lib/recipe.sh`; a lock file of analysis tool packages under `images/agent/`; `tests/smoke/recipes.sh` and small test samples.
- **Changed code:** `fc.ps1` (new command and options), `host/bin/fcctl` (new command, second upload for recipe files), `host/provision.sh` and `images/build-agent-rootfs.sh` (tool packages, recipes sync), `host/lib/doctor.sh`, `host/versions.env`, `mcp/FcMcp` (two tools), `tests/smoke-mcp/mcp.ps1`, `README.md`.
- **Setup:** the agent image is rebuilt once (new inputs), with a few more downloads. No new prerequisites.
- **Compatibility:** existing commands, the base image and existing MCP tools behave as before. The MCP tool list grows from seven to nine.
- **Security:** recipes run only inside VMs. `detonate`, `npm-check` and `pip-check` execute untrusted code as root in the guest, as any payload already can. `npm-check` and `pip-check` need networked mode, with the usual host protection.
