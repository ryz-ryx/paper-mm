#!/usr/bin/env python3
"""Pre-freeze check: PREREG v1.06 changes text only; every numeric parameter equals v1.05.

Usage: python check_params.py <v1.05 PREREG.md> <v1.06 PREREG.md>
1. Registered parameter table: each parameter is located by a regex in BOTH versions (body only, change log
   excluded) and its value(s) must be identical.
2. Numeric-token audit: every number in the body (outside the change log and the version lines) is counted in
   both versions; numbers that appear only in v1.06 or only in v1.05 are listed. Allowed differences must be
   explained (version strings, section cross-references, list item numbers).
Exit 0 = all parameters identical; 1 = a parameter differs or is missing.
"""
import re
import sys
from collections import Counter

PARAMS = [
    ("symbols", r"`EURUSD`.*?`USDJPY`", None),
    ("lot size", r"`(0\.01)`\s*lot", 1),
    ("lookback bars", r"[Ll]ookback[^.\n]*?(\d+)\s*(?:completed\s*)?(?:M1\s*)?bars", 1),
    ("window_id seconds", r"window_id[^\n]*?/\s*(300)", 1),
    ("spread gate cap pip", r"\\min\((0\.3)\\text\{ pip\}", 1),
    ("spread gate percentile", r"(60)th percentile", 1),
    ("tick freshness ms", r"(3000)\s*(?:\\text\{\s*)?ms", 1),
    ("session start", r"`(07:00(?::00)?)", 1),
    ("session end", r"(16:00(?::00)?)", 1),
    ("news exclusion minutes", r"(10)\s*min(?:utes)?\b", 1),
    ("degraded window 1", r"`?(12:25(?::00)?)\s*[-–]\s*(12:40(?::00)?)", None),
    ("degraded window 2", r"`?(13:25(?::00)?)\s*[-–]\s*(13:40(?::00)?)", None),
    ("TP/SL pips", r"\\pm\s*(5\.0)\$?-?\s*pip", 1),
    ("time stop s", r"\$(300)\$\s*seconds", 1),
    ("burn-in N", r"N_\{\\text\{burn\}\}\s*=\s*(\d+)", 1),
    ("target N", r"N\s*=\s*(900)", 1),
    ("alpha", r"\\alpha\s*=\s*(0\.025)", 1),
    ("spread fidelity factor", r"(1\.20)\s*\\times\s*S", 1),
    ("daily volume cap", r"[Mm]aximum of \$?(\d+)\$? completed trades per day per symbol", 1),
    ("daily loss stop pips", r"\*\*\$?(30\.0)\$?\s*pips\*\*", 1),
    ("consecutive error breaker", r"If \$?(\d+)\$? consecutive order dispatches", 1),
    ("hard stop weeks", r"(?i)start date\s*\+\s*(8)\s*weeks", 1),
    ("p0 formula", r"p_0\s*=\s*\\frac\{\|\\bar\{L\}\|\}\{\\bar\{W\}\s*\+\s*\|\\bar\{L\}\|\}", None),
    ("net pips formula", r"net\\_pips\}\s*=\s*\\text\{gross\\_pips\}\s*-\s*2\s*\\times\s*\\text\{commission\\_pips\}", None),
]


def body(text: str) -> str:
    """Document body without the change log (from '## Change Log' to the next '## ' heading) and version lines."""
    out, skip = [], False
    for line in text.split("\n"):
        if line.startswith("## Change Log"):
            skip = True
            continue
        if skip and line.startswith("## "):
            skip = False
        if skip:
            continue
        if re.search(r"Document Version|^Version:|^# Pre-Registration", line):
            continue
        out.append(line)
    return "\n".join(out)


def find_all(rx, text):
    vals = []
    for m in re.finditer(rx, text, flags=re.S):
        vals.append(m.groups() if m.groups() else (m.group(0),))
    return vals


def main():
    old_raw = open(sys.argv[1], encoding="utf-8").read()
    new_raw = open(sys.argv[2], encoding="utf-8").read()
    old, new = body(old_raw), body(new_raw)
    if len(sys.argv) > 3:  # v1.05 states some parameters only in ACCOUNT.md (e.g. hard stop = start + 8 weeks)
        old_param_text = old + "\n" + open(sys.argv[3], encoding="utf-8").read()
    else:
        old_param_text = old
    bad = 0
    print(f"{'parameter':28s} {'v1.05':34s} {'v1.06':34s} result")
    for name, rx, grp in PARAMS:
        a, b = find_all(rx, old_param_text), find_all(rx, new)
        va = sorted(set(a)) if a else []
        vb = sorted(set(b)) if b else []
        ok = bool(va) and va == vb
        if not ok:
            bad += 1
        fa = "; ".join("/".join(x) for x in va)[:33] or "(not found)"
        fb = "; ".join("/".join(x) for x in vb)[:33] or "(not found)"
        print(f"{name:28s} {fa:34s} {fb:34s} {'identical' if ok else 'DIFFERS'}")
    num = r"(?<![\w.])\d+(?:\.\d+)?(?![\w.])"
    ca, cb = Counter(re.findall(num, old)), Counter(re.findall(num, new))
    only_new = {k: cb[k] - ca[k] for k in cb if cb[k] > ca[k]}
    only_old = {k: ca[k] - cb[k] for k in ca if ca[k] > cb[k]}
    print("\nnumeric tokens (body, change log excluded): added in v1.06:", dict(sorted(only_new.items())))
    print("numeric tokens (body, change log excluded): removed in v1.06:", dict(sorted(only_old.items())))
    print(f"\nRESULT: {'all registered parameters identical' if bad == 0 else str(bad) + ' parameter(s) differ or not found'}")
    sys.exit(0 if bad == 0 else 1)


if __name__ == "__main__":
    main()
