# Contributing to adamant-Core

Coordinator that discovers installed adamant modules, provides a unified UI, and manages config hashing and profiles. Depends on adamant-Lib.

## Architecture

```
src/
  main.lua               -- entry point, lifecycle, imports
  def.lua                -- shared constants (NUM_PROFILES, defaultProfiles)
  discovery_registry.lua -- MODULE_ORDER and SPECIAL_MODULES canonical lists
  discovery.lua          -- module discovery, ordering, state accessors
  hash.lua               -- pure config hash encoding/decoding (no engine deps)
  hud.lua                -- HUD mod marker display (reads Core.Hash)
  ui_theme.lua           -- colors, layout constants, theme push/pop
  ui.lua                 -- staging, tabs, window rendering, toggle handlers
  config.lua             -- Chalk config schema (ModEnabled, DebugMode, Profiles)
```

Files are imported sequentially in main.lua and share state via the `Core` namespace. Each file attaches its exports (e.g., `Core.Discovery`, `Core.Theme`, `Core.Def`).

## Key systems

### Discovery (discovery.lua)

Scans `rom.mods` for installed adamant modules using a canonical order list.

**MODULE_ORDER is append-only** -- never reorder or remove entries. Existing config hashes and profiles depend on positional encoding.

To register a new module:
1. Append to `MODULE_ORDER` (or `SPECIAL_MODULES` for special modules)
2. Set `category` and optionally `categoryLabel` (only needed on the first entry of a new category)

The UI automatically creates tabs for new categories.

### Config hash (hash.lua)

Pure encoding logic with no engine dependencies — fully testable in standalone Lua. Encodes all module states into a compact base62 string:

```
<bool_hash>.<special_hash>
```

- **Bool hash**: one bit per boolean module (in MODULE_ORDER order), plus bits for inline options
- **Special hash**: each special module's stateSchema fields encoded sequentially
- **Chunk size**: 30 bits per chunk (`CHUNK_BITS = 30`), chunks separated by `.`

`Core.Hash.GetConfigHash(source)` accepts an optional staging table for computing hashes without flushing to Chalk. `Core.Hash.ApplyConfigHash(hash)` decodes and applies a hash to all modules.

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

Append entries to `MODULE_ORDER` in discovery.lua with a new category key and `categoryLabel` on the first entry.

## Guidelines

- **MODULE_ORDER is append-only** -- this is the most critical invariant
- All module apply/revert calls go through pcall -- log via `lib.warn`, never crash
- UI reads from staging, not Chalk -- always keep staging in sync
- Theme is data-driven -- don't hardcode counts or layout numbers
