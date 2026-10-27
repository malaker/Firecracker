# Tasks

## 1. Repository scaffolding

- [x] 1.1 Create the layout from design D12 (`fc.ps1`, `windows/`, `host/bin`, `host/lib`, `images/`, `tests/smoke/`, `docs/`) and a `.gitignore` containing `runs/` and downloaded artifacts; verify the tree matches D12
- [x] 1.2 Add `host/versions.env` with the chosen Firecracker v1.x release, guest kernel and Ubuntu squashfs URLs and their SHA256 sums; verify each URL downloads and its checksum matches with `sha256sum -c`

## 2. Host bootstrap (kvm-host-setup)

- [x] 2.1 Implement `windows/setup-host.ps1`: create the `fc-host` Ubuntu 24.04 distro if absent (D1), leaving other distros untouched; verify `wsl -l -v` shows `fc-host` and `podman-machine-default` is unchanged
- [x] 2.2 Implement the `.wslconfig` merge with a confirmation prompt, `-Yes` bypass, `.wslconfig.bak` backup and `wsl --shutdown` (D2); verify that declining leaves the file untouched and exits non-zero, and that accepting yields `/dev/kvm` inside `fc-host`
- [x] 2.3 Implement `host/provision.sh`: apt packages (curl, jq, nftables, socat, openssh-client, e2fsprogs, squashfs-tools), checksum-verified download and install of firecracker/jailer and the kernel into `/opt/fc-sandbox`, `kvm` permissions at boot, base nft table, controller SSH keypair; verify that a second run downloads nothing and reports "up to date"
- [x] 2.4 Implement `images/build-rootfs.sh` (D4): ext4 base image with sshd, socat vsock-to-sshd unit (D6), authorized key, `/work`; verify the image file exists and `debugfs` shows the authorized key and socat unit
- [x] 2.5 Implement `fcctl doctor` (`host/lib/doctor.sh`): checks for `/dev/kvm` access, binaries and versions, kernel and rootfs checksums, `/dev/net/tun`, nftables, free disk and memory, each with pass/fail and a hint; verify exit 0 on the configured host and exit non-zero with the KVM hint when `/dev/kvm` is chmod'ed away
- [x] 2.6 Wire `fc.ps1 setup` and `fc.ps1 doctor` through the wrapper (D3, D11) so setup ends by running doctor; verify by running `fc.ps1 setup` end-to-end on this PC
- [x] 2.7 Document setup, rollback (design Migration Plan) and the `.wslconfig` change in `docs/README.md`; verify the documented commands run as written

## 3. MicroVM lifecycle (microvm-lifecycle)

- [x] 3.1 Implement run state (`host/lib/state.sh`): run-id generation, `meta.json` read/write, PID tracking (D9); verify with a smoke test that creates, reads and lists fake state entries
- [x] 3.2 Implement VM start under the jailer (`host/lib/vm.sh`): per-VM uid, cgroup limits, sparse disk copy into the jail, generated Firecracker config JSON, vsock device (D5, D8); verify `tests/smoke/boot.sh` boots a VM, the firecracker process is non-root and chrooted, and the base image checksum is unchanged after the guest writes to disk
- [x] 3.3 Implement vCPU/memory options with validation and defaults of 2 vCPUs and 1024 MiB; verify the guest `nproc`/`free -m` match a 4 vCPU/2048 MiB request and that 0 vCPUs is rejected
- [x] 3.4 Implement the hard timeout with a watchdog that survives controller death (D9); verify a VM with a 1-minute timeout is killed and `meta.json` records `timed_out`, including when `fcctl` is `kill -9`'d mid-run
- [x] 3.5 Implement `list`, `stop <run-id>`, `cleanup` and the `--keep` option; verify `tests/smoke/lifecycle.sh` starts two VMs, lists both, stops one, kills the controller for the other, and that `cleanup` leaves no process, jail dir, disk copy, tap or nft chain
- [x] 3.6 Document lifecycle commands and options in `docs/README.md`; verify the examples match `fcctl --help`

## 4. Network modes (microvm-network-modes)

- [x] 4.1 Implement isolated mode as the default, with no network device attached; verify in the guest that `ip -o link` lists only `lo` and `curl https://example.com` fails
- [x] 4.2 Implement networked mode (`host/lib/net.sh`): per-VM tap, /30 from 172.30.0.0/16, guest IP via kernel cmdline, masquerade through eth0 (D7); verify the guest can `curl https://example.com`
- [x] 4.3 Implement host-protection rules (drop to WSL host, Windows gateway, RFC1918, link-local, other VMs); verify `tests/smoke/net-protect.sh` shows connections from the guest to each of those addresses time out
- [x] 4.4 Implement the `--allow` CIDR allowlist; verify that with `--allow <public-ip>/32` only that address is reachable and example.com is not
- [x] 4.5 Make teardown remove the tap and the per-VM nft chain on stop, cleanup and timeout; verify `ip link` and `nft list table inet fc_sandbox` show nothing for the run afterwards
- [x] 4.6 Document network modes, the egress-via-Windows-IP warning and the allowlist in `docs/README.md`; verify the documented examples behave as described

## 5. Test runs and shell (sandbox-test-runs)

- [x] 5.1 Implement the SSH-over-vsock ProxyCommand helper (`host/lib/ssh.sh`, D6); verify `ssh` executes `uname -a` in an isolated-mode VM
- [x] 5.2 Implement `run`: boot, upload payload to `/work/in` via tar-over-ssh, execute the command in `/work`, stream stdout/stderr to log files, download `/work/out`, write `meta.json`, destroy the VM; verify a payload with `scan.sh` writing to `out/` produces all files in `runs/<run-id>/`
- [x] 5.3 Implement exit code propagation with reserved 124 (timeout) and 125 (infrastructure) (D10); verify a guest `exit 3` gives exit 3, a timeout gives 124 with partial logs saved, and a missing payload dir gives 125
- [x] 5.4 Implement `shell` with automatic teardown on exit; verify an interactive session gets a root prompt and `list` shows nothing after exit
- [x] 5.5 Implement Windows path translation in `fc.ps1` for `-Payload` and results under `runs\`; verify `fc.ps1 run -Payload .\samples\hello -Cmd "./in/hello.sh"` from PowerShell writes results to `C:\sources\Firecracker\runs\<run-id>\`
- [x] 5.6 Add a `samples/hello` payload and write the quick-start in `docs/README.md` (setup, then the first isolated run, results layout, limitations from design Risks); verify by following the quick-start literally

## 6. Integration

- [x] 6.1 Add `tests/smoke/all.sh`, which runs every smoke test in sequence and finishes with `cleanup` and an empty `list`; verify it passes on this PC from `fc.ps1` in a fresh PowerShell session
