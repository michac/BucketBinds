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

## In-game smoke test (M3.1 — /bb diagnostics)

`/bb diagnostics` is a **read-only** report (no `PlaceAction`/`SetBinding` — safe
in combat) that classifies every seed bucket for the **active spec**, reads the
bars back, and lists castable abilities no bucket covers. It writes into
`BucketBindsDB.diagnostics[<char>][<spec>]` — **account-level** SavedVariables, so
runs **accumulate** across specs and characters (merge, never wipe). It flushes
to disk only on `/reload`/logout; the `wowkb.diagnostics` Python reader parses it
off the WSL mount.

1. `/bb dump` then `/bb diagnostics` → chat prints a headline count line for the
   `char / spec` slot just written; any `unresolved` names list in WARN (seed
   bugs) and any `placementIssues` list as `category (issue)`. Footer names how
   many `<char>/<spec>` reports are stored.
2. **Accumulation pass**: for a character with 3 specs — switch spec, `/bb dump`,
   `/bb diagnostics` (×3) — then `/reload`. Hop to a second character and repeat.
   A char switch logs out (auto-flush); the single `/reload` per character is the
   flush the reader needs.
3. `/reload`, then from `tools/`: `uv run python -m wowkb.diagnostics` →
   **all** stored `<char>/<spec>` reports render with counts + the
   bugs/skips/gaps/mismatch sections. `--character <name>` / `--spec <name>`
   filter to one; `--json` dumps the raw tree.
4. **Merge, don't wipe**: re-run `/bb diagnostics` on ONE spec → `/reload` → the
   reader shows that slot's `reviewed` time refreshed while the others are
   retained. `/bb diagnostics clear` empties the whole store.
5. **No-seed spec**: a spec with no seed key still records `castableTotal` +
   `unmapped` (all castable) + empty buckets with a "no seed for …" note.

## In-game smoke test (M5 — macros, Phase A)

Run after deploying a build (`ghaddons update michac/BucketBinds` → `/reload`).
Phase A ships two macros: `BBfocus` (account) → key `5`, and `BBintr` (per-char,
per-spec) → key `V` (replaces the raw interrupt on bar 1 / slot 12).

1. **Spec with an interrupt** (e.g. Frost Mage): `/bb dump` → report shows
   `macros: N created / M updated`; key `5` casts `/focus`; key `V` shows the
   interrupt-spell icon (via `#showtooltip`) and is a **macro**. In the macro UI
   confirm `BBintr` is a **character** macro and `BBfocus` an **account** macro.
2. **Focus redirect**: `/focus` an enemy, target something else, press `V` →
   interrupts the **focus**; clear focus, press `V` → interrupts current target.
   **Warlock** (`Command Demon`): verify the `@focus` redirect fires the active
   demon's interrupt (Felhunter Spell Lock / Felguard Axe Toss) — `@verify-ingame`.
3. **Healer, no interrupt** (Holy Paladin / Preservation Evoker / Resto Druid /
   Disc Priest): dump reports "no interrupt for this spec — slot V left as
   placed"; `BBintr` not created. Holy Priest → `BBintr` built from
   `Holy Word: Chastise`.
4. **Idempotent**: `/bb dump` twice → macros **edited, not duplicated**; the
   count doesn't grow.
5. **Cross-class isolation**: dump a Warrior then a Mage on the same account →
   each character's `BBintr` casts its own interrupt (validates per-char scope).
6. **Form class (Druid)** — the **Hazard-1 regression check, do not skip**:
   `/bb dump` in caster, shift to Cat/Bear → `V` still fires the interrupt
   **macro** on the form bar (validates the form-mirror + that `bar1[12]=nil`
   stops `onShapeshift` re-placing the raw spell).
7. **Revert**: `/bb undo` reverts dump + macros (single backup).
   `/bb macros clear` → `BBfocus`/`BBintr` deleted, key `5` unbound, slot 37
   cleared (slot `V`/12 left empty — a later `/bb dump` refills it).
8. **Combat defer**: `/bb macros` on a target dummy → prints "deferred", applies
   on leaving combat.
9. **Standalone**: `/bb macros Fire` and `/bb macros` (auto-detect) resolve +
   place the two macros without a full dump.

> **ExtraActionButton note**: `/bb dump` now binds key `5` to the focus macro,
> overriding a manual `ExtraActionButton` bind (seed `bonus_binds`, applied by
> hand — the addon never wrote key 5). Rebind EAB to another key in-game. Keys
> `5`–`9` are the intended **utility/prep band** (free bar 5, buttons 1–5).

## In-game smoke test (M5 — Phase B: items + prep)

Run after deploying a build (`ghaddons update michac/BucketBinds` → `/reload`).
Phase B adds fall-through item macros + a prep band on top of Phase A. It also
regenerates `Data.lua` — `python3 tool/gen_data_lua.py --check` must pass.

1. **Item macros**: `/bb dump` on a DPS caster → `BBhp`/`BBmana`/`BBdmg` land on
   bar-4 slots 1–3, fired by `Alt+Q/E/R`; each shows a potion tooltip and
   `/use`s whatever potion you carry (fall-through). `BBtrinket` on slot 5, key
   `6`, fires `/use 13`+`/use 14`.
