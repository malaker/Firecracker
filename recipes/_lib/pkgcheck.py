#!/usr/bin/env python3
"""npm-check / pip-check: installs a package under strace in a networked VM and reports what
the install executed, wrote and connected to (design D8).

Usage: pkgcheck.py npm|pip [seconds]   (how long the install may run; default 600)
"""
import json
import os
import re
import sys

sys.path.insert(0, "/work/recipe/_lib")
import tracelib as t  # noqa: E402

KIND = sys.argv[1]
SECONDS = int(sys.argv[2]) if len(sys.argv) > 2 else 600
IN = "/work/in"
PKG = "/work/pkg"
NOTE = ("This evidence was recorded inside the guest with strace, and the install ran as root there: an install "
        "script could detect tracing, behave differently, or alter the record. Connections are listed by address "
        "and port as the programs made them; host names are not recorded. A clean report does not prove a package is safe.")
# Folders the installer itself works in; writes there are not reported as "outside the install folder".
OWN = {
    "npm": [re.compile(r"^/work/pkg/"), re.compile(r"^/root/\.npm/"), re.compile(r"^/work/in/"),
            re.compile(r"^/tmp/node-compile-cache/")],
    "pip": [re.compile(r"^/work/pkg/"), re.compile(r"^/root/\.cache/pip/"), re.compile(r"^/work/in/"),
            re.compile(r"^/tmp/pip-[a-z-]+-[a-z0-9_]{6,}(/|$)"), re.compile(r"/__pycache__(/|$)")],
}


def target(env):
    """What to install: the package spec, or the uploaded sample (a folder or a single file)."""
    if env.get("FC_RECIPE_PACKAGE"):
        return env["FC_RECIPE_PACKAGE"], "package `%s`" % env["FC_RECIPE_PACKAGE"]
    if env.get("FC_RECIPE_SAMPLE_KIND") == "file":
        return os.path.join(IN, env.get("FC_RECIPE_SAMPLE", "")), "file `%s`" % env.get("FC_RECIPE_SAMPLE", "")
    return IN, "the uploaded folder"


def npm_declared_scripts():
    """Install-time scripts declared by the packages that were installed."""
    found = []
    for folder, meta in npm_packages():
        scripts = meta.get("scripts") if isinstance(meta.get("scripts"), dict) else {}
        for hook in ("preinstall", "install", "postinstall"):
            if isinstance(scripts.get(hook), str):
                found.append({"package": str(meta.get("name")), "version": str(meta.get("version")),
                              "hook": hook, "command": scripts[hook]})
        # binding.gyp without an install script means npm runs node-gyp rebuild.
        if os.path.exists(os.path.join(folder, "binding.gyp")) and "install" not in scripts and "preinstall" not in scripts:
            found.append({"package": str(meta.get("name")), "version": str(meta.get("version")),
                          "hook": "install", "command": "node-gyp rebuild"})
    return found


def npm_packages(base=None, depth=0):
    """Yields (folder, package.json contents) for every installed package, nested ones included."""
    base = base or os.path.join(PKG, "node_modules")
    if depth > 8 or not os.path.isdir(base):
        return
    for name in sorted(os.listdir(base)):
        if name.startswith("."):
            continue
        folders = [os.path.join(base, name)]
        if name.startswith("@"):
            folders = [os.path.join(base, name, n) for n in sorted(os.listdir(os.path.join(base, name)))]
        for folder in folders:
            if os.path.islink(folder) or not os.path.isdir(folder):
                continue
            try:
                meta = json.load(open(os.path.join(folder, "package.json"), encoding="utf-8"))
            except (OSError, ValueError):
                meta = None
            if isinstance(meta, dict):
                yield folder, meta
            yield from npm_packages(os.path.join(folder, "node_modules"), depth + 1)


def npm_installed():
    return sorted({"%s@%s" % (m.get("name"), m.get("version")) for _, m in npm_packages() if m.get("name")})


def pip_installed():
    out = []
    site = os.path.join(PKG, "site")
    if os.path.isdir(site):
        for n in os.listdir(site):
            m = re.match(r"^(.+)-([^-]+)\.dist-info$", n)
            if m:
                out.append("%s==%s" % (m.group(1), m.group(2)))
    return sorted(out)


