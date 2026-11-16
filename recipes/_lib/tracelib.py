"""Shared helpers for the trace-based recipes (detonate, npm-check, pip-check); design D6.

Runs a command under strace inside the guest, turns the trace into lists of processes, file
changes and connection attempts, and writes report.json / report.md. Standard library only.

Everything recorded here comes from inside the guest. A program that runs as root in the guest
can detect tracing, behave differently, or alter this evidence; every report says so.
"""
import hashlib
import json
import os
import re
import shlex
import signal
import subprocess
import time

OUT = "/work/out"
TRACE = "/work/trace.log"
MARKER = "/work/.fc/trace-marker"
TRACE_CAP = 50 * 1024 * 1024      # raw trace copied to out/ (the airlock has its own limits)
OUTPUT_CAP = 10 * 1024 * 1024     # the traced program's stdout/stderr files
SYSCALLS = ("execve,execveat,clone,clone3,fork,vfork,chdir,connect,bind,openat,open,creat,"
            "rename,renameat,renameat2,unlink,unlinkat,mkdir,mkdirat,chmod,fchmodat,symlink,symlinkat,link,linkat")
EVIDENCE_NOTE = ("This evidence was recorded inside the guest with strace. A program can detect tracing and "
                 "behave differently, and code running as root in the guest could alter the record.")
# Paths that are noise in every trace.
NOISE = ("/dev/null", "/dev/tty", "/dev/pts/", "/proc/", "/sys/", "/work/out/", "/work/trace.log", "/work/.fc/")


def read_env(path="/work/.fc/recipe.env"):
    env = {}
    try:
        for line in open(path, encoding="utf-8"):
            k, sep, v = line.rstrip("\n").partition("=")
            if not sep:
                continue
            # Values were written with the shell's %q quoting.
            try:
                parts = shlex.split(v)
                env[k] = parts[0] if parts else ""
            except ValueError:
                env[k] = v
    except OSError:
        pass
    return env


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def tool(*args, limit=20000, timeout=60):
    """Output of an analysis tool (stdout, then stderr), cut to limit characters."""
    try:
        p = subprocess.run(list(args), capture_output=True, timeout=timeout)
        text = (p.stdout + p.stderr).decode("utf-8", "replace")
    except (OSError, subprocess.TimeoutExpired) as e:
        text = "(%s failed: %s)" % (args[0], e)
    return text[:limit].strip()


def run_traced(cmd, cwd, seconds, env=None):
    """Runs cmd under strace for at most `seconds`. Returns a dict with exit_code, signal, timed_out, seconds.

    The program gets no terminal and no pipe to this session: its output goes to files, so a
    process it leaves behind cannot keep the recipe from ending.
    """
    os.makedirs(OUT, exist_ok=True)
    os.makedirs(os.path.dirname(MARKER), exist_ok=True)
    open(MARKER, "w").close()
    time.sleep(0.05)  # files changed by the program are strictly newer than the marker
    stdout = open(os.path.join(OUT, "program-stdout.log"), "wb")
    stderr = open(os.path.join(OUT, "program-stderr.log"), "wb")
    argv = ["strace", "-f", "-qq", "-s", "256", "-e", "trace=" + SYSCALLS, "-o", TRACE, "--"] + list(cmd)
    t0 = time.monotonic()
    proc = subprocess.Popen(argv, cwd=cwd, env=env, stdin=subprocess.DEVNULL, stdout=stdout, stderr=stderr,
                            start_new_session=True)
    timed_out = False
    try:
        proc.wait(timeout=seconds)
    except subprocess.TimeoutExpired:
        timed_out = True
    # Stop whatever is left: the session's process group first, then every pid the trace saw.
    try:
        os.killpg(proc.pid, signal.SIGKILL)
    except OSError:
        pass
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        pass
    for pid in trace_pids():
        if pid not in (os.getpid(), os.getppid(), 1):
            try:
                os.kill(pid, signal.SIGKILL)
            except OSError:
                pass
    stdout.close()
    stderr.close()
    for name in ("program-stdout.log", "program-stderr.log"):
        truncate(os.path.join(OUT, name), OUTPUT_CAP)
    rc = proc.returncode
    return {"exit_code": None if (timed_out or rc is None or rc < 0) else rc,
            "signal": -rc if (rc is not None and rc < 0 and not timed_out) else None,
            "timed_out": timed_out, "seconds": round(time.monotonic() - t0, 1), "limit_seconds": seconds}


def truncate(path, cap):
    try:
        if os.path.getsize(path) > cap:
            with open(path, "r+b") as f:
                f.truncate(cap)
            return True
    except OSError:
        pass
    return False


