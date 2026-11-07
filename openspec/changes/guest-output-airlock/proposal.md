# Proposal

## Why

Every run copies the guest's output folder back to the host by unpacking a guest-made tar archive with the host's own `tar`: GNU tar as root inside `fc-host` for Linux guests, bsdtar in the elevated controller for Windows guests. That makes a large C archive parser, running with full rights, the first thing a hostile guest can attack, and planned features make it more pressing: agents running inside the sandbox (for example, asked to try to escape it) and the `get` command from `sandbox-mcp-server`. The host should never parse an archive a guest produced.

## What Changes

- Add an **airlock**: every guest-to-host file transfer goes through a fresh, disposable VM of the same guest OS (a Firecracker microVM for Linux guests, a Hyper-V Nano Server Utility VM for Windows guests), started in isolated mode, used for exactly one transfer and then destroyed.
- The host pulls the source VM's archive as opaque bytes (byte-capped, never parsed on the host) and pushes them unchanged into the airlock.
- A validator inside the airlock reads the tar stream entry by entry without extracting anything. It accepts only regular files and directories whose names are safe on NTFS, enforces size and count caps, and writes a `manifest.json` plus one blob of file contents with SHA-256 hashes.
- A host-side reader, running without administrator or root rights, applies the same rules again to the manifest, copies the declared byte ranges out of the blob, checks every hash, and writes the files into a fresh folder that is then moved into place.
- The validator and reader share one rules implementation in .NET 10, published as self-contained single-file binaries (`linux-x64` and `win-x64` validators, one Windows-side reader). The host pushes the validator into each airlock, so no image changes are needed.
- The airlock is **mandatory** for `run`'s output collection and is the transfer path for any later guest-to-host copy such as `get`. There is no direct-extraction fallback. Host-to-guest copies (payload upload, `put`) are unchanged.
- Airlock VMs follow the existing lifecycle rules (hard timeout, watchdog, `list`, `stop`, `cleanup`) and can be told apart from ordinary VMs.
- **BREAKING (setup prerequisites):** the .NET 10 SDK becomes required by every setup (`-Guest linux` and `-Guest windows`), because setup builds the airlock binaries. Today only Windows networked mode needs it.

## Capabilities

### New Capabilities
- `guest-output-airlock`: how files leave a guest: the airlock VM's lifecycle and isolation, opaque handling of guest archives on the host, the accepted entry types and name rules, size and count caps, the manifest and blob format, host-side re-validation, and how refusals are reported.

### Modified Capabilities
- `sandbox-test-runs`: result collection of the guest output folder goes through the airlock, and a refused or failed collection is recorded in the run's results instead of writing unchecked files.
- `microvm-lifecycle`: listing, stopping, timeout and cleanup also cover airlock VMs, which are marked as such.
- `kvm-host-setup`: setup builds the airlock binaries with the .NET 10 SDK, and `doctor` checks that they are present.
- `windows-microvm-host-setup`: Windows setup builds the airlock binaries, and `doctor -Guest windows` checks that they are present.

## Impact

- `host/lib/ssh.sh` and `host/bin/fcctl` (Linux collection path), `windows/lib/runtime.ps1` and `windows/fcctl-win.ps1` (Windows collection path), `fc.ps1` (runs the host-side reader after Linux runs).
- New .NET projects for the shared rules, the validator and the reader, with unit tests, and a setup step that builds them only when sources change, like the egress build.
- Every run gains one extra VM boot for output collection. The overhead will be measured on both backends before default caps and timeouts are fixed.
- `tests/smoke` and `tests/smoke-win`: collection through the airlock, refusal of hostile archives (links, devices, absolute and parent paths, NTFS-unsafe names, oversize), and no leftover airlock VMs.
- `README.md`: new prerequisite, the airlock in the architecture and security sections.
- Changes the plan for `sandbox-mcp-server`, which now uses the airlock for `get` instead of its own extraction check and is ordered after this change.
