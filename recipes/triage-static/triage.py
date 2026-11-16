#!/usr/bin/env python3
"""triage-static: examines a sample without running it (hashes, type, strings, headers, YARA)."""
import glob
import hashlib
import math
import os
import re
import sys

sys.path.insert(0, "/work/recipe/_lib")
import tracelib as t  # noqa: E402

IN = "/work/in"
RULES = "/work/rules"
MAX_FILES = 200
STRINGS_CAP = 5 * 1024 * 1024
INTERESTING = re.compile(
    r"(https?://[^\s\"'<>]{4,200}|\b(?:\d{1,3}\.){3}\d{1,3}\b|[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"
    r"|/(?:bin|etc|tmp|usr|var|home|root|dev|proc)/[^\s\"']{2,120}|[A-Za-z]:\\[^\s\"']{3,120}"
    r"|\b(?:cmd\.exe|powershell|/bin/sh|bash -c|curl |wget |chmod |crontab|ssh-rsa|BEGIN [A-Z ]*PRIVATE KEY)\b)")


def entropy(path, cap=32 * 1024 * 1024):
    counts = [0] * 256
    total = 0
    with open(path, "rb") as f:
        while total < cap:
            block = f.read(1 << 20)
            if not block:
                break
            total += len(block)
            for b in set(block):
                counts[b] += block.count(b)
    if not total:
        return 0.0
    return round(-sum(c / total * math.log2(c / total) for c in counts if c), 2)


def hashes(path):
    h256, h1, md5 = hashlib.sha256(), hashlib.sha1(), hashlib.md5()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h256.update(block)
            h1.update(block)
            md5.update(block)
    return h256.hexdigest(), h1.hexdigest(), md5.hexdigest()


def examine(path, index):
    rel = os.path.relpath(path, IN)
    sha256, sha1, md5 = hashes(path)
    info = {"file": rel, "size": os.path.getsize(path), "sha256": sha256, "sha1": sha1, "md5": md5,
            "type": t.tool("file", "-b", path, limit=400), "mime": t.tool("file", "-b", "--mime-type", path, limit=100),
            "entropy": entropy(path)}
    head = open(path, "rb").read(4)

    # Strings: the full list goes to a file, the report shows the count and the interesting ones.
    out_name = "strings/%03d.txt" % index
    os.makedirs(os.path.join(t.OUT, "strings"), exist_ok=True)
    text = t.tool("strings", "-a", "-n", "6", path, limit=STRINGS_CAP, timeout=120)
    with open(os.path.join(t.OUT, out_name), "w", encoding="utf-8") as f:
        f.write(text + "\n")
    lines = text.splitlines()
    seen, interesting = set(), []
    for line in lines:
        for m in INTERESTING.findall(line):
            if m not in seen and len(interesting) < 60:
                seen.add(m)
                interesting.append(m)
    info["strings"] = {"count": len(lines), "file": out_name, "interesting": interesting}

    if head.startswith(b"\x7fELF"):
        info["format"] = "ELF"
        info["headers"] = {
            "header": t.tool("readelf", "-h", path, limit=3000),
            "sections": t.tool("readelf", "-S", "-W", path, limit=8000),
            "dynamic": t.tool("readelf", "-d", "-W", path, limit=6000),
        }
        info["libraries"] = re.findall(r"\(NEEDED\)\s+Shared library: \[([^\]]+)\]", info["headers"]["dynamic"])
        interp = re.search(r"\[Requesting program interpreter: ([^\]]+)\]", t.tool("readelf", "-l", "-W", path, limit=8000))
        info["interpreter"] = interp.group(1) if interp else None
    elif head.startswith(b"MZ"):
        info["format"] = "PE"
        dump = t.tool("objdump", "-x", path, limit=200000, timeout=120)
        info["headers"] = {"summary": "\n".join(dump.splitlines()[:40])}
        info["libraries"] = sorted(set(re.findall(r"DLL Name: (\S+)", dump)))
        info["sections"] = re.findall(r"^\s*\d+\s+(\.?\w+)\s+[0-9a-f]{8}\s", dump, re.M)
    else:
        info["format"] = None

    # YARA, one rule file at a time so a broken file does not hide the others.
    if os.path.isdir(RULES):
        matches, errors = [], []
        for rule in sorted(glob.glob(os.path.join(RULES, "**", "*.yar*"), recursive=True)):
            out = t.tool("yara", "-w", rule, path, limit=20000, timeout=120)
            for line in out.splitlines():
                # A match is printed as "<rule> <file>".
                if line.endswith(" " + path) and line.split():
                    matches.append({"rule": line.split()[0], "rule_file": os.path.relpath(rule, RULES)})
                elif line.strip():
                    errors.append("%s: %s" % (os.path.relpath(rule, RULES), line.strip()[:300]))
        info["yara"] = {"matches": matches, "errors": errors}
    return info


