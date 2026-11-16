#!/usr/bin/env python3
"""Sandbox self-test, run inside the guest (recipes probe and probe-net; spec: sandbox-recipes).

Usage: probe.py isolated|networked

Tries to reach things from inside the VM and compares each result with what the sandbox promises:
  expect "blocked": the destination must not answer. An answer (a TCP connect, a TCP reset from
                    the destination, a ping reply, a vsock connect) fails the run (exit 1).
  expect "open":    the destination should answer; if not, that is a warning only (the host may
                    simply be offline).
Writes /work/out/report.json and /work/out/report.md. Uses only the Python standard library.
"""
import errno
import json
import os
import socket
import struct
import sys
import time
from concurrent.futures import ThreadPoolExecutor

MODE = sys.argv[1] if len(sys.argv) > 1 else "isolated"
OUT = "/work/out"
TIMEOUT = 2.0
PORTS = [22, 53, 80, 135, 443, 445, 2375, 3389, 11434]
VSOCK_PORTS = [22, 52, 1024, 8080]
PRIVATE = ["10.0.0.1", "172.16.0.1", "192.168.0.1", "192.168.1.1", "100.64.0.1", "169.254.169.254"]
INTERNET_IP = "1.1.1.1"
INTERNET_NAME = "example.com"
INTERNET_V6 = "2606:4700:4700::1111"


def read_env(path="/work/.fc/recipe.env"):
    env = {}
    try:
        for line in open(path, encoding="utf-8"):
            k, sep, v = line.strip().partition("=")
            if sep:
                env[k] = v.strip("'\"")
    except OSError:
        pass
    return env


def read(path, limit=4000):
    try:
        return open(path, encoding="utf-8", errors="replace").read(limit).strip()
    except OSError:
        return ""


def interfaces():
    try:
        return sorted(os.listdir("/sys/class/net"))
    except OSError:
        return []


def own_ipv4():
    """The guest's own address and default gateway, without external tools."""
    gw = ""
    for line in read("/proc/net/route", 20000).splitlines()[1:]:
        f = line.split()
        if len(f) > 2 and f[1] == "00000000":
            gw = socket.inet_ntoa(struct.pack("<L", int(f[2], 16)))
    ip = ""
    if gw:
        s = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            s.connect((gw, 9))
            ip = s.getsockname()[0]
        except OSError:
            pass
        finally:
            s.close()
    return ip, gw


def tcp(host, port, family=socket.AF_INET):
    """Returns (reached, detail). A reset from the destination counts as reached."""
    s = socket.socket(family, socket.SOCK_STREAM)
    s.settimeout(TIMEOUT)
    try:
        s.connect((host, port))
        return True, "connected"
    except ConnectionRefusedError:
        return True, "connection refused (the destination answered)"
    except socket.timeout:
        return False, "no answer"
    except OSError as e:
        return False, errno.errorcode.get(e.errno, str(e.errno)) if e.errno else str(e)
    finally:
        s.close()


def ping(host):
    """One ICMP echo over a raw socket (the guest runs as root)."""
    try:
        s = socket.socket(socket.AF_INET, socket.SOCK_RAW, socket.IPPROTO_ICMP)
    except OSError as e:
        return False, "no raw socket: %s" % e
    s.settimeout(TIMEOUT)
    ident = os.getpid() & 0xFFFF
    body = struct.pack("!BBHHH", 8, 0, 0, ident, 1) + b"fc-probe"
    csum = 0
    for i in range(0, len(body), 2):
        csum += (body[i] << 8) + (body[i + 1] if i + 1 < len(body) else 0)
    csum = (csum >> 16) + (csum & 0xFFFF)
    csum = ~(csum + (csum >> 16)) & 0xFFFF
    packet = struct.pack("!BBHHH", 8, 0, csum, ident, 1) + b"fc-probe"
    try:
        s.sendto(packet, (host, 0))
        end = time.time() + TIMEOUT
        while time.time() < end:
            data, addr = s.recvfrom(1024)
            # Echo reply (type 0) from the destination itself.
            if addr[0] == host and len(data) >= 28 and data[20] == 0:
                return True, "ping reply"
        return False, "no reply"
    except socket.timeout:
        return False, "no reply"
    except OSError as e:
        return False, errno.errorcode.get(e.errno, str(e.errno)) if e.errno else str(e)
    finally:
        s.close()


