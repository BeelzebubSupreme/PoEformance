#!/bin/sh
# Registers the "poever" merge driver for this repo so the version-line conflicts
# in InGameStateMonitor.ahk / README.md / CLAUDE.md auto-resolve to the higher
# version on LOCAL merges/rebases (see .gitattributes + tools/git-merge-version.py).
#
# Run once per clone:   sh tools/setup-git-merge-driver.sh
# The mapping in .gitattributes is committed; only this driver DEFINITION lives in
# .git/config (not committable), so re-run this after a fresh clone.
#
# NOTE: GitHub's web "Merge" button does NOT run local merge drivers. To benefit,
# merge locally, e.g.:
#     git checkout master && git merge <dev-branch> && git push
set -e

# Prefer python3, fall back to python (Git Bash on Windows exposes `python`).
PY=python3
command -v "$PY" >/dev/null 2>&1 || PY=python

git config merge.poever.name "Keep the higher PoEformance version on conflict"
git config merge.poever.driver "$PY tools/git-merge-version.py %O %A %B %L"

echo "Configured merge.poever.driver = $PY tools/git-merge-version.py %O %A %B %L"
echo "Version-line conflicts in the tracked files now auto-resolve on local merges."