2. **Racial**: key `7` casts your race's racial (`BBracial`, a **character**
   macro). On an **unmapped** race → reported skipped, `BBracial` not created.
   The whole `RACIALS` table is `@verify-ingame` (esp. Earthen/Dracthyr/allied).
3. **Prep band**: key `8` = `BBflask` (fall-through all 4 flasks); key `9` =
   `BBbuff` casts the spec's buff(s) — Mage→Arcane Intellect, Warrior→Battle
   Shout, Enh Shaman→weapon buffs, Rogue→Instant Poison (`@verify-ingame`). A
   class with no buff row (DK/DH/Hunter/Warlock) → `BBbuff` skipped, reported.
4. **`skipped (M5)` shrinks**: the dump report no longer lists Healthstone/Mana/
   Damage/Trinket/Racial; still lists `Another Combat Item If Needed`, `Mount`,
   `Free`, Stance.
5. **Idempotent**: `/bb dump` twice → macros edited not duplicated; key `6–9`
   binds stable, macro count doesn't grow.
6. **Cross-char isolation**: dump a Rogue then a Mage → each `BBracial`/`BBbuff`
   is its own (per-char scope); consumable/trinket/flask macros are account scope.
7. **Standalone**: `/bb macros` with no prior dump → item + prep macros placed
   **and** `Alt+Q/E/R` + `6–9` bound (self-sufficient).
8. **Revert**: `/bb undo` reverts dump + all macros (single backup).
   `/bb macros clear` → all `BB*` macros deleted, keys `5/6/7/8/9` unbound, their
   slots cleared (Alt item keys `Q/E/R/F` left to the dump layout).
9. **Combat defer**: `/bb macros` on a dummy → "deferred", applies on leaving
   combat.
10. **Macro cap sanity**: macro UI → ~7 account + ~3 char `BB*` macros, well
    under 120/18; no `(out of slots!)` warning.
11. **255-char cap** (`@verify-ingame`): open `BBhp` (the longest group +
    Healthstone prefix) → confirm no trailing `/use` line was silently dropped
    and no cap warning printed.

## In-game smoke test (M4a — schema-driven console)

Run after deploying a build (`ghaddons update michac/BucketBinds` → `/reload`).
M4a adds `Output.lua` (the `ns.Emit` sink) + `Console.lua` (the window) and
rewires Core around the `ns.Commands` schema. Bundled font: **JetBrains Mono**
(OFL-1.1, `BucketBinds/Media/JetBrainsMono.ttf`). No seed change —
`python3 tool/gen_data_lua.py --check` still passes.

1. **Toggle**: bare `/bb` **and** `/bb console` both open the window; running
   either again closes it. The `[X]` button and `Esc` (from the input) also
   close/blur. It's movable (drag anywhere on the frame) and resizable (bottom-
   right grip); move + resize it, `/reload`, reopen → position/size persist
   (`BucketBindsDB.console`).
2. **Scrollback capture**: run `/bb status`, `/bb list`, `/bb help` **inside**
   the console → output lands in the scrollback **and** still echoes to chat
   (default `ns.Console.echoChat`). `/bb help` text is schema-generated from
   `ns.Commands` — it lists **every** command with `args — desc`. Mouse-wheel
   scrolls; Shift+wheel jumps to top/bottom.
3. **Tab-complete**: `du`+Tab → `dump`; `dump `+Tab → inserts a spec key,
   repeated Tab **cycles** the spec keys; `restore `+Tab → a profile name (after
   at least one `/bb save`); `spill `/`ring `/`test `/`diagnostics `+Tab →
   `clear`; `macros `+Tab → cycles spec keys **and** `clear`.
4. **Live hint + dropdown + tooltip**: as you type the command token, the hint
   line under the input shows `args — desc` for an exact match; the autocomplete
   dropdown lists every prefix match with its one-liner; hovering a dropdown row
   shows a `GameTooltip` (name + args + desc); clicking a row fills the input.
5. **"Did you mean?"**: `/bb dmp` (typo) → `unknown command 'dmp'. Did you mean
   /bb dump?` — from **both** the console input and the plain chat `/bb dmp` (the
   suggestion lives in `ns.Dispatch`/`ns.SuggestCommand`, shared by both). While
   typing `dmp` in the console the hint line previews the same guess.
   `/bb dignostics` → suggests `diagnostics`.
6. **History**: type a few commands, then ↑/↓ in the input recalls them
   (`SetHistoryLines(64)`).
7. **Echo coloring**: the command you run is echoed to scrollback with a `>`
   prompt and the command token colorized (per-token in-input coloring is
   deliberately skipped; the echo is the free substitute).
8. **No-regression** (the important one): `/bb dump` from the console still runs
   the **real** dumper — on a target dummy it hits the existing combat guard
   ("deferred", applies on leaving combat); off a dummy it places + binds
   normally. `/bb undo` reverts. Nothing about placement/binding changed — the
   console is pure UI over the same `ns.Dispatch`.
9. **Font fallback**: if the `.ttf` ever fails to load, the frame still renders
   (SetFont falls back to a stock font object) — text is just not monospace.
