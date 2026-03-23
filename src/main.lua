-- =============================================================================
-- ADAMANT-CORE: Modular Coordinator
-- =============================================================================
-- Discovers installed adamant-* standalone modules and provides:
--   - Unified ImGui UI (categories, groups, profiles, hammers)
--   - Config hashing and HUD mod mark
--   - Profile save/load/import/export
--
-- Each standalone module manages its own hooks, backup/restore, and config.
-- The coordinator orchestrates enable/disable and renders the unified UI.

local mods = rom.mods
mods['SGG_Modding-ENVY'].auto()

---@diagnostic disable: lowercase-global
rom = rom
_PLUGIN = _PLUGIN
game = rom.game
modutil = mods['SGG_Modding-ModUtil']
chalk = mods['SGG_Modding-Chalk']
reload = mods['SGG_Modding-ReLoad']

config = chalk.auto('config.lua')
public.config = config

-- Shared namespace for cross-file communication within this plugin.
-- All imported files attach to Core and read from Core.Discovery.
Core = {}
-- local lib = rom.mods['adamant-Modpack_Lib']

-- =============================================================================
-- LIFECYCLE
-- =============================================================================

local function on_ready()

    import_as_fallback(rom.game)

    -- 0. Fixed definitions (constants, default profiles)
    import 'def.lua'

    -- 1. Import and run discovery (discovery.lua self-runs on import)
    import 'discovery_registry.lua'
    import 'discovery.lua'

    -- 2. Config hash (pure logic, no engine deps beyond Discovery)
    import 'hash.lua'

    
    -- 3. UI theme (colors, layout constants, helpers)
    import 'ui_theme.lua'

    -- 4. HUD system (mod mark display)
    import 'hud.lua'


    -- 5. UI system
    import 'ui.lua'

    -- 6. Set initial mod marker
    if config.ModEnabled then
        Core.SetModMarker(true)
    end
end

local function on_reload()
    import_as_fallback(rom.game)
    import 'def.lua'
    import 'discovery_registry.lua'
    import 'discovery.lua'
    import 'hash.lua'
    import 'ui_theme.lua'
    import 'hud.lua'
    import 'ui.lua'
end

local loader = reload.auto_single()

modutil.once_loaded.game(function()
    loader.load(on_ready, on_reload)
end)
