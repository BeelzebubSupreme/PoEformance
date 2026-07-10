#!/usr/bin/env python3
"""Build data/vaal_ruins_rooms.json for the Vaal Ruins Route Planner.

Merges the GGPK-extracted room data (data/incursion2_rooms.tsv +
data/incursion2_room_levels.tsv, produced by the PoeDataExtract
Incursion2Rooms / Incursion2RoomPerLevel extractors) with a small CURATED
overlay of the gameplay rules the dat doesn't spell out — each room's Temple
Mod bonus text and its adjacency upgrade/conversion rules, taken from the
mobalytics / maxroll Vaal Temple guides.

Vaal Ruins = PoE2's reworked Incursion (Temple of Atzoatl). Rooms connect by
ADJACENCY + path chaining from the entrance (NOT doorway edge-matching), and
upgrade to higher tiers by having specific room types placed ADJACENT to them.

Run from the repo root:  python tools/build_vaal_ruins_data.py
Re-run after re-extracting the TSVs (e.g. after a game patch).
"""
import csv, json, os, sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ROOMS_TSV  = os.path.join(ROOT, "data", "incursion2_rooms.tsv")
LEVELS_TSV = os.path.join(ROOT, "data", "incursion2_room_levels.tsv")
OUT_JSON   = os.path.join(ROOT, "data", "vaal_ruins_rooms.json")

def cid(tsv_id: str) -> str:
    """Canonical id = lowercased dat Id (Garrison -> garrison)."""
    return tsv_id.strip().lower()

# ── Curated overlay: gameplay rules from the Vaal Temple guides ──────────────
# bonus  = the Temple Mod the room adds (# = a scaling value).
# upBy   = adjacency upgrade rules: list of {type, count?, tier?, note?}.
#          count defaults to 1; tier is the tier reached (informational).
# convert= adjacency CONVERSION rules: {whenAdjacent, to}.
# value  = rough desirability weight for the scorer (tunable).
# cat    = room | path | entrance | reward | boss | special.
GUIDE = {
  # ── core upgradeable rooms ──
  "garrison":   {"bonus":"#% increased Number of Magic Packs", "value":3,
                 "convert":[{"whenAdjacent":"synthfleshlab","to":"transcendentbarracks"},
                            {"whenAdjacent":"viperspymaster","to":"viperlegionbarracks"}]},
  "commander":  {"bonus":"Rare Monsters have #% increased Effectiveness", "value":4,
                 "upBy":[{"type":"garrison","count":2,"tier":2},
                         {"type":"garrison","count":3,"tier":3}]},
  "viperspymaster": {"bonus":"#% increased effect of Temple Mods from Garrisons, Commanders, "
                              "Armouries, Smithies and Legion Barracks", "value":5,
                 "upBy":[{"type":"viperspymaster","note":"upgraded by defeating other Spymasters"}]},
  "viperlegionbarracks": {"bonus":"Legion of Garrison + Spymaster", "value":4,
                 "upBy":[{"type":"viperspymaster"},{"type":"synthfleshlab"}]},
  "armoury":    {"bonus":"Humanoid Monsters have #% increased Effectiveness", "value":3,
                 "upBy":[{"type":"smithy"},{"type":"alchemylab"}]},
  "smithy":     {"bonus":"Chests have #% increased Item Rarity", "value":2,
                 "upBy":[{"type":"golemworks"},{"type":"generator"}]},
  "generator":  {"bonus":"Construct Monsters have #% increased Effectiveness; Powers adjacent rooms",
                 "value":3, "upBy":[{"type":"thaumaturge"},{"type":"sacrificialchamber"}]},
  "golemworks": {"bonus":"#% increased Effect of Temple Mods from Generators, Synthflesh Labs, "
                          "Flesh Surgeons, Transcendent Barracks and Alchemy Labs", "value":3,
                 "upBy":[{"type":"generator"}]},
  "thaumaturge":{"bonus":"#% increased Effect of Temple Mods from Corruption Chambers, "
                          "Treasure Vaults and Sacrificial Chambers", "value":4,
                 "upBy":[{"type":"sacrificialchamber","tier":2}]},
  "alchemylab": {"bonus":"#% increased Rarity of items dropped by Monsters and #% increased Gold",
                 "value":3, "upBy":[{"type":"thaumaturge","count":1,"tier":2},
                                    {"type":"thaumaturge","count":2,"tier":3}]},
  "corruption": {"bonus":"Rare Monsters have a #% chance to have an additional Modifier", "value":4,
                 "upBy":[{"type":"thaumaturge"},{"type":"sacrificialchamber"}]},
  "fleshsurgeon":{"bonus":"Unique Monsters have #% increased Effectiveness", "value":3,
                 "upBy":[{"type":"synthfleshlab","tier":2},
                         {"type":"synthfleshlab","poweredBy":"generator","tier":3}]},
  "sacrificialchamber":{"bonus":"#% increased number of Rare Chests", "value":5,
                 "upBy":[{"type":"*","note":"upgrades when Sacrificing other placed Rooms"}]},
  "synthfleshlab":{"bonus":"Monsters grant #% increased Experience", "value":3,
                 "upBy":[{"type":"fleshsurgeon","tier":2},{"type":"generator","tier":3}]},
  "transcendentbarracks":{"bonus":"Empowered Garrison (via Synthflesh Lab)", "value":4},
  "vault":      {"bonus":"Contains valuable Chests based on surrounding Rooms", "value":5},
  # ── Architect reward rooms (special; destabilise after completion) ──
  "accesschamber":     {"cat":"reward","reward":"Unlocks Atziri's Chamber","value":6},
  "currencyreward":    {"cat":"reward","reward":"Two Treasure Chests dropping a lot of Currency","value":6},
  "uniquereward":      {"cat":"reward","reward":"Display granting a random Unique Item","value":5},
  "lineagesupportreward":{"cat":"reward","reward":"Random Lineage Support Gem","value":5},
  "socketablereward":  {"cat":"reward","reward":"Rune Cache — a high-level endgame Rune","value":5},
  "tabletreward":      {"cat":"reward","reward":"Corrupted Precursor Machine (modifies a Tablet)","value":5},
  "unsocketingreward": {"cat":"reward","reward":"Extraction Workbench (returns socketed Augments)","value":4},
  # ── structural ──
  "atziri":     {"cat":"boss","reward":"Atziri encounter (final target)","value":10},
  "architect":  {"cat":"special","reward":"Defeat the Architect to unlock reward rooms","value":4},
  "entrance":   {"cat":"entrance","value":0},
  "path":       {"cat":"path","value":0},
  "poweredpath":{"cat":"path","bonus":"Path that also Powers adjacent rooms","value":0},
  "sacrificeroom":{"cat":"special","reward":"Sacrifice a placed Room to upgrade a Sacrificial Chamber","value":1},
  "nothing":    {"cat":"special","value":0},
  "deadspymaster":{"cat":"special","value":0},
}
# The 6 biome reward variants share one entry.
for b in ("biomewater","biomemountain","biomegrass","biomeforest","biomeswamp","biomedesert"):
    GUIDE[b] = {"cat":"reward","reward":"Terraforming Research (biome mod)","value":3}