def trace_pids():
    pids = set()
    try:
        with open(TRACE, "rb") as f:
            for line in f:
                head = line.split(None, 1)[0] if line.strip() else b""
                if head.isdigit():
                    pids.add(int(head))
    except OSError:
        pass
    return pids


_LINE = re.compile(r"^(\d+)\s+(\w+)\((.*)\)\s+=\s+(-?\d+|\?)(?:\s+(\w+))?")
_UNFINISHED = re.compile(r"^(\d+)\s+(\w+)\((.*)<unfinished \.\.\.>$")
_RESUMED = re.compile(r"^(\d+)\s+<\.\.\. (\w+) resumed>(.*)$")
_STR = re.compile(r'"((?:[^"\\]|\\.)*)"')


def _unescape(s):
    try:
        return bytes(s, "latin-1").decode("unicode_escape").encode("latin-1").decode("utf-8", "replace")
    except Exception:
        return s


def _strings(args):
    return [_unescape(m) for m in _STR.findall(args)]


def _abs(cwd, path):
    return path if path.startswith("/") else os.path.normpath(os.path.join(cwd or "/", path))


def _noise(path):
    return any(path == n or path.startswith(n) for n in NOISE)


def parse_trace(start_cwd, path=TRACE):
    """Turns the strace log into processes, file changes and connection attempts."""
    cwd = {}
    pending = {}
    processes, connections = [], []
    files = {"written": set(), "deleted": set(), "renamed": set(), "created_dirs": set(), "mode_changed": set(), "links": set()}
    seen_conn = set()
    first_pid = None
    try:
        f = open(path, encoding="utf-8", errors="replace")
    except OSError:
        return {"processes": [], "connections": [], "files": {k: [] for k in files}, "trace_lines": 0, "first_pid": None}
    lines = 0
    with f:
        for raw in f:
            lines += 1
            line = raw.rstrip("\n")
            m = _UNFINISHED.match(line)
            if m:
                pending[(m.group(1), m.group(2))] = m.group(3)
                continue
            m = _RESUMED.match(line)
            if m:
                key = (m.group(1), m.group(2))
                line = "%s %s(%s%s" % (m.group(1), m.group(2), pending.pop(key, ""), m.group(3).lstrip())
            m = _LINE.match(line)
            if not m:
                continue
            pid, call, args, ret, err = int(m.group(1)), m.group(2), m.group(3), m.group(4), m.group(5)
            if first_pid is None:
                first_pid = pid
                cwd[pid] = start_cwd
            here = cwd.get(pid, start_cwd)
            ok = ret not in ("?",) and int(ret) >= 0
            strs = _strings(args)
            if call in ("clone", "clone3", "fork", "vfork"):
                if ok and int(ret) > 0:
                    cwd[int(ret)] = here
            elif call == "chdir":
                if ok and strs:
                    cwd[pid] = _abs(here, strs[0])
            elif call in ("execve", "execveat"):
                if ok and strs:
                    argv_m = re.search(r"\[(.*?)\](?:, |$)", args)
                    argv = _strings(argv_m.group(1)) if argv_m else []
                    processes.append({"pid": pid, "path": strs[0], "argv": argv or [strs[0]], "cwd": here})
            elif call in ("connect", "bind"):
                fam = re.search(r"sa_family=(\w+)", args)
                fam = fam.group(1) if fam else "?"
                addr = port = None
                if fam == "AF_INET":
                    a = re.search(r'inet_addr\("([^"]+)"\)', args)
                    p = re.search(r"sin_port=htons\((\d+)\)", args)
                    addr, port = (a.group(1) if a else None), (int(p.group(1)) if p else None)
                elif fam == "AF_INET6":
                    a = re.search(r'inet_pton\(AF_INET6, "([^"]+)"', args)
                    p = re.search(r"sin6_port=htons\((\d+)\)", args)
                    addr, port = (a.group(1) if a else None), (int(p.group(1)) if p else None)
                elif fam == "AF_UNIX":
                    a = re.search(r'sun_path=@?"([^"]*)"', args)
                    addr = a.group(1) if a else None
                # Port 0 is the resolver choosing a source address (a UDP connect that sends nothing).
                if call == "connect" and addr and port and fam in ("AF_INET", "AF_INET6"):
                    # EINPROGRESS: a non-blocking connect was started; the trace does not show how it ended.
                    result = "connected" if ok else ("started" if err == "EINPROGRESS" else (err or "failed"))
                    key = (fam, addr, port, result)
                    if key not in seen_conn:
                        seen_conn.add(key)
                        connections.append({"family": fam, "address": addr, "port": port, "result": result, "pid": pid})
            elif call in ("openat", "open", "creat"):
                if ok and strs and (call == "creat" or re.search(r"O_(WRONLY|RDWR|CREAT|TRUNC|APPEND)", args)):
                    p = _abs(here, strs[0])
                    if not _noise(p):
                        files["written"].add(p)
            elif call in ("unlink", "unlinkat"):
                if ok and strs and not _noise(_abs(here, strs[0])):
                    files["deleted"].add(_abs(here, strs[0]))
            elif call in ("rename", "renameat", "renameat2"):
                if ok and len(strs) >= 2:
                    a, b = _abs(here, strs[0]), _abs(here, strs[1])
                    if not _noise(b):
                        files["renamed"].add("%s -> %s" % (a, b))
                        files["written"].add(b)
            elif call in ("mkdir", "mkdirat"):
                if ok and strs and not _noise(_abs(here, strs[0])):
                    files["created_dirs"].add(_abs(here, strs[0]))
            elif call in ("chmod", "fchmodat"):
                if ok and strs and not _noise(_abs(here, strs[0])):
                    files["mode_changed"].add(_abs(here, strs[0]))
            elif call in ("symlink", "symlinkat", "link", "linkat"):
                if ok and len(strs) >= 2:
                    files["links"].add("%s -> %s" % (_abs(here, strs[-1]), strs[0]))
    return {"processes": processes, "connections": connections,
            "files": {k: sorted(v) for k, v in files.items()}, "trace_lines": lines, "first_pid": first_pid}


