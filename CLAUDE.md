# BucketBinds — addon repo (michac/BucketBinds)

This is a **standalone GitHub repo** for the BucketBinds WoW addon, checked out
**inside** the `wwt-keyboard` workspace at `projects/keybinder/addon/` but with
its **own git root** (`michac/BucketBinds`). The parent workspace **gitignores
this folder** (`/projects/keybinder/addon/`) so the workspace never sees it as
an embedded repo — exactly how `planner-state/` (michac/wow-planner-state) is
handled.

Don't confuse this checkout with the **installed** copy under
`…/_retail_/Interface/AddOns/BucketBinds/`. This is the **source of truth**;
the installed copy is what `ghaddons` deploys.

## What the addon does

A one-shot **bucket → action-slot** keybind/bar dumper plus **transactional
save/restore** of your keybind + bar + macro state. Full design, rationale, and
milestones live in the **parent project spec**: `../project-spec.md` (in the
`wwt-keyboard` repo, not this one).

## Relationship to the parent workspace (important)

`Data.lua` is **generated**, not hand-written. Its source is the canonical seed
JSON the parent workspace curates:

```
wwt-keyboard/projects/keybinder/
  data/bellular-keybinds.seed.json   <- CANONICAL seed, hand-edited (lives in wwt-keyboard)
  tool/gen_data_lua.py               <- regenerates BucketBinds/Data.lua HERE
```

To change the ability/keybind data: edit the **seed JSON** in the parent
workspace, run `python3 tool/gen_data_lua.py` (rewrites `BucketBinds/Data.lua`
here; `--check` gates it in CI), then commit + release here (below). **Never
hand-edit `Data.lua`.** (The Bellular `.xlsx` is a frozen archive —
`tool/extract_seed.py` is archival-only and no longer feeds this file.)

## File layout

```
projects/keybinder/addon/         <- THIS repo root (michac/BucketBinds)
  CLAUDE.md                       this file
  README.md
  .gitignore
  BucketBinds/                    <- the addon folder ghaddons installs
    BucketBinds.toc
    Core.lua                      namespace, slash cmds, load
    Data.lua                      GENERATED from the parent seed
    Snapshot.lua                  (M1) save/restore
    Dump.lua                      (M2) seed → bars; (M3) spillover; /bb test
```

## Deploy / release workflow (a plain push does NOT reach the game)

`ghaddons` installs this addon by pulling the **latest GitHub Release** (it
falls back to a default-branch snapshot if no release exists, but we cut
releases so version tracking is clean). So updating the in-game addon is:

1. **Edit** the Lua (or regenerate `Data.lua` from the parent seed).
2. **Bump the version** in `BucketBinds/BucketBinds.toc` (`## Version:`).
   Keep `## Interface:` matching the live patch (12.0.7 → `120007`).
3. **Syntax-check** before committing (no Lua binary here — use luaparser):
   ```bash
   uv run --with luaparser python -c "import luaparser.ast as a,glob; \
     [a.parse(open(f).read()) for f in glob.glob('BucketBinds/*.lua')]; print('lua OK')"
   ```
4. **Commit** in this repo.
5. **Cut a GitHub Release** whose tag matches the `.toc` version:
   ```bash
   git push
   gh release create v0.1.0 --title v0.1.0 --notes "…" --repo michac/BucketBinds
   ```
   (No BigWigs packager here, so ghaddons uses the release's **source zip** —
   which contains `BucketBinds/BucketBinds.toc`, so it installs correctly.)
6. **Deploy**: `cd ../../../addon-manager && python3 -m ghaddons.cli update michac/BucketBinds`
   (first time: `... add michac/BucketBinds` then `... install michac/BucketBinds`).
7. In-game: `/reload` (or restart) to load the new build; `/bb status` to confirm.

## Conventions

- **Interface version** tracks the live patch (workspace source of truth:
  `wwt-keyboard/knowledge/_meta/game-version.md`). 12.0.7 = `120007`.
- **Tag = `.toc` version**, prefixed `v` (e.g. `## Version: 0.1.0` → tag `v0.1.0`).
- SavedVariables: `BucketBindsDB`.

## In-game smoke test (M1 — snapshot/restore)

Run after deploying a build (`ghaddons update michac/BucketBinds` → `/reload`):

1. `/bb save baseline` → `/bb list` shows it with correct binding/action/macro
   counts.
2. Rebind a key **and** drag an action to a new slot → `/bb restore baseline` →
   both revert.
