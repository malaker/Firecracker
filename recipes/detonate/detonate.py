#!/usr/bin/env python3
"""detonate: runs the sample under strace in an isolated VM and reports what it did.

Usage: detonate.py [seconds]   (how long the sample may run; default 120)
"""
import os
import sys

sys.path.insert(0, "/work/recipe/_lib")
import tracelib as t  # noqa: E402

SECONDS = int(sys.argv[1]) if len(sys.argv) > 1 else 120
IN = "/work/in"
INTERPRETERS = {".sh": ["sh"], ".bash": ["bash"], ".py": ["python3"], ".js": ["node"], ".mjs": ["node"], ".pl": ["perl"]}


def how_to_start(path):
    """Returns (argv, description), or (None, reason) when the file cannot be run here."""
    try:
        head = open(path, "rb").read(4)
    except OSError as e:
        return None, "cannot read the sample: %s" % e
    if head.startswith(b"\x7fELF"):
        return [path], "run directly (ELF executable)"
    if head.startswith(b"#!"):
        return [path], "run directly (script with a #! line)"
    ext = os.path.splitext(path)[1].lower()
    if ext in INTERPRETERS:
        return INTERPRETERS[ext] + [path], "run with %s (by file extension)" % INTERPRETERS[ext][0]
    if head.startswith(b"MZ"):
        return None, "a Windows executable cannot run in this Linux VM; use triage-static"
    return None, "not an ELF executable, no #! line and no known extension (.sh .bash .py .js .mjs .pl)"


def main():
    env = t.read_env()
    if env.get("FC_RECIPE_SAMPLE_KIND") == "dir":
        name = env.get("FC_RECIPE_ENTRY", "")
    else:
        name = env.get("FC_RECIPE_SAMPLE", "")
    path = os.path.join(IN, name)
    report = {"recipe": "detonate", "sample": name, "limits": t.EVIDENCE_NOTE}
    md = ["# Detonation of `%s`" % name, ""]
    if not name or not os.path.isfile(path):
        report["error"] = "sample file not found in the guest"
        t.write_reports(report, md + ["The sample file was not found in the guest."])
        print("detonate: sample not found")
        return 0

    report["sha256"] = t.sha256_file(path)
    report["size"] = os.path.getsize(path)
    report["file_type"] = t.tool("file", "-b", path, limit=300)
    argv, how = how_to_start(path)
    report["started"] = how
    md += ["- SHA-256: `%s`" % report["sha256"], "- Size: %d bytes" % report["size"],
           "- Type: %s" % report["file_type"], "- Start: %s" % how, ""]
    if argv is None:
        report["runnable"] = False
        t.write_reports(report, md + ["**The sample was not run:** %s." % how, "", "## Limits of this evidence", "", t.EVIDENCE_NOTE])
        print("detonate: not run: %s" % how)
        return 0

    os.chmod(path, 0o755)
    run = t.run_traced(argv, os.path.dirname(path), SECONDS)
    trace = t.parse_trace(os.path.dirname(path))
    # The first process is the sample itself.
    started = trace["processes"][1:] if trace["processes"] else []
    newer = [p for p in t.newer_files() if p not in trace["files"]["written"]]
    kept, cut = t.copy_trace()
    report.update({"runnable": True, "run": run, "processes": started, "connections": trace["connections"],
                   "files": trace["files"], "files_newer_on_disk": newer,
                   "trace": {"lines": trace["trace_lines"], "bytes_kept": kept, "cut": cut}})

    if run["timed_out"]:
        outcome = "**stopped after %d s** (the sample did not end by itself)" % run["limit_seconds"]
    elif run["signal"]:
        outcome = "ended by signal %d after %s s" % (run["signal"], run["seconds"])
    else:
        outcome = "exit code **%s** after %s s" % (run["exit_code"], run["seconds"])
    md += ["## Outcome", "", "The sample: %s." % outcome, "",
           "## Processes it started (%d)" % len(started), ""] + t.process_lines(started) + ["",
           "## Network connections it attempted (%d)" % len(trace["connections"]), "",
           "This VM has no network device, so every attempt fails.", ""] + t.connection_lines(trace["connections"]) + ["",
           "## Files it created or changed (%d)" % len(trace["files"]["written"]), ""] + t.md_list(trace["files"]["written"]) + ["",
           "## Files it deleted (%d)" % len(trace["files"]["deleted"]), ""] + t.md_list(trace["files"]["deleted"]) + ["",
           "## Other changed files found on disk (%d)" % len(newer), "",
           "Files newer than the start of the run that the trace did not attribute to the sample (system services write some).", ""]
    md += t.md_list(newer, limit=50) + ["",
           "## Program output (first lines)", "", "Untrusted text produced by the sample.", "", "```",
           t.tail_text(os.path.join(t.OUT, "program-stdout.log"), 2000) or "(no stdout)", "```", "", "```",
           t.tail_text(os.path.join(t.OUT, "program-stderr.log"), 2000) or "(no stderr)", "```", "",
           "## Limits of this evidence", "", t.EVIDENCE_NOTE,
           "The raw trace is in `trace.log`%s." % (" (cut to 50 MiB)" if cut else ""), ""]
    t.write_reports(report, md)
    print("detonate: %s; %d processes, %d connection attempts, %d files changed" % (
        outcome.replace("*", ""), len(started), len(trace["connections"]), len(trace["files"]["written"])))
    return 0


if __name__ == "__main__":
    sys.exit(main())
