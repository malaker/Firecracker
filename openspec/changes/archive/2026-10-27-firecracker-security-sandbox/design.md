# Design

## Context

- The repo is greenfield: only OpenSpec scaffolding exists, with no code and no specs.
- Host: Windows 11 (build 26200), Intel Core Ultra 9 275HX with VT-x, Hyper-V active, WSL 2.6.3 (kernel 6.6.87). The only WSL distro is `podman-machine-default`, which has no `/dev/kvm`, and there is no `%USERPROFILE%\.wslconfig`.
- VirtualBox is installed but runs on top of Hyper-V (NEM), where nested VT-x is not available, so it was ruled out (see proposal).
- Requirements are in `specs/`. Motivation is in proposal.md.

```
Windows 11
 |  fc.ps1 (PowerShell wrapper)
 |     |  wsl -d fc-host -u root -- /opt/fc-sandbox/bin/fcctl <cmd> ...
 v     v
WSL2 distro "fc-host" (Ubuntu 24.04, nested virt -> /dev/kvm)
 |  fcctl (bash controller)
 |   +-- state:  /var/lib/fc-sandbox/vms/<run-id>/   (meta, sockets, disk copy)
 |   +-- jailer --> firecracker (uid fc-<n>, chroot /srv/jailer/firecracker/<run-id>/root)
 |                     |  vsock (control: SSH)        tap-<id> (networked mode only)
 |                     v                                 |
 |               microVM: Ubuntu guest, sshd             +--> nftables: drop host/LAN,
 |                                                            allowlist, masquerade -> eth0
 +-- results copied to /mnt/c/sources/Firecracker/runs/<run-id>/
```

## Goals / Non-Goals

**Goals:**
- A single command for setup and a single command per test run, from PowerShell.
- The same control path (SSH over vsock) in both network modes, so isolated mode really has no NIC.
- Everything a run creates can be found and removed by `cleanup`.

**Non-Goals:**
- Running several hosts, cloud hosts or VirtualBox hosts. The Linux-side controller is plain bash and would port, but only WSL2 is supported and tested.
- Custom guest images beyond the one Ubuntu base. Users can install tools inside a kept VM or extend the build script later.
- Snapshots/restore, GPU or device passthrough, and Windows guests (Firecracker only runs Linux guests).
- Defending against Firecracker or KVM escape zero-days. The jailer is defense in depth, not a guarantee.

## Decisions

**D1: Dedicated WSL2 distro `fc-host` (Ubuntu 24.04), not the podman distro.**
This keeps the sandbox host separate from podman's container image and lets setup own it completely (`wsl --unregister fc-host` is a full reset). Setup imports it with `wsl --install -d Ubuntu-24.04 --name fc-host --no-launch`, and falls back to `wsl --import` from the Ubuntu WSL rootfs tarball. Alternative: reuse `podman-machine-default`. Rejected because podman manages that distro and may recreate it.

