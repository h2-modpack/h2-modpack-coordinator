-- =============================================================================
-- MODULE DISCOVERY
-- =============================================================================
-- Discovers installed adamant-* standalone modules by checking rom.mods.
-- Order is fixed for hash compatibility — matches the original modules/init.lua.
-- DO NOT reorder entries — it will break existing config hashes / profiles.
--
-- Each entry: { modName = "adamant-XXX", category = "...", categoryLabel = "..." }
-- The module's public.definition provides id, name, group, tooltip, default, etc.

local Discovery = {}
local lib = rom.mods['adamant-Modpack_Lib']

-- -------------------------------------------------------------------------
-- CANONICAL ORDER (hash-stable — append only, never reorder)
-- -------------------------------------------------------------------------

local MODULE_ORDER = {
    -- Run Modifiers
    { modName = "adamant-ForceMedea",              category = "RunModifiers",  categoryLabel = "Run Modifiers" },
    { modName = "adamant-ForceArachne",            category = "RunModifiers" },
    { modName = "adamant-DisableArachnePity",      category = "RunModifiers" },
    { modName = "adamant-PreventEchoScam",         category = "RunModifiers" },
    { modName = "adamant-DisableSeleneBeforeBoon",  category = "RunModifiers" },
    { modName = "adamant-RTAMode",                 category = "RunModifiers" },
    { modName = "adamant-SkipGemBossReward",       category = "RunModifiers" },
    { modName = "adamant-EscalatingFigLeaf",       category = "RunModifiers" },
    { modName = "adamant-SurfaceStructure",        category = "RunModifiers" },
    { modName = "adamant-CharybdisBehavior",       category = "RunModifiers" },

    -- QoL
    { modName = "adamant-ShowLocation",            category = "QoLSettings",   categoryLabel = "QoL" },
    { modName = "adamant-SkipDialogue",            category = "QoLSettings" },
    { modName = "adamant-SkipRunEndCutscene",      category = "QoLSettings" },
    { modName = "adamant-SkipDeathCutscene",       category = "QoLSettings" },
    { modName = "adamant-SpawnLocation",           category = "QoLSettings" },
    { modName = "adamant-KBMEscape",              category = "QoLSettings" },
    { modName = "adamant-VictoryScreen",           category = "QoLSettings" },
    { modName = "adamant-SpeedrunTimer",           category = "QoLSettings" },

    -- Bug Fixes
    { modName = "adamant-CorrosionFix",            category = "BugFixes",      categoryLabel = "Bug Fixes" },
    { modName = "adamant-GGGFix",                  category = "BugFixes" },
    { modName = "adamant-BraidFix",                category = "BugFixes" },
    { modName = "adamant-MiniBossEncounterFix",    category = "BugFixes" },
    { modName = "adamant-ExtraDoseFix",            category = "BugFixes" },
    { modName = "adamant-PoseidonWavesFix",        category = "BugFixes" },
    { modName = "adamant-TidalRingFix",            category = "BugFixes" },
    { modName = "adamant-ShimmeringFix",           category = "BugFixes" },
    { modName = "adamant-StagedOmegaFix",          category = "BugFixes" },
    { modName = "adamant-OmegaCastFix",            category = "BugFixes" },
    { modName = "adamant-CardioTorchFix",          category = "BugFixes" },
    { modName = "adamant-FamiliarDelayFix",        category = "BugFixes" },
    { modName = "adamant-SufferingFix",            category = "BugFixes" },
    { modName = "adamant-SeleneFix",               category = "BugFixes" },
    { modName = "adamant-ETFix",                   category = "BugFixes" },
    { modName = "adamant-SecondStageChanneling",   category = "BugFixes" },
}

-- Special modules (not in boolean hash, handled separately)
-- Each must expose definition.tabLabel for the sidebar.
-- Append only, never reorder — hash payload order depends on this.
local SPECIAL_MODULES = {
    { modName = "adamant-FirstHammer" },
}

-- -------------------------------------------------------------------------
-- DISCOVERY STATE
-- -------------------------------------------------------------------------

-- Populated by Discovery.run()
Discovery.modules = {}          -- ordered list of discovered boolean modules
Discovery.modulesById = {}      -- id -> module entry
Discovery.modulesWithOptions = {} -- ordered list of modules that have definition.options
Discovery.specials = {}         -- ordered list of discovered special modules

Discovery.categories = {}       -- ordered list of { key, label }
Discovery.byCategory = {}       -- category key -> ordered list of modules
Discovery.categoryLayouts = {}  -- category key -> UI layout (groups)

-- -------------------------------------------------------------------------
-- DISCOVERY
-- -------------------------------------------------------------------------

