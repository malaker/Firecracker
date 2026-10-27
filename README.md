# Firecracker Security Sandbox

Disposable, jailed [Firecracker](https://firecracker-microvm.github.io/) microVMs on Windows 11 through WSL2, built for security testing: detonating untrusted samples with no network at all, or running scanners and exploit tooling with tightly controlled outbound access. Everything is driven from PowerShell.

```
Windows (PowerShell)                 WSL2 distro "fc-host" (Ubuntu 24.04)
 .\fc.ps1 run ...  ---- wsl.exe --->  fcctl (root) --> jailer --> firecracker --> microVM (Ubuntu 24.04)
                                         |                          ^  SSH over vsock (control, files)
 runs\<run-id>\  <---- results ----------+                          |  tap + NAT (networked mode only)
```

## Features

- **One-command setup.** A dedicated WSL2 distro is created and provisioned with pinned, checksum-verified Firecracker, guest kernel and root filesystem. Re-running setup is safe and repairs only what is missing.
- **Disposable VMs.** Every VM boots from a fresh copy of the base image and is destroyed after use, so nothing a test changes survives.
- **Defence in depth.** Each VM runs under the Firecracker jailer: its own chroot, an unprivileged uid and cgroup CPU/memory limits.
- **Hard timeouts.** A detached watchdog enforces every VM's lifetime, even if the controller crashes.
- **Two network modes.** `isolated` has no network device at all. `networked` has NAT-ed egress with the host and private ranges blocked, plus an optional destination allowlist.
- **Simple results.** Each run's exit code, stdout/stderr, metadata and output files are collected into `runs\<run-id>\` on Windows.
- **Signed scripts.** The PowerShell entry points are Authenticode-signed and timestamped.

## Requirements

- Windows 11 with WSL 2 (a recent version that supports `wsl --install <distro> --name`)
- A CPU with hardware virtualization (Intel VT-x or AMD-V) enabled in firmware
- WSL2 nested virtualization (on by default on Windows 11; setup offers to enable it if needed)
- About 6 GB of free disk space and internet access during setup

Tested with Windows 11 build 26200, WSL 2.6.3 (kernel 6.6.87) and Firecracker v1.17.0.

VirtualBox is not supported. When Hyper-V is active (as it is whenever WSL2 runs), VirtualBox cannot expose nested VT-x to its guests, so Firecracker cannot start inside them.

## Quick start

From the repository root in PowerShell:

```powershell
.\fc.ps1 setup                                            # once; safe to re-run
.\fc.ps1 run -Payload .\samples\hello -Cmd 'sh ./in/hello.sh'
Get-ChildItem .\runs                                      # results, one folder per run
```

The run streams the guest's output and exits with the guest command's exit code. The expected output includes `Hello from fc-guest` and `Network interfaces: lo` (isolated mode: no network), and the result folder contains `out\whoami.txt`.

## Setup

`.\fc.ps1 setup [-Yes]` performs the following steps, skipping any that are already complete:

1. Creates the WSL distro `fc-host` (Ubuntu 24.04). Other distros are not modified.
2. Ensures `/dev/kvm` is available in it. If nested virtualization is off, setup offers to add `nestedVirtualization=true` under `[wsl2]` in `%USERPROFILE%\.wslconfig` (keeping a `.wslconfig.bak` backup) and to run `wsl --shutdown`. That restarts **all** WSL distros, including those used by Podman or Docker Desktop. Setup asks for confirmation unless `-Yes` is given. Declining leaves the system unchanged and exits with code 1.
3. Runs `host/provision.sh` inside `fc-host`, which:
   - installs the required packages and downloads the pinned Firecracker/jailer release, guest kernel and Ubuntu image (versions and SHA-256 sums are in [host/versions.env](host/versions.env)). A checksum mismatch stops setup and names the file.
   - builds the base disk image, generates the controller's SSH key, enables IP forwarding and creates the nftables table.
   - installs the controller into `/opt/fc-sandbox`.
4. Runs `.\fc.ps1 doctor`.

A repeated run downloads nothing and reports `all components are up to date`. After changing anything under `host/` or `images/`, re-run setup to copy the updated controller into the distro.

### Checking the host

```powershell
.\fc.ps1 doctor          # every precondition, PASS/FAIL with a hint; exit 0 only if all pass
.\fc.ps1 doctor -Boot    # additionally boots a small VM and runs a command in it
```

### Uninstalling

```powershell
wsl --unregister fc-host                         # deletes the distro and everything in it
# only if setup added it: restore %USERPROFILE%\.wslconfig from .wslconfig.bak (or remove the nestedVirtualization line)
Remove-Item -Recurse .\runs
```

## Commands

| Command | Description |
|---|---|
| `.\fc.ps1 run -Payload <dir> -Cmd '<command>' [options]` | Boot a VM, copy `<dir>` to `/work/in`, run the command in `/work`, collect results, destroy the VM |
| `.\fc.ps1 shell [options]` | Boot a VM and open an interactive root shell; the VM is destroyed on exit |
| `.\fc.ps1 start [options]` | Boot a VM in the background and print its run id |
| `.\fc.ps1 ssh <run-id> ['<command>']` | Open a shell in, or run a command in, a started VM |
| `.\fc.ps1 list` | List VMs: `running`, `dead` (process gone, e.g. after a WSL restart) or `kept` |
| `.\fc.ps1 stop <run-id>` | Destroy a VM (process, jail, disk copy, tap device and firewall rules) |
| `.\fc.ps1 cleanup` | Destroy every VM and remove all leftovers, including kept disks and orphans from crashes |
| `.\fc.ps1 doctor [-Boot]` | Run preflight checks |
| `.\fc.ps1 setup [-Yes]` | Create or repair the host |

Options for `run`, `shell` and `start`:

| Option | Default | Description |
|---|---|---|
| `-Net isolated\|networked` | `isolated` | Network mode (see below) |
| `-Allow <cidr>[,<cidr>...]` | none | Networked mode only: allow egress *only* to these destinations |
| `-Vcpu <n>` | 2 | vCPUs (1-32, at most the host's CPU count) |
| `-MemMib <n>` | 1024 | Guest memory in MiB (at least 128; must fit in free host memory) |
| `-Timeout <dur>` | `30m` | Hard lifetime, e.g. `90s`, `10m`, `1h` |
| `-Keep` | off | Keep the VM's disk after it stops, for inspection; removed by `stop` or `cleanup` |

VMs created with `start` are also subject to `-Timeout`.

## Network modes

**isolated** (default): the VM has **no network device**, only loopback. The controller reaches it over a virtio-vsock socket, so uploads and result collection still work.

**networked**: the VM gets `eth0` with a private /30 from `172.30.0.0/16` and NAT-ed outbound access through WSL. Firewall rules always block the guest from reaching:

- the WSL host and the Windows host (the WSL default gateway)
- other microVMs
- private, link-local, CGNAT, loopback and multicast ranges (`10/8`, `172.16/12`, `192.168/16`, `169.254/16`, `100.64/10`, `127/8`, `224/4`, `240/4`)
- all IPv6 destinations

With `-Allow`, *only* the listed CIDRs are reachable; private addresses become reachable only when listed explicitly. All other traffic is dropped, **including DNS**. The guest resolves names through `1.1.1.1` and `8.8.8.8`, so add `1.1.1.1/32` to the allowlist when a test needs name resolution.

```powershell
.\fc.ps1 run -Payload .\tests -Cmd './in/scan.sh' -Net networked -Allow 203.0.113.0/24,1.1.1.1/32 -Timeout 10m
```

> **Note:** traffic from networked VMs leaves through the Windows host, so targets see the host's public or LAN IP address. Use `isolated` mode for untrusted samples.

## Results

Every `run` writes `runs\<run-id>\` (run ids look like `20261027-183001-3461`):

| File | Content |
|---|---|
| `exit_code` | Exit code of the run |
| `stdout.log`, `stderr.log` | Output of the guest command, written as it runs (kept on timeout) |
| `out\` | Everything the command wrote to `/work/out` in the guest |
| `meta.json` | Run id, command, payload, network mode, allowlist, vCPU, memory, timeout, start/end time, `timed_out`, `error`, Firecracker version |

Exit codes: the guest command's own exit code; **124** when the run hit its timeout; **125** when the sandbox itself failed (boot, upload, missing payload). For commands that can themselves exit with 124 or 125, `timed_out` and `error` in `meta.json` tell the cases apart.

Inside the guest the payload is at `/work/in` and the working directory is `/work`, so `-Cmd './in/scan.sh'` runs a script from the payload. Files written to `out/` are copied back. Commands run as root. The guest image is a minimal Ubuntu 24.04 with `curl`, `socat`, `iproute2` and `openssh`. Additional tools can be installed in networked mode (`apt-get update && apt-get install -y nmap`).

## Security considerations and limitations

- Firecracker with the jailer provides strong isolation but is not a guarantee against KVM or Firecracker escape vulnerabilities. A successful escape would land in the `fc-host` WSL VM, which can access Windows drives through `/mnt/c`. For high-risk samples, set `[automount] enabled=false` in `fc-host`'s `/etc/wsl.conf`. Results then stay in `/var/lib/fc-sandbox/results` inside the distro, and `fc.ps1` (which runs scripts from `/mnt/c`) is unavailable until automount is re-enabled.
- VMs run inside WSL. `wsl --shutdown`, or Windows stopping WSL, terminates them; `list` then shows them as `dead` and `cleanup` removes the leftovers.
- Each VM receives a full sparse copy of the 2 GiB base image (about 1-2 seconds). Nested virtualization is slower than bare metal.
- All WSL2 distros share one network namespace. The `inet fc_sandbox` nftables table matches only `fc-tap-*` interfaces and `172.30.0.0/16`, so other distros are unaffected; avoid using `172.30.0.0/16` elsewhere.
- The controller connects to guests with host-key checking disabled. The channel is a root-owned local Unix socket and every guest boots from the same fresh image; the controller key should not be reused elsewhere.
- Only Linux guests are supported (a Firecracker limitation), and a single Ubuntu image is provided.
- The guest kernel and root filesystem come from Firecracker's public CI artifacts (the v1.15 set, the newest published). To upgrade, update [host/versions.env](host/versions.env), including the checksums, and re-run setup.

## Development

Run the end-to-end smoke tests inside `fc-host` from the repository root (about 5 minutes):

```powershell
wsl -d fc-host -u root -e bash tests/smoke/all.sh
```

Repository layout:

| Path | Purpose |
|---|---|
| [fc.ps1](fc.ps1) | Windows entry point |
| [windows/setup-host.ps1](windows/setup-host.ps1) | Creates and configures the `fc-host` distro |
| [host/provision.sh](host/provision.sh) | Provisions the distro (packages, binaries, images, controller) |
| [host/bin/fcctl](host/bin/fcctl), [host/lib/](host/lib/) | Linux-side controller |
| [images/build-rootfs.sh](images/build-rootfs.sh) | Builds the base guest image |
| [tests/smoke/](tests/smoke/) | End-to-end smoke tests |
| [openspec/](openspec/) | Specifications and the archived design and planning documents |

The PowerShell scripts are Authenticode-signed. Any edit invalidates the signature, so modified scripts must be re-signed, or run under an execution policy that permits unsigned local scripts.

## Responsible use

This project is intended for authorised security testing, malware analysis and research. Only test systems you own or have explicit permission to test.

## License

[MIT](LICENSE) © 2026 Krzysztof Balcerowski
