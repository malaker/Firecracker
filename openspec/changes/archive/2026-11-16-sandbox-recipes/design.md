# Design

## Context

See proposal.md for motivation. What shapes the approach:

- **A run takes one payload.** `fcctl run` uploads one folder to `/work/in` and runs one command (`cmd_run` in `host/bin/fcctl`). A recipe needs its own scripts and the user's sample side by side.
- **The controller already owns similar data.** Agent profiles live in the repository, are synced to `/opt/fc-sandbox/agents` by `host/provision.sh`, and are read by `fcctl`. `fc.ps1` passes options through.
- **Two images exist.** `fcctl` accepts `--image base|agent`, but `fc.ps1` only selects the agent image through `-Agent`. A VM gets a gateway only when an agent profile is set, so booting the agent image without an agent already works in `vm_create`.
- **What the base image has** (checked with `debugfs` on the installed image): `python3`, `strace`, `perl`, `find`, `sha256sum`, `dpkg`, `apt`. It lacks `file`, binutils, YARA, pip and `jq`. The agent image adds Node.js, but `npm` is not on the path.
- **Images are built without running package code on the host.** The agent image is made by copying files into a loop-mounted copy of the base image; npm packages are installed with `--ignore-scripts`. Every download is pinned by checksum (`kvm-host-setup`, "Pinned and verified artifacts").
- **Linux networked mode logs nothing on the host** (`host/lib/net.sh` has no log or counter rules), so connection evidence can only come from inside the guest in this change.

## Goals / Non-Goals

**Goals:**

- One command per recipe, with the recipe fixing everything that affects safety (image, network mode, command).
- The user's sample goes from its folder into the guest with no extra copy on the host.
- Analysis tools pinned and installed without running their install scripts on the host.
- The same recipes reachable from the CLI, the Linux smoke suite and MCP.

**Non-Goals:**

- A host-side connection log, Windows guests, bundled YARA rules, direct-mode agents (see proposal.md).
- A plugin system. A recipe is a folder in the repository; there is no download or registry of recipes.
- Defeating samples that detect tracing.

## Decisions

### D1. The controller owns recipes

`host/provision.sh` syncs `recipes/` to `/opt/fc-sandbox/recipes`. A new `host/lib/recipe.sh` adds `fcctl recipe list [--json]` and `fcctl recipe <name> [options]`. `fc.ps1 recipe` converts host paths to WSL paths and passes everything through, as it does for `run`.

- **Why:** the manifest is validated in one place, the Linux smoke suite can run recipes inside `fc-host` without Windows, and it matches how agent profiles work.
- **Alternative: `fc.ps1` builds a merged payload folder and calls `run`.** Rejected: it copies the sample into a temporary host folder (a second copy of a suspicious file, which antivirus may also quarantine mid-run) and leaves the image choice to a Windows-side script.

### D2. Manifest

`recipes/<name>/recipe.json`, validated with `jq`; unknown keys are refused:

```json
{
  "description": "Hashes, file type, strings, headers and YARA matches for a sample",
  "kind": "command",
  "image": "agent",
  "net": "isolated",
  "command": "sh /work/recipe/run.sh",
  "input": { "sample": "required", "package": "none", "rules": "optional", "entry": "none" },
  "timeout": "10m", "vcpu": 2, "mem_mib": 1024
}
```

- `kind` is `command` (with `command`) or `agent` (with `prompt`, a file in the recipe folder).
- `image` is `base` or `agent`; `net` is `isolated` or `networked`.
- Each `input` is `none`, `optional` or `required`. `sample` and `package` may both be `optional` with `"one_of": ["sample", "package"]` for the package checks.
- `host_facts: true` (probes only) asks the controller to write the addresses the probe should test (D7).
- Recipe names match `^[a-z0-9][a-z0-9-]{0,40}$`. Folders starting with `_` are not recipes (`recipes/_lib` holds shared scripts, uploaded with every recipe).

### D3. Guest layout

| Guest path | Content |
|---|---|
| `/work/recipe` | the recipe's folder and `_lib` |
| `/work/in` | the sample: a folder's contents, or a single file under its own name |
| `/work/rules` | the YARA rules folder, when given |
| `/work/.fc/recipe.env` | recipe name, package spec, entry, detonation time, host facts |
| `/work/out` | `report.md`, `report.json`, raw evidence |

The package spec and entry travel in `recipe.env` over SSH stdin, never on a command line, and are validated first (spec: `^[A-Za-z0-9@._/~^<>=!,*+-]{1,200}$`; entry: relative, no `..`).

### D4. A recipe run is a normal run

`fcctl recipe <name>` sets the same options `run` uses from the manifest, then calls the existing run path. `cmd_run` gains a hook for the extra uploads (recipe folder, rules, `recipe.env`) between the payload upload and the command. An agent recipe sets the agent profile and uses the recipe's `prompt.md` as the prompt file, so key hand-over, the gateway, the transcript and `llm.log` work unchanged. `write_run_meta` gains a `recipe` object: `{name, kind, sample, package}`.

