#!/usr/bin/env python3
# Custom git merge driver for PoEformance's version-carrying files
# (InGameStateMonitor.ahk, README.md, CLAUDE.md — see .gitattributes).
#
# It performs a normal 3-way merge, then auto-resolves any conflict hunk whose
# two sides differ ONLY in a 4-part version number (a.b.c.d) by keeping the
# HIGHER version. This matches the project rule "the dev-branch version always
# wins" without depending on merge direction (the dev branch is always ahead).
# Any OTHER conflict is left marked, so real content conflicts still surface.
#
# Git invokes it (configured via `git config merge.poever.driver`) as:
#     python tools/git-merge-version.py %O %A %B %L
#   %O = base (ancestor)   %A = ours (current; the merged result goes here)
#   %B = theirs (other)    %L = conflict-marker length
# Exit 0 = fully resolved; non-zero = conflicts remain (git stops for the user).
#
# NOTE: git's own web merge (github.com) does NOT run local merge drivers — this
# only helps LOCAL merges/rebases. See tools/setup-git-merge-driver.sh.

import re
import subprocess
import sys

base, ours, theirs = sys.argv[1], sys.argv[2], sys.argv[3]
marker = sys.argv[4] if len(sys.argv) > 4 and sys.argv[4].isdigit() else "7"

# Standard 3-way merge to stdout (does not touch `ours` yet).
# Force UTF-8 decoding of the merge output: the version-carrying files hold
# UTF-8 content (emoji, em-dashes) whose bytes are undefined in the Windows
# default (cp1252), which otherwise crashes the stdout reader with a
# UnicodeDecodeError and leaves proc.stdout as None.
proc = subprocess.run(
    ["git", "merge-file", "-p",
     "-L", "ours", "-L", "base", "-L", "theirs",
     "--marker-size", marker, ours, base, theirs],
    capture_output=True, text=True, encoding="utf-8",
)
merged = proc.stdout or ""

# Clean merge → write it through, done.
if proc.returncode == 0:
    with open(ours, "w", encoding="utf-8", newline="") as f:
        f.write(merged)
    sys.exit(0)

# merge-file error (e.g. 255) with no usable output → leave `ours` untouched,
# report a conflict so git falls back to a manual resolution.
if not merged.strip():
    sys.exit(1)

VER = re.compile(r"\d+\.\d+\.\d+\.\d+")


def vkey(v):
    return tuple(int(x) for x in v.split("."))


lt = "<" * int(marker)
eq = "=" * int(marker)
gt = ">" * int(marker)

lines = merged.split("\n")
out = []
i, n = 0, len(lines)
unresolved = False

while i < n:
    line = lines[i]
    if not line.startswith(lt):
        out.append(line)
        i += 1
        continue

    # Collect the ours-block (until the '=======' marker) and the theirs-block
    # (until the '>>>>>>>' marker).
    j = i + 1
    ours_block = []
    while j < n and not lines[j].startswith(eq):
        ours_block.append(lines[j])
        j += 1
    k = j + 1
    theirs_block = []
    while k < n and not lines[k].startswith(gt):
        theirs_block.append(lines[k])
        k += 1
    # k now indexes the '>>>>>>>' marker (or end of file).

    resolved = None
    if len(ours_block) == 1 and len(theirs_block) == 1:
        o, t = ours_block[0], theirs_block[0]
        mo, mt = VER.search(o), VER.search(t)
        # Same line apart from the version number → keep the higher version.
        if mo and mt and VER.sub("", o) == VER.sub("", t):
            resolved = o if vkey(mo.group()) >= vkey(mt.group()) else t

    if resolved is not None:
        out.append(resolved)
    else:
        out.extend(lines[i:k + 1])  # keep the whole conflict hunk untouched
        unresolved = True
    i = k + 1

with open(ours, "w", encoding="utf-8", newline="") as f:
    f.write("\n".join(out))

sys.exit(1 if unresolved else 0)