def newer_files(exclude=()):
    """Files changed since the marker, found by walking the disk (catches what the trace missed)."""
    try:
        base = os.stat(MARKER).st_mtime_ns
    except OSError:
        return []
    skip = ("/proc", "/sys", "/dev", "/run", "/work/out", "/work/.fc", "/var/log", "/var/lib/systemd") + tuple(exclude)
    found = []
    for root, dirs, names in os.walk("/", followlinks=False):
        dirs[:] = [d for d in dirs if not os.path.join(root, d).startswith(skip) and os.path.join(root, d) not in skip]
        for n in names:
            p = os.path.join(root, n)
            if p == TRACE or p.startswith(skip):
                continue
            try:
                st = os.lstat(p)
            except OSError:
                continue
            if st.st_mtime_ns > base or st.st_ctime_ns > base:
                found.append(p)
            if len(found) >= 20000:
                return sorted(found)
    return sorted(found)


def tail_text(path, limit=4000):
    try:
        with open(path, "rb") as f:
            data = f.read(limit + 1)
    except OSError:
        return ""
    text = data[:limit].decode("utf-8", "replace")
    text = "".join(c if (c == "\n" or c == "\t" or 32 <= ord(c) < 127 or ord(c) > 160) else "?" for c in text)
    return text + ("\n[... cut ...]" if len(data) > limit else "")


def copy_trace():
    """Copies the raw trace into out/, cut to TRACE_CAP. Returns (bytes_kept, was_cut)."""
    dst = os.path.join(OUT, "trace.log")
    try:
        size = os.path.getsize(TRACE)
        with open(TRACE, "rb") as src, open(dst, "wb") as out:
            left = TRACE_CAP
            while left > 0:
                block = src.read(min(1 << 20, left))
                if not block:
                    break
                out.write(block)
                left -= len(block)
        return min(size, TRACE_CAP), size > TRACE_CAP
    except OSError:
        return 0, False


def md_list(items, limit=200, code=True):
    if not items:
        return ["(none)"]
    shown = ["- `%s`" % i.replace("`", "'") if code else "- %s" % i for i in items[:limit]]
    if len(items) > limit:
        shown.append("- ... and %d more (see report.json)" % (len(items) - limit))
    return shown


def process_lines(processes, limit=200):
    return md_list([" ".join(p["argv"])[:300] for p in processes], limit)


def connection_lines(connections, limit=200):
    return md_list(["%s:%s (%s)" % (c["address"], c["port"], c["result"]) for c in connections], limit)


def write_reports(report, md_lines):
    os.makedirs(OUT, exist_ok=True)
    with open(os.path.join(OUT, "report.json"), "w", encoding="utf-8") as f:
        json.dump(report, f, indent=1)
    with open(os.path.join(OUT, "report.md"), "w", encoding="utf-8") as f:
        f.write("\n".join(md_lines) + "\n")