- **Why:** timeouts, the watchdog, the airlock and result collection stay in one code path.
- **Refusals** (`-Cmd`, `-Payload`, `-Net`, `-Allow`, `-AgentDirect` with `recipe`; missing or unaccepted inputs; missing agent image) happen in option checking, before any VM starts, with exit code 125.

### D5. Analysis tools from a package lock file

`images/agent/tools.lock` lists each `.deb` (name, version, URL, SHA-256). URLs point at `snapshot.ubuntu.com` for one pinned timestamp, so they do not disappear when Ubuntu publishes updates. `host/provision.sh` downloads and verifies them into the existing download cache. `images/build-agent-rootfs.sh` unpacks each with `dpkg-deb -x` into the image and runs `ldconfig -r` on it. pip comes as one pinned wheel from PyPI (SHA-256 in `host/versions.env`), unpacked to `/opt/pip` with a small `pip` wrapper. `npm` and `npx` get links in `/usr/local/bin`.

- **Why:** every byte is checksum-pinned, and no package install script runs on the host or as root against the image, the same properties the npm install has today.
- **Packages needed:** `file` (with `libmagic1t64`, `libmagic-mgc`), `binutils` (with its `binutils-common`, `binutils-x86-64-linux-gnu`, `libbinutils`, `libctf`, `libsframe`, `libgprofng` parts) and `yara` (with `libyara` and whatever it links that the base lacks). The exact closure and versions are fixed in the spike (task 1.1).
- **Alternative: `apt-get install` in a chroot of the image.** Rejected: unpinned unless a snapshot is configured anyway, and it runs maintainer scripts as root on `fc-host`.
- **Alternative: install inside a throwaway networked VM and keep its disk.** Safer than a chroot, but it needs new machinery to turn a VM disk into an image. Kept as the fallback if the spike shows a tool does not work without its maintainer scripts.
- **Not installed as packages:** `dpkg` does not know about the unpacked files. That is acceptable for a disposable image.

### D6. Tracing and reports

`detonate`, `npm-check` and `pip-check` share one Python module, `recipes/_lib/tracelib.py`, which runs the program under `strace`, parses the trace and writes the reports:

- **Trace:** `strace -f -qq -s 256 -o /work/trace.log` limited to process, file-write and network calls (`execve`, `connect`, `openat`, `creat`, `rename`, `unlink`, `mkdir`, `chmod`).
- **Changed files:** from the trace (writes, creates, renames, deletes), cross-checked with a listing of files newer than a marker created before the run.
- **Report:** a Python script turns the trace into `report.json` and `report.md` (the base image has `python3`; there is no `jq` in the guest).
- **Raw evidence:** the trace is copied to `out/` cut to 50 MiB, so it stays inside the airlock's limits.
- **Detonation time:** 120 s by default, then the process group is killed. The run's own `-Timeout` still bounds the whole recipe.
- **How a sample is started:** directly when it is an ELF file or has a `#!` line; by extension otherwise (`.sh`, `.py`, `.js`, `.pl`). Anything else is reported as not runnable, and the recipe still exits 0 with its report.

### D7. Probes

`probe` and `probe-net` use the base image, so they test the image most runs use. With `host_facts: true` the controller writes into `recipe.env` what the guest cannot know: the WSL host address, the Windows host address (the WSL default gateway), the microVM range and this VM's own gateway. The probe script then tries TCP connections to a fixed port list on each (plus `10.0.0.1`, `192.168.0.1`, `192.168.1.1`, `169.254.169.254`), an internet address by IP and by name, and vsock CID 2 on a few ports. It also records interfaces, routes, `/dev`, mounts, the kernel command line and CPU flags as information.

Each check has an expectation (`blocked` or `open`). A `blocked` check that connects sets exit code 1; an `open` check that fails is a warning.

### D8. Package checks

- **npm:** `npm install --foreground-scripts <spec | folder | tarball>` in `/work/pkg`, traced. The report lists install scripts declared in the installed tree (`preinstall`, `install`, `postinstall`, `prepare`) and which of them ran.
- **pip:** `pip install --no-input --target /work/pkg/site <spec | folder>`, traced. Source distributions run their build code, which is what the check is for.
- **Network:** networked without an allowlist, because registries sit behind CDNs. Host protection applies as always.
- **Connections:** reported as `IP:port` from `connect()` calls, with a note that names are not recorded and that the evidence is guest-side.

### D9. Agent recipes

The prompt files state that this is an authorised assessment of the user's own disposable sandbox, describe the task, and ask for `out/report.md`. `agent-triage` tells the agent the sample is at `/work/in`, lists the tools, and says not to execute the sample. A model may still refuse or ignore parts of a prompt, so the transcript, not the report, is the guaranteed output; agent recipes promise no `report.json`.

