# Contributing to adamant-Core

Coordinator that discovers installed adamant modules, provides a unified UI, and manages config hashing and profiles. Depends on adamant-Lib.

## Architecture

```
src/
  main.lua               -- entry point, lifecycle, imports
  def.lua                -- shared constants (NUM_PROFILES, defaultProfiles)
  discovery.lua          -- auto-discovers opted-in modules, state accessors
  hash.lua               -- pure config hash encoding/decoding (no engine deps)
  hud.lua                -- HUD mod marker display (reads Core.Hash)
  ui_theme.lua           -- colors, layout constants, theme push/pop
  ui.lua                 -- staging, tabs, window rendering, toggle handlers
  config.lua             -- Chalk config schema (ModEnabled, DebugMode, Profiles)
```

Files are imported sequentially in main.lua and share state via the `Core` namespace. Each file attaches its exports (e.g., `Core.Discovery`, `Core.Theme`, `Core.Def`).

## Key systems

### Discovery (discovery.lua)

Auto-discovers all installed modules that opt in via `definition.modpackModule = true`. No registry required — modules are picked up automatically on load.

- Regular modules: `def.special` is nil/false
- Special modules: `def.special = true`
- All metadata (id, name, category, group, tooltip, default) lives in each module's `public.definition`
- Modules are sorted alphabetically by display name; categories and groups are also sorted alphabetically

A new category tab is created automatically the first time a module with an unseen `def.category` is discovered. No Core changes needed to add a new module or category.

### Config hash (hash.lua)

Pure encoding logic with no engine dependencies — fully testable in standalone Lua. Uses a **key-value canonical string** format:

```
ModId=1|ModId.configKey=value|adamant-SpecialName.configKey=value
```

- Only non-default values are encoded — adding new fields with defaults is non-breaking
- Keys are sorted alphabetically for stable output
- Value encoding is delegated to `lib.FieldTypes[field.type].toHash/fromHash`
- An empty string means all values are at their defaults

`GetConfigHash(source)` returns `canonical, fingerprint` — the canonical string is used for import/export, the 12-char base62 fingerprint is shown on the HUD. `ApplyConfigHash(hash)` decodes and applies a canonical string; unknown keys are ignored and missing keys reset to defaults.

`hud.lua` handles only the HUD marker display — it reads `Core.Hash` but contains no encoding logic.

### UI (ui.lua)

Uses a **staging table** -- a plain Lua cache mirroring Chalk configs for fast per-frame reads. Chalk is only written when the user makes a change.

Key handlers:

| Function | Purpose |
|---|---|
| `ToggleModule(module, val)` | Enable/disable a boolean module |
| `ChangeOption(module, key, val)` | Change an inline option (triggers revert + apply) |
| `ToggleSpecial(special, val)` | Enable/disable a special module |
| `SetModuleState(module, state)` | Game-side only apply/revert (no Chalk, no staging) |
| `LoadProfile(hash)` | Apply a hash string to all modules |
| `SetBugFixes(val)` | Bulk toggle all bug fix modules |

### Theme (ui_theme.lua)

Declarative colors and layout constants. Colors are defined as a data-driven table so push/pop stay in sync automatically.

### Definitions (def.lua)

Shared constants: `Core.Def.NUM_PROFILES` and `Core.Def.defaultProfiles`.

## How-tos

### Adding a new profile preset

Add to `Core.Def.defaultProfiles` in def.lua. Get the hash from the Profiles tab export field in-game.

### Adding a new category

Set `def.category` to a new string in the module's `public.definition`. The tab appears automatically — no registry change needed.

## Guidelines

- **Never rename `def.id` or `field.configKey` after release** — these are hash keys; renaming silently resets that field to default for anyone with an existing profile
- All module apply/revert calls go through pcall — log via `lib.warn`, never crash
- UI reads from staging, not Chalk — always keep staging in sync
- Theme is data-driven — don't hardcode counts or layout numbers
