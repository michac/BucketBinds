# BucketBinds

A World of Warcraft addon (Retail, Midnight / patch 12.0.7) that does two things
the game won't:

1. **One-shot ability dump** — sort every ability into a fixed *bucket* and place
   it into the matching action-bar slot with a consistent keybind, for any spec,
   in one command. Dump once, tweak by hand, done — no background re-syncing.
2. **Transactional save/restore** — snapshot your entire keybind + action-bar +
   macro layout to a named profile and restore it atomically, with a pre-restore
   backup. (WoW has binding sets and Edit Mode layouts, but no snapshot/rollback.)

The bucket taxonomy is seeded from Bellular's "Midnight Keybinding System" and
then owned/curated locally.

## Install (via ghaddons)

```bash
python3 -m ghaddons.cli add     michac/BucketBinds
python3 -m ghaddons.cli install michac/BucketBinds
```

Then `/reload` in-game and run `/bb status`.

## Status

Working. Snapshot/restore (M1, `/bb save|restore|undo`), the spec dumper (M2,
`/bb dump`), spillover/diagnostics (M3), utility macros (M5), and the
schema-driven in-game console (M4a — bare `/bb` opens it) are shipped. `/bb help`
lists every command. See the design doc in the companion `wwt-keyboard`
workspace (`projects/keybinder/project-spec.md`).

## Note

`BucketBinds/Data.lua` is **generated** from a seed in the companion workspace —
don't hand-edit it. See `CLAUDE.md` for the regenerate + release workflow.

## Bundled font

The in-game console (`/bb`) uses **JetBrains Mono** for its terminal look,
bundled at `BucketBinds/Media/JetBrainsMono.ttf`. JetBrains Mono is licensed
under the **SIL Open Font License 1.1**; the full license travels with the font
at `BucketBinds/Media/JetBrainsMono-OFL.txt`.