### D10. `fc.ps1`

`recipe` joins the command list; the first remaining argument is the recipe name or `list`. New options: `-Sample`, `-Package`, `-Rules`, `-Entry`. For agent recipes the existing agent block (profile lookup, key stash, `_drop-key`) runs for `recipe` too, without requiring `-Prompt`.

### D11. MCP

- `sandbox_recipes` calls `fc.ps1 recipe list -Json` and returns the list.
- `sandbox_recipe` validates the name, applies the path policy to `sample_path` and `rules_path`, reads the recipe's network mode from the list to apply the networked opt-in, refuses agent recipes without a profile, then calls `fc.ps1 recipe`. The result is built like `sandbox_run`'s, plus `recipe`, `report_path` and `report_json_path`.

### D12. Testing

- **Linux smoke suite** (`tests/smoke/recipes.sh`, in `all.sh`): each `command` recipe against small benign samples in `tests/smoke/samples/` (a script that drops a file, starts a process and attempts a connection; a local npm package and a local Python project with install-time code); refusals; `recipe list`. Agent recipes run against the existing fake provider and check that the prompt and sample arrive.
- **MCP:** unit tests for the argument checks with the fake runner, an opt-in integration test, and the MCP smoke script.
- **Limits:** `pip-check` on a local project still downloads its build backend, so that check needs internet, like the existing networked checks.

## Risks / Trade-offs

- [A tool does not work when unpacked without its install scripts] → Spike 1.1 decides before anything else is built; the fallback is the VM-based install in D5.
- [`snapshot.ubuntu.com` is unreachable during setup] → Downloads are cached and verified, so only the first build needs it; setup names the failing URL. `-NoAgentImage` still gives a working sandbox without the tool recipes.
- [A sample detects `strace` and stays quiet] → Stated in every trace-based report. Not solvable here.
- [Guest-side evidence in the package checks can be altered by the install] → Stated in the report; the host-side connection log is a planned follow-up.
- [A model refuses or drifts from an agent recipe's prompt] → The transcript is always collected; the README says the report is best-effort.
- [Antivirus on Windows blocks reading a real sample from the host folder] → Outside the sandbox's control; the README explains that the sample must be readable, for example in an excluded quarantine folder.
- [`npm-check` and `pip-check` run untrusted code with internet access] → Same exposure as any networked run: host and private ranges blocked, hard timeout, disposable VM. The VM holds nothing but the package.
- [The trace is large] → Cut to 50 MiB in `out/`; the report is built from the full trace before cutting.
- [`probe-net` connects to ports on the user's own hosts and a few private addresses] → Plain TCP connects to a short fixed list; documented.
- [The agent image grows and is rebuilt once] → A one-time cost at the next setup.

## Migration Plan

1. Re-running `.\fc.ps1 setup` downloads the tool packages, rebuilds the agent image once, installs the recipes and rebuilds the MCP server.
2. Rollback: check out the previous commit and re-run setup; the agent image is rebuilt from the old inputs.

## Spike results

**1.1 Tools from `.deb` files (2026-11-10):** the approach in D5 works; no fallback is needed.

- **The base image has no package database.** `/var/lib/dpkg` is empty, so `dpkg -i` or `apt` against the image was never an option; unpacking is the natural way.
- **Closure:** 15 packages, 4.9 MB of downloads, 28 MB unpacked: `file`, `libmagic1t64`, `libmagic-mgc` (1:5.45-3build1); `binutils`, `binutils-common`, `binutils-x86-64-linux-gnu`, `libbinutils`, `libctf0`, `libctf-nobfd0`, `libgprofng0`, `libsframe1` (2.42-4ubuntu2.10); `libjansson4` (2.14-2build2); `yara`, `libyara10` (4.5.0-1build2); `libprotobuf-c1` (1.4.1-1ubuntu4). Every library these need is either in the set or already in the base image (OpenSSL, zlib, zstd, libstdc++).
- **Snapshot:** `https://snapshot.ubuntu.com/ubuntu/20261101T000000Z/pool/...` served all 15 files with the SHA-256 sums the Ubuntu archive index lists.
- **pip:** `pip-26.3-py3-none-any.whl` from PyPI (SHA-256 `f3b60b20…940fad13`), unzipped to `/opt/pip` and started as `python3 /opt/pip/pip`, reports `pip 26.3 ... (python 3.12)`. No environment variable is needed.
- **In a booted agent VM** after unpacking and `ldconfig`: `file` 5.45, `strings`/`readelf`/`objdump` 2.42, `yara` 4.5.0 (matched a test rule), `pip` 26.3, `npm` 11.19.1 (through a link to `/opt/node/bin/npm`) and the base image's `strace` 6.8 all ran.
- **All packages unpack under `usr/` and `etc/` only**, so nothing collides with the image's merged `/usr` links.

## Open Questions

- The exact port list the probes test. It can change without changing the specs.