def vsock(port):
    if not hasattr(socket, "AF_VSOCK"):
        return False, "no vsock support"
    try:
        s = socket.socket(socket.AF_VSOCK, socket.SOCK_STREAM)
    except OSError as e:
        return False, "no vsock socket: %s" % e
    s.settimeout(TIMEOUT)
    try:
        s.connect((2, port))  # CID 2 is the host
        return True, "connected"
    except socket.timeout:
        return False, "no answer"
    except OSError as e:
        return False, errno.errorcode.get(e.errno, str(e.errno)) if e.errno else str(e)
    finally:
        s.close()


def resolve(name):
    try:
        return True, socket.gethostbyname(name)
    except OSError as e:
        return False, str(e)


def main():
    env = read_env()
    env.update({k: v for k, v in os.environ.items() if k.startswith("FC_")})
    ifaces = interfaces()
    ip, gw = own_ipv4()
    checks = []
    jobs = []

    def add(group, target, expect, fn, *args):
        jobs.append((group, target, expect, fn, args))

    # What the VM should look like.
    non_lo = [i for i in ifaces if i != "lo"]
    if MODE == "isolated":
        checks.append({"group": "network", "target": "interfaces", "expect": "loopback only",
                       "found": ", ".join(ifaces), "status": "fail" if non_lo else "pass",
                       "detail": "an isolated VM has no network device"})
        checks.append({"group": "network", "target": "default route", "expect": "none",
                       "found": gw or "none", "status": "fail" if gw else "pass", "detail": ""})
    else:
        checks.append({"group": "network", "target": "interfaces", "expect": "lo and eth0",
                       "found": ", ".join(ifaces), "status": "pass" if non_lo == ["eth0"] else "warn",
                       "detail": "own address %s, gateway %s" % (ip or "-", gw or "-")})

    # Hosts that must never answer.
    blocked = {}
    if gw:
        blocked["WSL host (this VM's gateway %s)" % gw] = gw
    if env.get("FC_HOST_WSL"):
        blocked["WSL host (%s)" % env["FC_HOST_WSL"]] = env["FC_HOST_WSL"]
    if env.get("FC_HOST_WINDOWS"):
        blocked["Windows host (%s)" % env["FC_HOST_WINDOWS"]] = env["FC_HOST_WINDOWS"]
    # Addresses of neighbouring microVM slots (each VM has its own /30 in 172.30.0.0/16).
    neighbours = ["172.30.0.1", "172.30.0.2"]
    if ip.startswith("172.30."):
        o = [int(x) for x in ip.split(".")]
        base = (o[2] * 256 + o[3]) // 4 * 4
        neighbours = []
        for b in (base - 4, base + 4):
            if 0 <= b < 65536:
                neighbours += ["172.30.%d.%d" % ((b + k) // 256, (b + k) % 256) for k in (1, 2)]
    for n in neighbours:
        blocked["other microVM slot (%s)" % n] = n
    for p in PRIVATE:
        blocked["private range (%s)" % p] = p

    for label, host in blocked.items():
        add("blocked", label + " ping", "blocked", ping, host)
        for port in PORTS:
            add("blocked", "%s tcp/%d" % (label, port), "blocked", tcp, host, port)
    add("blocked", "IPv6 internet (%s tcp/443)" % INTERNET_V6, "blocked", tcp, INTERNET_V6, 443, socket.AF_INET6)
    for port in VSOCK_PORTS:
        add("blocked", "host over vsock, port %d" % port, "blocked", vsock, port)
    # Test hook: extra host:port pairs that must be blocked.
    for pair in filter(None, env.get("FC_PROBE_EXTRA_BLOCKED", "").split(",")):
        host, _, port = pair.rpartition(":")
        add("blocked", "extra (%s)" % pair, "blocked", tcp, host, int(port))

    # The internet: closed in an isolated VM, open in a networked one.
    inet = "blocked" if MODE == "isolated" else "open"
    add("internet", "internet by address (%s tcp/443)" % INTERNET_IP, inet, tcp, INTERNET_IP, 443)
    add("internet", "name resolution (%s)" % INTERNET_NAME, inet, resolve, INTERNET_NAME)
    add("internet", "internet by name (%s tcp/443)" % INTERNET_NAME, inet, tcp, INTERNET_NAME, 443)

    with ThreadPoolExecutor(max_workers=48) as pool:
        futures = [(g, t, e, pool.submit(fn, *a)) for g, t, e, fn, a in jobs]
        for group, target, expect, fut in futures:
            try:
                reached, detail = fut.result()
            except Exception as e:  # a failed check must not hide the others
                reached, detail = False, "check error: %s" % e
            if expect == "blocked":
                status = "fail" if reached else "pass"
            else:
                status = "pass" if reached else "warn"
            checks.append({"group": group, "target": target, "expect": expect,
                           "found": "answered" if reached else "no answer", "status": status, "detail": detail})

    facts = {
        "kernel": read("/proc/version", 300),
        "cmdline": read("/proc/cmdline", 600),
        "hypervisor_flag": " hypervisor" in read("/proc/cpuinfo", 20000),
        "cpus": os.cpu_count(),
        "block_devices": sorted(os.listdir("/sys/block")) if os.path.isdir("/sys/block") else [],
        "virtio_devices": sorted(os.listdir("/sys/bus/virtio/devices")) if os.path.isdir("/sys/bus/virtio/devices") else [],
        "dev_entries": sorted(os.listdir("/dev"))[:200],
        "mounts": [" ".join(l.split()[:3]) for l in read("/proc/mounts", 20000).splitlines()],
        "uid": os.getuid(),
    }
    summary = {s: sum(1 for c in checks if c["status"] == s) for s in ("pass", "fail", "warn")}
    report = {"recipe": env.get("FC_RECIPE", "probe"), "mode": MODE, "summary": summary, "checks": checks, "facts": facts,
              "limits": "Checks a fixed list of addresses and ports; a pass means none of them answered, "
                        "not that nothing else is reachable."}
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)

    lines = ["# Sandbox self-test (%s)" % MODE, "",
             "Result: **%s** (%d passed, %d failed, %d warnings)" % (
                 "FAILED" if summary["fail"] else "passed", summary["pass"], summary["fail"], summary["warn"]), ""]
    notable = [c for c in checks if c["status"] != "pass"]
    if notable:
        lines += ["## Failures and warnings", "", "| Status | Check | Expected | Found | Detail |", "|---|---|---|---|---|"]
        lines += ["| %s | %s | %s | %s | %s |" % (c["status"].upper(), c["target"], c["expect"], c["found"], c["detail"]) for c in notable]
        lines.append("")
    lines += ["## All checks", "", "| Status | Check | Expected | Found | Detail |", "|---|---|---|---|---|"]
    lines += ["| %s | %s | %s | %s | %s |" % (c["status"], c["target"], c["expect"], c["found"], c["detail"]) for c in checks]
    lines += ["", "## What the guest sees", "",
              "- Kernel: `%s`" % facts["kernel"],
              "- Kernel command line: `%s`" % facts["cmdline"],
              "- CPUs: %s, hypervisor flag: %s" % (facts["cpus"], facts["hypervisor_flag"]),
              "- Block devices: %s" % (", ".join(facts["block_devices"]) or "none"),
              "- Virtio devices: %s" % (", ".join(facts["virtio_devices"]) or "none"),
              "- Mounts:"] + ["  - `%s`" % m for m in facts["mounts"]]
    lines += ["", "## Limits of this evidence", "", report["limits"], ""]
    with open(os.path.join(OUT, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(lines))

    print("probe (%s): %d passed, %d failed, %d warnings" % (MODE, summary["pass"], summary["fail"], summary["warn"]))
    for c in notable:
        print("  %s %s: expected %s, found %s (%s)" % (c["status"].upper(), c["target"], c["expect"], c["found"], c["detail"]))
    return 1 if summary["fail"] else 0


if __name__ == "__main__":
    sys.exit(main())