def main():
    env = t.read_env()
    what, label = target(env)
    os.makedirs(PKG, exist_ok=True)
    child_env = {"PATH": "/usr/local/bin:/opt/node/bin:/usr/sbin:/usr/bin:/sbin:/bin", "HOME": "/root", "LANG": "C.UTF-8"}
    if KIND == "npm":
        child_env.update({"npm_config_update_notifier": "false", "npm_config_fund": "false", "npm_config_audit": "false",
                          "NODE_DISABLE_COMPILE_CACHE": "1"})
        # --install-links: a folder is installed like a published package (copied, scripts run), not linked.
        cmd = ["npm", "install", "--foreground-scripts", "--install-links", "--no-save", "--loglevel=notice", "--", what]
    else:
        cmd = ["python3", "/opt/pip/pip", "install", "--no-input", "--disable-pip-version-check", "--no-cache-dir",
               "--root-user-action=ignore", "--target", os.path.join(PKG, "site"), "--", what]
    run = t.run_traced(cmd, PKG, SECONDS, env=child_env)
    trace = t.parse_trace(PKG)
    main_pid = trace["first_pid"]
    # Everything the installer started; its own first process (and what that process exec'd into) is left out.
    started = [p for p in trace["processes"] if p["pid"] != main_pid]

    if KIND == "npm":
        declared = npm_declared_scripts()
        for s in declared:
            s["ran"] = any(len(p["argv"]) >= 3 and os.path.basename(p["argv"][0]) in ("sh", "bash", "dash")
                           and p["argv"][1] == "-c" and p["argv"][2] == s["command"] for p in started)
        scripts = declared
        installed = npm_installed()
    else:
        scripts = []
        for p in started:
            joined = " ".join(p["argv"])
            if "setup.py" in joined or "_in_process.py" in joined:
                scripts.append({"package": None, "hook": "build", "command": joined[:300], "ran": True, "cwd": p["cwd"]})
        installed = pip_installed()

    own = OWN[KIND]
    outside = [f for f in trace["files"]["written"] if not any(r.search(f) for r in own)]
    deleted = [f for f in trace["files"]["deleted"] if not any(r.search(f) for r in own)]
    kept, cut = t.copy_trace()
    report = {"recipe": KIND + "-check", "installer": KIND, "target": env.get("FC_RECIPE_PACKAGE") or env.get("FC_RECIPE_SAMPLE") or "(folder)",
              "command": cmd, "run": run, "installed": installed, "install_scripts": scripts, "processes": started,
              "files_outside_install_folder": outside, "files_deleted_outside_install_folder": deleted,
              "files_written_total": len(trace["files"]["written"]), "connections": trace["connections"],
              "trace": {"lines": trace["trace_lines"], "bytes_kept": kept, "cut": cut}, "limits": NOTE}

    if run["timed_out"]:
        outcome = "**stopped after %d s** (the install did not end)" % run["limit_seconds"]
    elif run["signal"]:
        outcome = "ended by signal %d" % run["signal"]
    else:
        outcome = "exit code **%s** after %s s" % (run["exit_code"], run["seconds"])
    md = ["# %s install check: %s" % (KIND, label), "",
          "Command: `%s`" % " ".join(cmd), "", "The install: %s." % outcome, "",
          "## Installed (%d)" % len(installed), ""] + t.md_list(installed, limit=100) + [""]
    if KIND == "npm":
        md += ["## Install scripts (%d declared)" % len(scripts), ""]
        md += t.md_list(["%s@%s %s: %s -- %s" % (s["package"], s["version"], s["hook"], s["command"][:200],
                                              "RAN" if s["ran"] else "not seen running") for s in scripts], limit=100)
    else:
        md += ["## Build code that ran (%d)" % len(scripts), "",
               "A source distribution runs its own build code during install; a wheel does not.", ""]
        md += t.md_list([s["command"] for s in scripts], limit=50)
    md += ["", "## Processes the install started (%d)" % len(started), ""] + t.process_lines(started, limit=150) + ["",
           "## Files written outside the install folder (%d)" % len(outside), "",
           "Not counted: the install folder `/work/pkg`, the uploaded project, and the installer's own cache and temporary build folders "
           "(%d files written in total)." % len(trace["files"]["written"]), ""] + t.md_list(outside, limit=150) + ["",
           "## Files deleted outside the install folder (%d)" % len(deleted), ""] + t.md_list(deleted, limit=50) + ["",
           "## Connections (%d)" % len(trace["connections"]), ""] + t.connection_lines(trace["connections"], limit=150) + ["",
           "## Installer output (first lines)", "", "Untrusted text produced during the install.", "", "```",
           t.tail_text(os.path.join(t.OUT, "program-stdout.log"), 3000) or "(no stdout)", "```", "", "```",
           t.tail_text(os.path.join(t.OUT, "program-stderr.log"), 3000) or "(no stderr)", "```", "",
           "## Limits of this evidence", "", NOTE,
           "The raw trace is in `trace.log`%s." % (" (cut to 50 MiB)" if cut else ""), ""]
    t.write_reports(report, md)
    print("%s-check: %s; %d installed, %d install scripts, %d processes, %d files outside, %d connections" % (
        KIND, outcome.replace("*", ""), len(installed), len(scripts), len(started), len(outside), len(trace["connections"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
