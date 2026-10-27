# Proposal

## Why

Security tests (running untrusted samples, scanners, exploit tooling) need a throwaway, strongly isolated environment that starts in seconds and leaves nothing behind. Firecracker microVMs give that, but bringing one up by hand on a Windows 11 workstation (WSL2, nested KVM, kernel/rootfs images, networking, jailer) is slow and error-prone, so it needs to be a one-command, repeatable workflow.

## What Changes

- Add a one-time, idempotent host bootstrap that creates a dedicated WSL2 distro on this Windows PC, makes `/dev/kvm` available through nested virtualization, and installs pinned Firecracker/jailer binaries, a guest kernel and a base guest root filesystem.
- Add a preflight check (`doctor`) that reports whether the host can run microVMs and what to fix if not.
- Add a single Windows entry point (`fc.ps1`) that forwards to a Linux-side controller to start, list, stop and clean up microVMs.
- Every microVM runs from a disposable copy of the base image, under the Firecracker jailer, with configurable vCPU/memory and a hard timeout; it is destroyed after the run unless explicitly kept.
- Two network modes chosen per run: **isolated** (no network device at all) and **networked** (NAT egress, host and Windows-side addresses blocked, optional destination allowlist).
- A test-run workflow: upload a local folder into the VM, execute a command, and collect exit code, stdout/stderr and an output folder back into the project's `runs/<run-id>/` directory; plus an interactive shell mode.
- Documentation of setup, usage and known limitations.

## Capabilities

### New Capabilities
- `kvm-host-setup`: Bootstrapping and verifying the WSL2-based KVM host that runs microVMs (distro, nested virtualization, pinned binaries and images, preflight diagnostics).
- `microvm-lifecycle`: Creating, tracking, timing out and destroying disposable, jailed microVMs with configurable resources.
- `microvm-network-modes`: Per-run selection between a fully isolated VM and a NAT-networked VM with host protection and optional egress allowlist.
- `sandbox-test-runs`: Running a test payload inside a microVM (upload, execute, collect results) and opening an interactive shell.

### Modified Capabilities
<!-- None: the project has no existing specs. -->

## Impact

- New files in this repo: Windows wrapper script, Linux controller and helper scripts, image build script, smoke tests and docs.
- Windows host: adds a WSL2 distro (`fc-host`) and may add `nestedVirtualization=true` to `%USERPROFILE%\.wslconfig`, which requires `wsl --shutdown` (affects the existing `podman-machine-default` distro only by restarting WSL).
- External downloads: Firecracker release binaries from GitHub, and a guest kernel and Ubuntu rootfs from Firecracker's published CI artifacts, pinned by version and checked against checksums.
- No change to Hyper-V or VirtualBox configuration; VirtualBox is out of scope because nested VT-x is unavailable while Hyper-V is active.