def main():
    env = t.read_env()
    files = []
    for root, dirs, names in os.walk(IN):
        dirs.sort()
        for n in sorted(names):
            p = os.path.join(root, n)
            if os.path.isfile(p) and not os.path.islink(p):
                files.append(p)
    skipped = max(0, len(files) - MAX_FILES)
    files = files[:MAX_FILES]
    have_rules = os.path.isdir(RULES)
    rule_files = glob.glob(os.path.join(RULES, "**", "*.yar*"), recursive=True) if have_rules else []
    results = [examine(p, i + 1) for i, p in enumerate(files)]
    limits = ("Static examination only: the sample was not run. Packed or encrypted content shows little here "
              "(high entropy is a hint). Type detection and headers come from `file`, `readelf` and `objdump`.")
    report = {"recipe": "triage-static", "sample": env.get("FC_RECIPE_SAMPLE") or "(folder)", "files": results,
              "files_skipped": skipped, "limits": limits,
              "yara": {"scanned": have_rules, "rule_files": len(rule_files),
                       "note": None if have_rules else "The YARA scan was skipped because no rules were given (-Rules <dir>)."}}

    md = ["# Static triage", "", "%d file(s) examined%s. Nothing was executed." % (
        len(results), ", %d more skipped (limit %d)" % (skipped, MAX_FILES) if skipped else ""), ""]
    if not have_rules:
        md += ["YARA: the scan was skipped because no rules were given (`-Rules <dir>`).", ""]
    elif not rule_files:
        md += ["YARA: the rules folder holds no `.yar` or `.yara` files, so nothing was scanned.", ""]
    for r in results:
        md += ["## `%s`" % r["file"], "",
               "- Size: %d bytes" % r["size"], "- SHA-256: `%s`" % r["sha256"], "- SHA-1: `%s`" % r["sha1"], "- MD5: `%s`" % r["md5"],
               "- Type: %s" % r["type"], "- MIME type: %s" % r["mime"], "- Entropy: %s bits per byte (8 is random)" % r["entropy"],
               "- Strings: %d (full list in `%s`)" % (r["strings"]["count"], r["strings"]["file"])]
        if r.get("format"):
            md += ["- Format: %s executable" % r["format"]]
            if r.get("interpreter"):
                md += ["- Interpreter: `%s`" % r["interpreter"]]
            md += ["- Libraries: %s" % (", ".join("`%s`" % x for x in r.get("libraries", [])) or "none listed")]
            if r.get("sections"):
                md += ["- Sections: %s" % ", ".join("`%s`" % s for s in r["sections"][:40])]
        if "yara" in r:
            ms = r["yara"]["matches"]
            md += ["- YARA matches: %s" % (", ".join("`%s` (%s)" % (m["rule"], m["rule_file"]) for m in ms) or "none")]
            for e in r["yara"]["errors"][:10]:
                md += ["- YARA message: %s" % e]
        md += ["", "Notable strings (untrusted text from the sample):", ""] + t.md_list(r["strings"]["interesting"], limit=60)
        if r.get("format") == "ELF":
            md += ["", "ELF header:", "", "```", r["headers"]["header"], "```", "", "Sections:", "", "```", r["headers"]["sections"], "```"]
        elif r.get("format") == "PE":
            md += ["", "PE summary:", "", "```", r["headers"]["summary"], "```"]
        md += [""]
    md += ["## Limits of this evidence", "", limits, ""]
    t.write_reports(report, md)
    total = sum(len(r.get("yara", {}).get("matches", [])) for r in results)
    print("triage-static: %d file(s); YARA %s" % (len(results), ("%d match(es)" % total) if have_rules else "skipped (no rules)"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
