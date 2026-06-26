#!/usr/bin/env python3
"""Build framed PoE2 skill-node UI icons from GGG's official passive-tree export.

For every icon named in Tools/skillnode_map.json this slices the matching node out of
GGG's sprite sheets and composites it with the node frame, producing two PNGs per icon
in img/skillnodes/:
  <name>.png      allocated look   (active art  + allocated frame)   -> section OPEN / tab active
  <name>_off.png  unallocated look (disabled art + unallocated frame)-> section CLOSED / tab idle

Source = grindinggear/poe2-skilltree-export (official, free). The six source files are
cached under Tools/.skilltree_cache/ (gitignored); pass --src DIR to use a local copy.

Run:  python3 Tools/build_skillnode_icons.py
Deps: pillow  (pip install pillow)
"""
import json, os, sys, urllib.request

ROOT  = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CACHE = os.path.join(ROOT, "Tools", ".skilltree_cache")
OUT   = os.path.join(ROOT, "img", "skillnodes")
MAP   = os.path.join(ROOT, "Tools", "skillnode_map.json")
BASE  = "https://raw.githubusercontent.com/grindinggear/poe2-skilltree-export/main/assets/"
FILES = ["skills.webp", "skills.json", "skills-disabled.webp",
         "skills-disabled.json", "frame.webp", "frame.json"]
CANVAS = 64   # uniform output square (px); icons display ~20px so this stays crisp

# allocated / unallocated frame key per node type
FRAME_ALLOC  = {"normal": "PSSkillFrameActive", "notable": "NotableFrameAllocated",   "keystone": "KeystoneFrameAllocated"}
FRAME_UNALLOC= {"normal": "PSSkillFrame",       "notable": "NotableFrameUnallocated", "keystone": "KeystoneFrameUnallocated"}
PREFIX = {"normalActive": "normal", "notableActive": "notable", "keystoneActive": "keystone"}


def src_path(srcdir, name):
    if srcdir:
        return os.path.join(srcdir, name)
    os.makedirs(CACHE, exist_ok=True)
    p = os.path.join(CACHE, name)
    if not os.path.exists(p):
        print("  downloading", name)
        urllib.request.urlretrieve(BASE + name, p)
    return p


def main():
    from PIL import Image
    srcdir = None
    if "--src" in sys.argv:
        srcdir = sys.argv[sys.argv.index("--src") + 1]

    files = {n: src_path(srcdir, n) for n in FILES}
    A  = Image.open(files["skills.webp"]).convert("RGBA")
    D  = Image.open(files["skills-disabled.webp"]).convert("RGBA")
    F  = Image.open(files["frame.webp"]).convert("RGBA")
    fa = json.load(open(files["skills.json"]))["frames"]
    fd = json.load(open(files["skills-disabled.json"]))["frames"]
    ff = json.load(open(files["frame.json"]))["frames"]
    mapping = json.load(open(MAP))

    # index active frames by basename, preferring 'normal' on a basename collision
    # (same source symbol; the simpler ring reads cleaner at header size).
    by_name = {}
    order = {"normal": 0, "notable": 1, "keystone": 2}
    for key in fa:
        pref = key.split(":", 1)[0]
        if pref not in PREFIX:
            continue
        t = PREFIX[pref]
        name = key.split("/")[-1][:-4]
        if name not in by_name or order[t] < order[by_name[name][0]]:
            by_name[name] = (t, key)

    def cut(sheet, frames, key):
        f = frames[key]["frame"]
        return sheet.crop((f["x"], f["y"], f["x"] + f["w"], f["y"] + f["h"])).convert("RGBA")

    def compose(name, allocated):
        t, akey = by_name[name]
        framekey = "frame:" + (FRAME_ALLOC[t] if allocated else FRAME_UNALLOC[t])
        fr = cut(F, ff, framekey)
        if allocated:
            ico = cut(A, fa, akey)
        else:
            ico = cut(D, fd, akey.replace("Active:", "Inactive:", 1))
        node = Image.new("RGBA", fr.size, (0, 0, 0, 0))
        node.alpha_composite(ico, ((fr.width - ico.width) // 2, (fr.height - ico.height) // 2))
        node.alpha_composite(fr, (0, 0))
        # fit (contain) onto the uniform square so every node shares one footprint
        s = CANVAS / max(node.width, node.height)
        node = node.resize((max(1, round(node.width * s)), max(1, round(node.height * s))), Image.LANCZOS)
        out = Image.new("RGBA", (CANVAS, CANVAS), (0, 0, 0, 0))
        out.alpha_composite(node, ((CANVAS - node.width) // 2, (CANVAS - node.height) // 2))
        return out

    os.makedirs(OUT, exist_ok=True)
    names = sorted(set(mapping.values()))
    missing = [n for n in names if n not in by_name]
    if missing:
        print("ERROR: unknown icon names:", missing)
        sys.exit(1)
    for n in names:
        compose(n, True).save(os.path.join(OUT, n + ".png"))
        compose(n, False).save(os.path.join(OUT, n + "_off.png"))
    print(f"wrote {len(names) * 2} PNGs ({len(names)} icons) to img/skillnodes/")


if __name__ == "__main__":
    main()
