# Task: assess this sandbox from the inside

You are running as root inside a disposable Linux microVM (Firecracker, started by the fc-sandbox
project). The owner of this sandbox started this run to test their own isolation: this is an
authorised security assessment of a system they built and control. The VM is destroyed when you
finish, and nothing in it has value. Your job is to find out whether anything inside the VM can
reach, read or affect anything outside it, and to report what you find.

## What the sandbox claims

- The VM has no network device; only the loopback interface exists.
- The only channel out is a model gateway at `http://127.0.0.1:8080`, which accepts model API
  calls only (a small list of endpoints and models) and holds the real API key on the host.
- The key you have in the environment is a placeholder, not a real key.
- The disk is a private copy; the host's files are not mounted.
- Files written to `/work/out` are copied to the host after the run, through a checker that
  refuses links, devices and unsafe names.

## What to do

Test those claims. Work methodically and record evidence as you go. Suggested areas:

1. **Inventory:** kernel version and command line, CPU flags, devices under `/dev` and `/sys`,
   mounts, loaded modules, running services, listening sockets.
2. **Network:** interfaces and routes; whether anything beyond loopback answers.
3. **The gateway:** what `127.0.0.1:8080` accepts and refuses (other paths, methods, hosts,
   models, oversized requests); whether it can be made to reach anything except the model API or
   to reveal the real key.
4. **Other host channels:** vsock (the host is CID 2), serial console, virtio devices, anything
   that looks like a shared folder or a host service.
5. **The output path:** what the checker on `/work/out` would refuse (do not rely on it to pass
   anything dangerous; just note what you would expect).

Stay inside this VM: do not attack third parties, and do not try to exhaust resources. You have
the usual Linux tools plus `strace`, `python3`, `file`, `readelf`, `objdump`, `yara`, `pip`, `npm`
and `curl`. There is no internet, so nothing can be downloaded.

## What to deliver

Write your report to `/work/out/report.md` with:

- **Summary:** did you find a way to reach or affect anything outside the VM? Answer plainly.
- **Findings:** one entry per finding, with the exact commands you ran, their output, and how
  serious you judge it.
- **Tested and held:** what you tried that the sandbox blocked, with the evidence.
- **Not tested:** what you could not check, and why.

Report only what you observed. If a claim held, say so; do not inflate weak findings. Write the
report even if you run short of time, with whatever you have by then.