def load_rooms():
    rooms = []  # index-aligned with the dat
    with open(ROOMS_TSV, encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            rooms.append(row)
    return rooms

def load_tiers():
    by_index = {}
    with open(LEVELS_TSV, encoding="utf-8") as f:
        for row in csv.DictReader(f, delimiter="\t"):
            idx = int(row["room_index"])
            by_index.setdefault(idx, []).append({
                "level": int(row["level"]),
                "name": row["name"],
                "desc": row["description"],
            })
    for idx in by_index:
        by_index[idx].sort(key=lambda t: t["level"])
    return by_index

def main():
    rooms = load_rooms()
    tiers = load_tiers()
    out = []
    for i, r in enumerate(rooms):
        rid = cid(r["id"])
        if rid in ("nothing",):   # engine placeholder, not placeable
            continue
        g = GUIDE.get(rid, {})
        is_path = r["is_pathway"] == "1"
        is_reward = r["is_boss_reward"] == "1"
        cat = g.get("cat") or ("path" if is_path else ("reward" if is_reward else "room"))
        entry = {
            "id": rid,
            "name": (r["name"] or r["id"]).strip(),
            "cat": cat,
            "isPath": is_path,
            "isReward": is_reward,
            "value": g.get("value", 2),
        }
        if g.get("bonus"):   entry["bonus"]   = g["bonus"]
        if g.get("reward"):  entry["reward"]  = g["reward"]
        if g.get("upBy"):    entry["upgradeBy"] = g["upBy"]
        if g.get("convert"): entry["convertsTo"] = g["convert"]
        # Raw dat adjacency-upgrade hint (multiset of room ids) + conversion.
        upraw = [cid(x) for x in r["upgraded_by"].split(";") if x]
        if upraw: entry["datUpgradedBy"] = upraw
        conv = [cid(x) for x in r["converted_to"].split(";") if x]
        if conv: entry["datConvertsTo"] = conv
        ts = tiers.get(i)
        if ts: entry["tiers"] = ts
        if r["icon"]: entry["icon"] = r["icon"]
        out.append(entry)

    doc = {
        "_source": "GGPK incursion2rooms/incursion2roomperlevel + curated guide overlay",
        "_note": "Vaal Ruins connect by ADJACENCY + path chaining from the entrance; "
                 "rooms upgrade via adjacent room types. Regenerate with "
                 "tools/build_vaal_ruins_data.py after re-extracting the TSVs.",
        "grid": 9,
        "handSize": 6,
        "medallionSlots": {"default": 3, "max": 6},
        "rooms": out,
    }
    with open(OUT_JSON, "w", encoding="utf-8", newline="\n") as f:
        json.dump(doc, f, indent=1, ensure_ascii=False)
        f.write("\n")
    counts = {}
    for e in out: counts[e["cat"]] = counts.get(e["cat"], 0) + 1
    print(f"wrote {OUT_JSON}: {len(out)} rooms  {counts}")

    # Inject a compact copy into the standalone planner HTML between markers,
    # so the prototype (opened via file://, no fetch) always carries the data.
    inject_html(doc)

def inject_html(doc):
    html_path = os.path.join(ROOT, "ui", "vaal_ruins_planner.html")
    if not os.path.exists(html_path):
        return
    start = "/* VAAL-DATA-START (generated by tools/build_vaal_ruins_data.py — do not edit by hand) */"
    end   = "/* VAAL-DATA-END */"
    with open(html_path, encoding="utf-8") as f:
        html = f.read()
    i, j = html.find(start), html.find(end)
    if i < 0 or j < 0 or j < i:
        print("  (planner HTML markers not found — skipped inject)")
        return
    compact = json.dumps(doc, ensure_ascii=False, separators=(",", ":"))
    block = f"{start}\nconst VAAL = {compact};\n{end}"
    html = html[:i] + block + html[j + len(end):]
    with open(html_path, "w", encoding="utf-8", newline="\n") as f:
        f.write(html)
    print(f"  injected {len(compact)} bytes into {html_path}")

if __name__ == "__main__":
    sys.exit(main())
