# Tasks

## 1. Linux suite environment check (`smoke-test-suites`)

- [x] 1.1 Add the preflight to `tests/smoke/lib.sh` per design D1: runs when sourced, before `mktemp`; checks Linux, root, read/write `/dev/kvm`, executable `$FCCTL`, `/opt/fc-sandbox/images/rootfs.ext4`, and `jq ip nft pgrep socat sha256sum timeout awk`; lists every missing item with the documented `wsl -d fc-host -u root -e bash /mnt/c/sources/Firecracker/tests/smoke/all.sh` command and `.\fc.ps1 setup`, then exits 125. Verify that `bash tests/smoke/net.sh` from Git Bash prints no `ok`/`FAIL` lines, names the missing items and exits 125, and that `wsl -d fc-host -u nobody -e bash /mnt/c/sources/Firecracker/tests/smoke/boot.sh` (fc-host defaults to root) exits 125 reporting root is required
- [x] 1.2 Update `tests/smoke/all.sh` per design D2: source `lib.sh` before the first `fcctl cleanup` and stop with exit 125 when a part exits 125. Verify that `bash tests/smoke/all.sh` from Git Bash shows the environment report once, runs no part and exits 125
- [x] 1.3 Fix the Linux smoke test instructions in `README.md` to use the absolute `/mnt/c/...` path and describe the exit 125 environment failure. Verify that the documented command, run from PowerShell outside the repo folder, runs the suite and it passes in `fc-host`

## 2. Windows suite runtime selection (`smoke-test-suites`)

- [x] 2.1 Add `-WinRuntime docker|containerd` (default `docker`) to `tests/smoke-win/net-isolated.ps1`, `lifecycle.ps1` and `net-protect.ps1`, passing it to every `fc.ps1` call they make. Verify each part still passes on its own with no argument from an elevated prompt
- [x] 2.2 Add `-WinRuntime` to `tests/smoke-win/all.ps1` per design D3: pass it to `setup`, `doctor`, every `fc.ps1` call and every part; copy `C:\ProgramData\fc-sandbox-win\config.json` before `setup` and restore it in `finally`. Verify `all.ps1` with no argument passes on `docker` and `config.json` is byte-identical before and after, including after a run interrupted with Ctrl+C during `lifecycle.ps1`
- [x] 2.3 Document `-WinRuntime` for the Windows suite in `README.md`. Verify the documented commands match the script parameters
- [x] 2.4 In `tests/smoke-win/all.ps1`'s `finally` block, restore (or remove) `config.json` before the cleanup call, so a second Ctrl+C or a slow cleanup cannot skip the restore. Report the final cleanup's exit code and output when it fails or microVMs are still listed afterwards, instead of discarding them. Verify by running `all.ps1` (docker) from an elevated prompt, pressing Ctrl+C once during `[smoke-win:lifecycle] 1.`, and checking that the restore message is printed, the `config.json` hash matches the one taken before the run, `list -Guest windows` is empty, and no `fc-win-` containers or `fc-egress` processes remain

## 3. Single table of containerd limitations (`windows-microvm-host-setup`)

- [x] 3.1 Add the limitations table and `Assert-FcWinFeatureSupported` to `windows/lib/common.ps1` per design D4, and move the existing `-BuildFromSource` refusal in `setup-nanoserver.ps1` and `Invoke-FcWinImageBuild` onto it. Verify `.\fc.ps1 setup -Guest windows -WinRuntime containerd -BuildFromSource` exits 125 naming the feature and `-WinRuntime docker`, without installing or downloading anything
- [x] 3.2 Show the table's entries for the active runtime in `windows/lib/doctor.ps1`, replacing the generic "experimental" note. Verify `.\fc.ps1 doctor -Guest windows -WinRuntime containerd` lists `-BuildFromSource`, and `.\fc.ps1 doctor -Guest windows` on `docker` shows no limitation note
- [x] 3.3 Have the Windows suite read the table: on a runtime with limitations, skip the affected parts with a message and assert that each limited feature is refused with exit 125 and leaves nothing behind. Verify by temporarily adding a test-only entry for `-Net networked` on `containerd` and running `net-protect.ps1 -WinRuntime containerd`, which must skip and pass; remove the entry afterwards
- [x] 3.4 Add a "containerd limitations" section to `README.md` listing the table's entries, the extra disk use for a second image store, and the rollback steps from the design's Migration Plan. Verify the README list matches `doctor -Guest windows -WinRuntime containerd`

## 4. Cleanup across both runtimes

- [x] 4.1 Make `cleanup -Guest windows` clear network policies for every installed runtime per design D6. Verify `.\fc.ps1 cleanup -Guest windows` (elevated) succeeds both with only `docker` installed and after containerd is installed (task 5.1)

## 5. containerd backend bring-up (`windows-microvm-host-setup`)

- [x] 5.1 Install containerd alongside docker with `.\fc.ps1 setup -Guest windows -WinRuntime containerd -Yes` (elevated), then restore `docker` as the default with `.\fc.ps1 setup -Guest windows -WinRuntime docker -Yes`. Verify the `containerd` and `docker` services are both running, `nerdctl image inspect malaker/nanoserver:aspnet-x86` succeeds, and `config.json` shows `win_runtime: docker`
- [x] 5.2 Get `.\fc.ps1 doctor -Guest windows -WinRuntime containerd -Boot` passing, fixing or tabulating each failure per design D5. Verify every check passes and `hcsdiag list` shows the Utility VM while the boot check runs
- [x] 5.3 Get `net-isolated.ps1 -WinRuntime containerd` passing (payload upload, run, results, exit code 3 propagation), per design D5. Verify the run's `meta.json` has `win_runtime: containerd` and `runs\<run-id>\out\whoami.txt` exists
- [x] 5.4 Get `lifecycle.ps1 -WinRuntime containerd` passing (start, list, ssh, keep, timeout watchdog, stop, cleanup), per design D5. Verify the timed-out run records `exit_code: 124` and `timed_out: true`, and `nerdctl ps -a` shows no `fc-win-` containers afterwards
- [x] 5.5 Get `net-protect.ps1 -WinRuntime containerd` passing, or tabulate networked mode as a limitation if the egress relay cannot run over `nerdctl exec`, per design D5. Verify the part either passes in full or skips with the refusal asserted by task 3.3
- [x] 5.6 Record each limitation found in 5.2–5.5 with a one-line rationale under Risks in `design.md`, and update the README section from task 3.4. Verify the design, README and doctor output list the same features

## 6. End-to-end verification

- [x] 6.1 Run `tests/smoke-win/all.ps1 -WinRuntime containerd` and `tests/smoke-win/all.ps1` (docker) from an elevated prompt, and `wsl -d fc-host -u root -e bash /mnt/c/sources/Firecracker/tests/smoke/all.sh`. Verify all three pass, the containerd run lists every skipped part with its reason, and `config.json` is unchanged

## Workflow follow-up

- Archive the change after both Windows suite runs and the Linux suite pass.
