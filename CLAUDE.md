# Project conventions for Claude

Path of Exile 2 memory-reading / overlay assistant. AutoHotkey v2 + a WebView2 UI.
Reimplementation of the original C# project (see Reference). Version `0.45.13.332`.

## Language

**All written output must be in English.** That includes:

- Source code (variable names, function names, file names)
- Code comments (block comments, line comments, docstrings)
- Git commit messages
- Pull-request titles, descriptions, review comments
- Issue text on GitHub
- Any other artifact that ends up on GitHub or in the repo

Chat replies inside the editor may use whatever language the user is
writing in (German is fine), but the moment something gets committed
or posted to GitHub, switch to English.

The user is a native German speaker but explicitly wants the project
to stay in English so future contributors / public review aren't
blocked by language. Don't ask for translation help — just translate
inline when authoring commit messages, PR bodies, etc.

## Working rules

- **Never guess.** When unclear, first check the C# reference project (below); ask a
  clarifying question before doing extensive work.
- **Plan first** for larger tasks, then break them into small, verifiable steps.
- **Performance matters** — keep the per-frame render / radar hot path (every ~50–100 ms)
  as cheap as possible.
- Keep files small; split into new `*.ahk` modules via `#Include` when a single file grows
  substantially.
- New functions get a short 2-3 line comment explaining purpose, parameters, and return value.
- Variable names follow the existing camelCase / snake_case style of surrounding code.
- When a change can only be verified in-game, say so and list exactly what to check.
- **Bump the version after every change.** Increment the last segment of the version
  number on each adjustment — in **all three** of `InGameStateMonitor.ahk`
  (`POEFORMANCE_VERSION := "x.y.z.N"`), `CLAUDE.md` (the `Version` line above), and
  `README.md` (the `version-vX.Y.Z.N` badge), e.g. `0.45.12.2` → `0.45.12.3`. Keep all
  three in sync. **The dev branch owns the version** — it is the single source of truth.
  Always count up from the dev branch's own latest value; never reset it to match
  `master`. `master` is not bumped independently, so on merge the dev-branch version
  always wins (resolve any version-line conflict by taking the dev-branch value).
  A **merge driver automates this for LOCAL merges**: `.gitattributes` maps the three
  version files to `merge=poever` (`tools/git-merge-version.py`), which keeps the higher
  version on a version-only conflict (direction-independent). It needs a one-time local
  setup — `sh tools/setup-git-merge-driver.sh` (or `tools\setup-git-merge-driver.bat`) —
  since the driver definition lives in `.git/config`, not the repo. GitHub's web "Merge"
  button does NOT run merge drivers, so merge LOCALLY to benefit
  (`git checkout master && git merge <dev-branch> && git push`).
- **Always end a reply that committed & pushed with the exact pull command** so the
  user can grab it locally, e.g. `git pull origin <current-dev-branch>`. Every time a
  change is pushed — no exceptions. The user merges the dev branch onto `master`
  themselves later, so only ever hand them the dev-branch pull — never merge to
  `master` or push there yourself.
  **Never add the current AI Session to the end of the commit message** — Skip the entire line (e.g. "https://claude.ai/code/session_123456789abcdef")

### Completion-summary format (lean, GitHub-ready)
When wrapping up a task, output the summary as ONE copyable raw GitHub-flavored
markdown block (a fenced ```` ```markdown ```` code block), so it can be pasted
straight into a PR/issue/commit. Because it is destined for GitHub, write it in
**English** (per the Language rules above). Use this fixed, lean structure and
show only the sections that have content — never pad with empty headings:

- **Summary** — one sentence on what was achieved.
- **Changes** — bullet list, `path/file.ext:line — what & why`.
- **Advices** — everything the needs to know about how the changes work.
- **Open / Next steps** only when actually relevant. Any prose outside the block
(chat commentary) may stay German.

## Project structure & conventions

- **Entry point:** `InGameStateMonitor.ahk` (repo root). Run with **AutoHotkey v2**.
- **All other `.ahk` files live in `ahk/`.**
- **UI:** `ui/index.html` — one self-contained file with a single inline `<script>`,
  rendered in a WebView2 control.
- **Sounds:** alert `.wav` files live in the root **`wav/`** folder.
- **Logs:** `.log` files live in the root **`logs/`** folder.
- **Data:** `.tsv` files needed for translating internal strings by using a dictionary live in the root **`data/`** folder.
- **Tools:** `.py` files needed for building the dictionaries live in the root **`tools/`** folder.
  (All repo folders are lowercase except `Lib/` — keep new paths lowercase, or a
  `Tools/` vs `tools/` case-collision breaks checkout on case-insensitive Windows/macOS.)

### Include conventions
- `InGameStateMonitor.ahk` includes with the `ahk/` prefix, e.g. `#Include ahk/RadarOverlay.ahk`.
- Files inside `ahk/` include each other with bare names, e.g. `#Include EntityFacts.ahk`.

### ⚠️ AHK v2 gotcha — module init (read before adding globals)
Feature modules are `#Include`d at the **bottom** of `InGameStateMonitor.ahk` (after the
auto-execute `return`, ~line 437). Function/class definitions still work, but **top-level
`global x := value` initializers in those modules never run.**

→ **Initialize every module global inside a `Load…()` / init function the main script calls
before its `return`** (see `LoadEntityGroups()`, `LoadEntityAlertsConfig()` around line ~295).
Seed defaults **unconditionally** (defaults first, then optionally overlay from INI). The
symptom of getting this wrong is the runtime error *"This global variable has not been
assigned a value."*

### Persistence (self-persist pattern, like LootPickup)
Each module owns its INI section: Groups → `poeformance_config.ini [Groups]`;
Alerts → `alerts.ini [Alerts]`.

### AHK ↔ WebView bridge
- AHK → JS: `PushHeaderToWebView()` builds a JSON header and calls `updateHeader(...)`.
- JS → AHK: UI calls `ahkCall(name, ...args)`, dispatched in `ahk/BridgeDispatch.ahk`.

### Line endings (preserve per file when editing)
- **CRLF:** `BridgeDispatch.ahk`, `WebViewBridge.ahk`. **LF:** everything else.

### Static verification (no game needed)
- AHK: brace balance per file; confirm edit anchors match exactly once.
- UI: extract the inline `<script>` and run `node --check`; keep `<div>` balance unchanged.


### UI conventions
- Collapsible sections: `.cfg-section > <details> > <summary><div class="cfg-header">` with
  `.cfg-subsection` / `.cfg-row` / `.cfg-label` inside.
- Boolean options use the themed pill toggle (`<label class="toggle"> … <span class="toggle-slider">`).
- Sliders: `.cfg-slider-row > .cfg-label + .slider-wrap(.slider-val bubble + input)` with
  `oninput="_sb(this,'<bubble-id>',this.value)"` — the standard slider pattern; reuse it for any new slider.
- Theme text font is `var(--codex-serif)` (labels 13px, `var(--codex-text)`).
- Section open/closed state persists via `_cfgSectionIds` + `syncCfgSections()` → `g_cfgOpenSections`.

## Feature history / changelog
The detailed chronological write-up of every shipped feature, fix, and RE finding
(what changed, why, and the offsets/quirks discovered) lives in **`CHANGELOG.md`** —
split out of this file so it isn't reloaded every turn. **Search `CHANGELOG.md`** for
the background on any existing feature; **append a new dated section there** after
shipping (not here). Only durable cross-cutting conventions live in this file.

## Reference

- Original C# reference project (authority when unclear):
  `https://github.com/Gordin/GameHelper2` (branch `main`).
  Check it when starting a new feature — solutions / approaches may already exist there.