3. `/bb undo` → returns to the modified state (single-level auto-backup).
4. Enter combat (target dummy), `/bb restore baseline` → prints "deferred",
   then applies automatically on leaving combat.
5. **Druid** (or any form class): put a spell on a Cat-form slot while in caster
   form, `/bb save`, change it, `/bb restore` → the Cat bar round-trips
   (validates the 73–120 bonus-bar sweep without shapeshifting).
6. Confirm a macro-on-bar round-trips (name + body + icon intact).

Known M1 limitations: restore of `mount`/`pet`/`flyout`/`equipmentset` action
slots is skip-and-report (spell/item/macro are full-fidelity); the skyriding bar
(~slots 121–132) may only reflect content while active — verify during the pass.

## Dev-side seed validator (`tool/check_seed_spells.py`, in the parent workspace)

Advisory build-time check: cross-references every distinct seed ability name
against a wago `SpellName` DB2 dump and reports names with no 12.0.x match
(typos / Midnight renames). The addon resolves names→IDs at runtime, so this is
never a hard gate — exit 0 even on misses. Run before shipping a data change:

```bash
cd tools && uv run python -m wowkb.wago SpellName          # → raw/wago/SpellName.csv
cd ../projects/keybinder && uv run python tool/check_seed_spells.py
```

Fix real typos via `Dump.lua`'s `ALIASES` table (non-destructive — `Data.lua` is
generated and the source `.xlsx` is off-box). Known benign misses that stay
`unresolved`/`skipped` in-game (no single spell behind them): `Res` (Priest/Monk
Buff slot), `Poisons` (Rogue), `Protection Stance` (Warrior Stance — an M5 bucket).

## In-game smoke test (M2 — dump)

Run after deploying a build (`ghaddons update michac/BucketBinds` → `/reload`):

1. **Non-form spec** (e.g. Mage/Warlock): `/bb dump` → all 5 bars fill; keys
   `1 / Q / Shift-1 / Ctrl-Q / …` fire the right abilities; report shows
   `N/M abilities placed, K bound` (M = the spec's mapped abilities, not a fixed
   40 — specs map a subset). MultiBars are visible afterward (bar-toggle worked).
2. **Unresolved path**: a spec with an untalented bucket → that name is listed
   under `unresolved:` and reported, **not** errored; nothing wrong is placed.
3. **`/bb undo`** → reverts the dump to the pre-dump layout (M1 auto-backup reuse).
4. **Combat defer**: `/bb dump` on a target dummy → prints "deferred", then
   applies automatically on leaving combat.
5. **Druid** (the form test): `/bb dump` in caster form, then shift to Cat and
   Bear → the bar-1 abilities appear on both form bars and `1–8` fire them.
   Confirm the `FORM_BONUS_BARS` offsets (adjust the table if a form's slots are
   empty) and that the `UPDATE_SHAPESHIFT_FORM` safety hook fills any missed form
   on first entry. Also spot-check Rogue (Stealth) / Warrior (stances) — uncertain
   whether they page in 12.0.x; the hook is the backstop.
6. **Override**: `/bb dump Fire` (current class) and `/bb dump Mage Fire` both
   resolve; an unknown arg prints the available spec keys.
7. **`--nobind`**: change one keybind by hand, then `/bb dump --nobind` → the
   abilities re-place on the bars but your changed bind is **untouched** and the
   report says "bindings left unchanged (--nobind)".

## In-game smoke test (M3 — spill) + /bb test

1. **Verify the reserve region first** (the one hardcoded guess): 
   `/run for i=133,180 do local t,id=GetActionInfo(i); if t then print(i,t,id) end end`
   — confirm slots **145–168** are Action Bars 6–7 (empty by default). If the
   range is off on this patch, fix `SPILL_BASE`/`SPILL_COUNT` in `Dump.lua`.
2. `/bb dump` then `/bb spill` → learned-but-unplaced abilities land on bars 6–7;
   the report lists each `name (spellID)`. No keybinds are set. Confirm nothing
   the dump already placed shows up in spill (override-normalization works).
3. **Idempotent re-run**: park a spell manually on a bar-6 slot, `/bb spill`
   again → your parked spell is **not** wiped; only the addon's own prior spill
   slots are cleared/refilled.
4. **`/bb spill clear`** → the addon's spilled abilities are removed; your parked
   spell stays.
5. **`/bb test`** → Recuperate (or a fallback known spell) lands on the freed
   Left bar and `ALT-0` fires it; report shows `place … OK; bind … OK`.
   `/bb test clear` reverts both. This is the minimal write-path probe when a
   dump misbehaves on a new character/patch.