function Discovery.run()
    local mods = rom.mods

    -- Track category discovery order
    local categorySet = {}
    local categoryLabels = {}

    for _, entry in ipairs(MODULE_ORDER) do
        local mod = mods[entry.modName]
        if mod and mod.definition then
            local def = mod.definition
            if not def.id or not def.apply or not def.revert then
                lib.warn("Skipping " .. entry.modName .. ": missing id, apply, or revert")
            else
                local module = {
                    modName    = entry.modName,
                    mod        = mod,
                    definition = def,
                    id         = def.id,
                    name       = def.name,
                    category   = entry.category,
                    group      = def.group or "General",
                    tooltip    = def.tooltip or "",
                    default    = def.default,
                    options    = def.options,  -- nil if no inline options
                }

                table.insert(Discovery.modules, module)
                Discovery.modulesById[def.id] = module
                if def.options and #def.options > 0 then
                    table.insert(Discovery.modulesWithOptions, module)
                    lib.validateSchema(def.options, entry.modName)
                end

                -- Category tracking
                local cat = entry.category
                if not categorySet[cat] then
                    categorySet[cat] = true
                    table.insert(Discovery.categories, {
                        key = cat,
                        label = entry.categoryLabel or categoryLabels[cat] or cat,
                    })
                end
                if entry.categoryLabel then
                    categoryLabels[cat] = entry.categoryLabel
                end

                Discovery.byCategory[cat] = Discovery.byCategory[cat] or {}
                table.insert(Discovery.byCategory[cat], module)
            end
        end
    end

    -- Discover special modules (ordered)
    for _, entry in ipairs(SPECIAL_MODULES) do
        local mod = mods[entry.modName]
        if mod and mod.definition then
            local def = mod.definition
            if not def.name or not def.apply or not def.revert then
                lib.warn("Skipping special " .. entry.modName .. ": missing name, apply, or revert")
            else
                if def.stateSchema then
                    lib.validateSchema(def.stateSchema, entry.modName)
                end
                table.insert(Discovery.specials, {
                    modName     = entry.modName,
                    mod         = mod,
                    definition  = def,
                    stateSchema = def.stateSchema,  -- nil if module has no declarative state
                })
            end
        end
    end

    -- Build UI layouts
    for _, cat in ipairs(Discovery.categories) do
        Discovery.categoryLayouts[cat.key] = Discovery.buildLayout(cat.key)
    end
end

-- -------------------------------------------------------------------------
-- LAYOUT BUILDER
-- -------------------------------------------------------------------------

function Discovery.buildLayout(category)
    local mods = Discovery.byCategory[category] or {}
    local groupOrder = {}
    local groups = {}

    for _, m in ipairs(mods) do
        local g = m.group
        if not groups[g] then
            groups[g] = { Header = g, Items = {} }
            table.insert(groupOrder, g)
        end
        table.insert(groups[g].Items, {
            Key       = m.id,
            ModName   = m.modName,
            Name      = m.name,
            Tooltip   = m.tooltip,
        })
    end

    local layout = {}
    for _, g in ipairs(groupOrder) do
        table.insert(layout, groups[g])
    end
    return layout
end

-- -------------------------------------------------------------------------
-- MODULE STATE ACCESS
-- -------------------------------------------------------------------------

--- Read a module's current Enabled state from its own config.
function Discovery.isModuleEnabled(module)
    return module.mod.config.Enabled == true
end

--- Write a module's Enabled state and call enable/disable.
function Discovery.setModuleEnabled(module, enabled)
    module.mod.config.Enabled = enabled
    local fn = enabled and module.definition.apply or module.definition.revert
    local ok, err = pcall(fn)
    if not ok then
        lib.warn(module.modName .. " " .. (enabled and "enable" or "disable") .. " failed: " .. tostring(err))
    end
end

--- Read a module option's current value from its config.
function Discovery.getOptionValue(module, configKey)
    return module.mod.config[configKey]
end

--- Write a module option's value to its config.
function Discovery.setOptionValue(module, configKey, value)
    module.mod.config[configKey] = value
end

--- Read a special module's Enabled state from its config.
function Discovery.isSpecialEnabled(special)
    return special.mod.config.Enabled == true
end

--- Write a special module's Enabled state and call enable/disable.
function Discovery.setSpecialEnabled(special, enabled)
    special.mod.config.Enabled = enabled
    local fn = enabled and special.definition.apply or special.definition.revert
    local ok, err = pcall(fn)
    if not ok then
        lib.warn(special.modName .. " " .. (enabled and "enable" or "disable") .. " failed: " .. tostring(err))
    end
end

Core.Discovery = Discovery
Discovery.run()
