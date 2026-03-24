-- =============================================================================
-- Test utilities: mock engine globals so Core's hud.lua can load in plain Lua
-- =============================================================================

-- Mock public/ENVY
public = {}
_PLUGIN = { guid = "test-core" }

-- Deep copy
local function deepCopy(orig)
    if type(orig) ~= "table" then return orig end
    local copy = {}
    for k, v in pairs(orig) do
        copy[k] = deepCopy(v)
    end
    return copy
end

-- Mock rom
rom = {
    mods = {},
    game = {
        DeepCopyTable = deepCopy,
        SetupRunData = function() end,
    },
    ImGui = {},
    gui = {
        add_to_menu_bar = function() end,
        add_imgui = function() end,
    },
}

rom.mods['SGG_Modding-ENVY'] = {
    auto = function() return {} end,
}

-- Warning capture
Warnings = {}

function CaptureWarnings()
    Warnings = {}
    rom.mods['adamant-Modpack_Core'] = {
        config = { ModEnabled = true, DebugMode = true },
    }
    _originalPrint = print
    print = function(msg)
        table.insert(Warnings, msg)
    end
end

function RestoreWarnings()
    print = _originalPrint or print
    Warnings = {}
end

-- Load Lib first (Core depends on it)
dofile("../adamant-modpack-Lib/src/main.lua")
lib = public

-- Set up lib as a rom mod so Core's hud.lua can find it
rom.mods['adamant-Modpack_Lib'] = lib

-- Core namespace
Core = {}
config = { ModEnabled = true, DebugMode = false }

-- =============================================================================
-- Mock Discovery: simulates discovered modules for hash testing
-- =============================================================================

MockDiscovery = {}

function MockDiscovery.create(moduleConfigs, optionConfigs, specialConfigs)
    -- moduleConfigs: ordered list of { id, category, enabled, options? }
    -- optionConfigs: { [id] = { [configKey] = value } }
    -- specialConfigs: { { modName, config, stateSchema } }

    moduleConfigs = moduleConfigs or {}
    optionConfigs = optionConfigs or {}
    specialConfigs = specialConfigs or {}

    local discovery = {
        modules = {},
        modulesById = {},
        modulesWithOptions = {},
        specials = {},
        categories = {},
        byCategory = {},
    }

    local categorySet = {}

    for _, mc in ipairs(moduleConfigs) do
        local mod = {
            modName = "adamant-" .. mc.id,
            mod = { config = { Enabled = mc.enabled } },
            definition = {
                apply = function() end,
                revert = function() end,
            },
            id = mc.id,
            name = mc.id,
            category = mc.category or "General",
            options = mc.options,
            default = mc.default ~= nil and mc.default or false,
        }

        table.insert(discovery.modules, mod)
        discovery.modulesById[mc.id] = mod

        if mc.options and #mc.options > 0 then
            table.insert(discovery.modulesWithOptions, mod)
        end

        local cat = mc.category or "General"
        if not categorySet[cat] then
            categorySet[cat] = true
            table.insert(discovery.categories, { key = cat, label = cat })
        end
        discovery.byCategory[cat] = discovery.byCategory[cat] or {}
        table.insert(discovery.byCategory[cat], mod)
    end

    for _, sc in ipairs(specialConfigs) do
        table.insert(discovery.specials, {
            modName = sc.modName,
            mod = { config = sc.config, SnapshotStaging = function() end },
            definition = {},
            stateSchema = sc.stateSchema,
        })
    end

    -- State accessors
    function discovery.isModuleEnabled(m)
        return m.mod.config.Enabled == true
    end

    function discovery.setModuleEnabled(m, enabled)
        m.mod.config.Enabled = enabled
    end

    function discovery.getOptionValue(m, configKey)
        return m.mod.config[configKey]
    end

    function discovery.setOptionValue(m, configKey, value)
        m.mod.config[configKey] = value
    end

    return discovery
end