**D2: Nested virtualization through `.wslconfig` `[wsl2] nestedVirtualization=true`, edited with confirmation.**
Setup merges the key into the existing file instead of overwriting it (the file doesn't exist today), asks for confirmation, then runs `wsl --shutdown`. Afterwards `doctor` confirms `/dev/kvm` exists and gives the `kvm` group read/write access through a udev rule or a `chmod` at boot from `/etc/wsl.conf` `[boot] command=`.

**D3: Controller in bash (`fcctl`) plus `curl --unix-socket` for the Firecracker API, with a thin PowerShell wrapper.**
Firecracker is configured over a local HTTP API, and bash, curl and jq cover it with no runtime to install. The PowerShell wrapper only translates Windows paths (such as the payload folder) to `/mnt/c/...` and forwards arguments. Alternatives: Python (adds a dependency and packaging) or the `firectl` Go tool (unmaintained and doesn't drive the jailer the way we need). Each VM boots from a generated `--config-file` JSON, which keeps boot atomic. The API socket stays open for `SendCtrlAltDel`, metrics and shutdown.

**D4: Pinned upstream artifacts.**
`host/versions.env` records the Firecracker release version (the latest v1.x at implementation time) and SHA256 sums of the release tarball, the guest kernel (`vmlinux-6.1.x` from Firecracker's CI artifacts bucket, as used in the official getting-started guide) and the Ubuntu 24.04 squashfs. `images/build-rootfs.sh` turns the squashfs into an ext4 base image, installs `openssh-server`, `socat`, `python3`, `curl` and `iproute2`, adds a generated host SSH public key and a `/work` directory, and writes `rootfs.ext4` as read-only base.

**D5: Disposable disk via `cp --reflink=auto --sparse=always` into the jail.**
This is simple and supports the "never touches base" rule. On ext4 inside WSL a reflink isn't available, so it's a sparse copy that takes about 1 to 2 s for a 2 GB image, which is acceptable. Alternative: overlay with a read-only base drive plus a writable overlay drive inside the guest. That's faster but needs guest init changes, so it's deferred.

**D6: Control channel = SSH over Firecracker vsock (hybrid vsock UDS).**
In the guest, `socat VSOCK-LISTEN:22,fork TCP:127.0.0.1:22` runs as a systemd unit. On the host, an SSH `ProxyCommand` helper connects to the VM's vsock UDS and sends `CONNECT 22\n`. This gives `ssh` (exec, interactive shell, exit codes) and `scp`/`tar` streaming for upload and download in both modes, without any guest NIC in isolated mode. Alternatives: a serial console (no clean exit codes or file transfer) or SSH over the TAP device (impossible in isolated mode).

**D7: Networking with nftables in a dedicated table `inet fc_sandbox`.**
Networked VMs get `fc-tap-<slot>` with a /30 from `172.30.0.0/16`. The guest address, route and resolvers are applied over the vsock SSH channel right after boot (with `ip addr replace`, because the CI image's own boot script already derives the same address from the guest MAC `06:00:ac:1e:..`), so no DHCP is needed and the kernel cmdline stays the same in both modes. Rules for each VM run in a per-VM chain: drop to the WSL host addresses, the Windows host (the WSL default gateway), RFC1918, link-local and the 172.30.0.0/16 range of other VMs, except entries on the allowlist. When an allowlist is given, only those CIDRs are accepted. Then masquerade out through `eth0`. Deleting the per-VM chain and TAP covers teardown. Alternative: iptables. Rejected because nftables gives atomic per-VM tables and chains that are easy to clean up. Note: since WSL NAT egress goes through Windows, external targets see the Windows machine's IP.

**D8: Jailer with a uid/gid allocated per VM from a range (`fc-sandbox` base uid 64000+n).**
Each VM gets a cgroup v2 under `firecracker/<run-id>` with `cpu.max` and `memory.max` set from the VM size plus overhead. `fcctl` runs as root inside the distro (the wrapper uses `-u root`), because jailer, TAP and nftables need it.

**D9: Run state and timeout.**
`/var/lib/fc-sandbox/vms/<run-id>/meta.json` is the source of truth for `list` and `cleanup`. The run id is `YYYYMMDD-HHMMSS-<4 hex>`. The timeout is enforced by `fcctl` (`timeout` around the SSH exec) plus a detached `setsid` watchdog that runs `fcctl _expire <id>` after the VM's lifetime (for `run`, the command timeout plus 30 s to collect results). So a VM is still killed if the controller crashes, and the watchdog then finalises the run's `meta.json` as timed out. `cleanup` sweeps every state dir, jail dir, `tap-*` device and nft chain that has no live PID.

**D10: Exit codes.**
The guest exit code is passed through. `fcctl` reserves 124 for a timeout (matching coreutils `timeout`) and 125 for an infrastructure failure (boot, SSH, copy). If the guest command itself returns 124 or 125, that's recorded in `meta.json` and the two can be told apart there.

**D11: CLI surface (Windows wrapper and Linux controller are identical).**
```
fc.ps1 setup [-Yes]
fc.ps1 doctor
fc.ps1 run   -Payload <dir> -Cmd "<command>" [-Net isolated|networked] [-Allow cidr,...]
             [-Vcpu 2] [-MemMib 1024] [-Timeout 30m] [-Keep]
fc.ps1 shell [-Net ...] [-Allow ...] [-Vcpu] [-MemMib]
fc.ps1 list | stop <run-id> | cleanup
```

**D12: Repository layout.**
```
fc.ps1                      Windows entry point
windows/setup-host.ps1      distro creation, .wslconfig, invokes host/provision.sh
host/versions.env           pinned versions + checksums
host/provision.sh           installs packages, binaries, kernel, builds image, users, nft base table
host/bin/fcctl              controller entry point
host/lib/*.sh               vm.sh, net.sh, ssh.sh, state.sh, doctor.sh
images/build-rootfs.sh      base rootfs builder
tests/smoke/*.sh            end-to-end checks run inside fc-host
docs/README.md              usage and limitations
runs/                       results (gitignored)
```

## Risks / Trade-offs

- [Nested KVM in WSL2 is slower than bare metal and occasionally unstable after Windows updates.] → `doctor` checks `/dev/kvm` and boots a test VM. The docs explain `wsl --shutdown` recovery. Performance is acceptable for test workloads.
- [The WSL kernel may lack modules Firecracker needs (vhost-vsock isn't needed; TAP and nftables are).] → `doctor` checks `/dev/net/tun` and nft. If either is missing, docs point to a custom WSL kernel, which is out of scope for this change.
- [Hostile code in networked mode still egresses through the Windows machine's IP.] → Isolated is the default, the allowlist is available, and the docs carry a clear warning.
- [Guest-to-host escape would land in the WSL VM, not Windows directly, but WSL can reach `/mnt/c`.] → The jailer chroot plus an unprivileged uid limits what an escaped Firecracker process can reach. Docs recommend disabling automount in `fc-host`'s `/etc/wsl.conf` for high-risk samples (offered as a setup option, off by default because results are written to `/mnt/c`).
- [The full disk copy per run uses about 2 GB of temporary disk and about 2 s of startup time.] → It's acceptable and is revisited with D5's overlay alternative if it becomes a bottleneck.
- [Upstream artifact URLs (CI bucket) can change.] → Versions and checksums are pinned, and setup fails clearly on a 404 or mismatch.

## Migration Plan

Greenfield, so there's nothing to migrate. Rollback means running `wsl --unregister fc-host`, removing the `nestedVirtualization` line from `.wslconfig` if setup added it (setup writes a `.wslconfig.bak`), and deleting `runs/`.

## Open Questions

- Which exact Firecracker v1.x release to pin. Decide at implementation time from the latest stable release. This doesn't affect specs or tasks.
