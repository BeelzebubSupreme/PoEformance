#!/usr/bin/env python3
"""diag_skill_link.py - reverse-engineer how a live GrantedEffects.Id maps to a
display name, so the skill-name map can resolve renamed skills WITHOUT a manual
alias list.

The Actor reports the base GrantedEffects.Id live (e.g. "CircleOfPower"), but the
display name ("Sigil of Power") lives on a differently-named ActiveSkills row. The
build tool only follows GrantedEffects.ActiveSkill -> ActiveSkills.DisplayedName,
which yields nothing for these rows, so they are dropped.

This script dumps everything needed to find a deterministic join:
  - the column names of GrantedEffects / ActiveSkills (+ a few related tables),
  - the full GrantedEffects row for each problem id (+ the ActiveSkills row it
    points at via the ActiveSkill index),
  - the reverse: every ActiveSkills row whose DisplayedName is the target, plus
    every GrantedEffects row that references it.

Usage:
    python diag_skill_link.py [csv_dir]
    (csv_dir defaults to ../data/raw_csv/data/balance, like build_item_names_csv.py)
"""

import csv
import os
import sys

# Live GrantedEffects.Id the Actor reports -> the display name we expect.
TARGETS = {
    "CircleOfPower": "Sigil of Power",
    "Firewall": "Flame Wall",
    "StormCloud": "Orb of Storms",
    # a working skill for comparison (resolves today):
    "SparkPlayer": "Spark",
}

# Tables to inspect (loaded if present). The first two are the core join.
TABLES = ["GrantedEffects", "ActiveSkills", "GrantedEffectsPerLevel", "SkillGems"]


def load(csv_dir, name):
    path = os.path.join(csv_dir, name + ".csv")
    if not os.path.isfile(path):
        print(f"  (missing) {name}.csv")
        return None, []
    with open(path, "r", encoding="utf-8") as f:
        reader = csv.DictReader(f)
        rows = list(reader)
        return (reader.fieldnames or []), rows


def safe_int(v, default=-1):
    if v is None or v == "":
        return default
    try:
        return int(v)
    except ValueError:
        try:
            return int(float(v))
        except ValueError:
            return default


def show_row(row, cols, indent="    "):
    for c in cols:
        val = row.get(c, "")
        if val not in ("", "[]", "0", None):   # skip empty/zero for readability
            print(f"{indent}{c} = {val}")


def main():
    script_dir = os.path.dirname(os.path.abspath(__file__))
    data_dir = os.path.join(os.path.dirname(script_dir), "data")
    csv_dir = sys.argv[1] if len(sys.argv) > 1 else os.path.join(data_dir, "raw_csv", "data", "balance")
    csv_dir = os.path.realpath(csv_dir)
    print(f"csv_dir = {csv_dir}\n")

    tables = {}
    for name in TABLES:
        cols, rows = load(csv_dir, name)
        tables[name] = (cols, rows)
        if cols:
            print(f"== {name}.csv columns ({len(rows)} rows) ==")
            print("   " + ", ".join(cols))
            print()

    ge_cols, ge_rows = tables.get("GrantedEffects", ([], []))
    as_cols, as_rows = tables.get("ActiveSkills", ([], []))
    if not ge_rows or not as_rows:
        print("Need GrantedEffects.csv and ActiveSkills.csv — aborting.")
        return

    # Index ActiveSkills by row number (foreign rows are 0-based indices) and by Id.
    as_by_id = {}
    for i, r in enumerate(as_rows):
        rid = (r.get("Id", "") or "").strip()
        if rid:
            as_by_id.setdefault(rid, i)

    print("\n########## FORWARD: GrantedEffects.Id -> ActiveSkill row ##########")
    for ge_id, expect in TARGETS.items():
        print(f"\n--- GrantedEffects Id='{ge_id}'  (expect '{expect}') ---")
        matches = [r for r in ge_rows if (r.get("Id", "") or "").strip() == ge_id]
        if not matches:
            print("    NO GrantedEffects row with this exact Id.")
            continue
        for r in matches:
            show_row(r, ge_cols)
            as_ref = safe_int(r.get("ActiveSkill", ""))
            print(f"    -> ActiveSkill (foreign row index) = {as_ref}")
            if 0 <= as_ref < len(as_rows):
                ar = as_rows[as_ref]
                print(f"       ActiveSkills[{as_ref}]: Id='{ar.get('Id','')}' "
                      f"DisplayedName='{ar.get('DisplayedName','')}' "
                      f"Icon='{ar.get('Icon_DDSFile','')}'")
            else:
                print("       (no valid ActiveSkills row referenced)")

    print("\n########## REVERSE: DisplayedName -> ActiveSkills row -> GrantedEffects ##########")
    want_names = set(TARGETS.values())
    name_to_asrows = {}
    for i, r in enumerate(as_rows):
        dn = (r.get("DisplayedName", "") or "").strip()
        if dn in want_names:
            name_to_asrows.setdefault(dn, []).append(i)
    for dn in sorted(want_names):
        print(f"\n--- DisplayedName='{dn}' ---")
        idxs = name_to_asrows.get(dn, [])
        if not idxs:
            print("    NO ActiveSkills row with this DisplayedName.")
            continue
        for i in idxs:
            ar = as_rows[i]
            print(f"    ActiveSkills[{i}]: Id='{ar.get('Id','')}' Icon='{ar.get('Icon_DDSFile','')}'")
            # which GrantedEffects rows point at this ActiveSkills row?
            refs = [r for r in ge_rows if safe_int(r.get("ActiveSkill", "")) == i]
            if refs:
                print(f"      referenced by GrantedEffects: "
                      + ", ".join((r.get('Id','') or '') for r in refs))
            else:
                print("      (no GrantedEffects.ActiveSkill points here)")

    print("\nDone. Share this output so the join can be made generic.")


if __name__ == "__main__":
    main()
