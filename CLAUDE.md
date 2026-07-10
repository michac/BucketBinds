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

`Data.lua` is **generated**, not hand-written. Its source is the seed the parent
workspace curates:

```
wwt-keyboard/projects/keybinder/
  data/bellular-keybinds.seed.json   <- canonical seed (lives in wwt-keyboard)
  tool/extract_seed.py               <- regenerates BucketBinds/Data.lua HERE
```

To change the ability/keybind data: edit the seed in the parent workspace, run
`uv run --with openpyxl python tool/extract_seed.py`, and it rewrites
`BucketBinds/Data.lua` in this repo. Then commit + release here (below).
**Never hand-edit `Data.lua`.**

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
    Snapshot.lua                  (M1) save/restore   — not yet
    Dump.lua                      (M2) seed → bars     — not yet
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
