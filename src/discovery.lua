-- =============================================================================
-- MODULE DISCOVERY
-- =============================================================================
-- Auto-discovers all installed modules that opt in via definition.modpackModule = true,.
-- Regular modules: definition.special is nil/false.
-- Special modules: definition.special = true.
-- Modules are sorted alphabetically by display name within each category.

local Discovery = {}
local lib = rom.mods['adamant-Modpack_Lib']

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

    -- Collect all opted-in modules
    local found = {}
    for modName, mod in pairs(mods) do
        if type(mod) == "table" and mod.definition and mod.definition.modpackModule then
            table.insert(found, { modName = modName, mod = mod, def = mod.definition })
        end
    end

    -- Sort alphabetically by display name for stable UI ordering
    table.sort(found, function(a, b)
        return (a.def.name or a.def.id or a.modName) < (b.def.name or b.def.id or b.modName)
    end)

    local categorySet = {}

    for _, entry in ipairs(found) do
        local modName = entry.modName
        local mod     = entry.mod
        local def     = entry.def

        if def.special then
            if not def.name or not def.apply or not def.revert then
                lib.warn("Skipping special " .. modName .. ": missing name, apply, or revert")
            else
                if def.stateSchema then
                    lib.validateSchema(def.stateSchema, modName)
                end
                table.insert(Discovery.specials, {
                    modName     = modName,
                    mod         = mod,
                    definition  = def,
                    stateSchema = def.stateSchema,
                })
            end
        else
            if not def.id or not def.apply or not def.revert then
                lib.warn("Skipping " .. modName .. ": missing id, apply, or revert")
            else
                local cat = def.category or "General"
                local module = {
                    modName    = modName,
                    mod        = mod,
                    definition = def,
                    id         = def.id,
                    name       = def.name,
                    category   = cat,
                    group      = def.group or "General",
                    tooltip    = def.tooltip or "",
                    default    = def.default,
                    options    = def.options,
                }

                table.insert(Discovery.modules, module)
                Discovery.modulesById[def.id] = module
                if def.options and #def.options > 0 then
                    table.insert(Discovery.modulesWithOptions, module)
                    lib.validateSchema(def.options, modName)
                end

                if not categorySet[cat] then
                    categorySet[cat] = true
                    table.insert(Discovery.categories, { key = cat, label = cat })
                end

                Discovery.byCategory[cat] = Discovery.byCategory[cat] or {}
                table.insert(Discovery.byCategory[cat], module)
            end
        end
    end

    -- Sort categories alphabetically for consistent sidebar ordering
    table.sort(Discovery.categories, function(a, b) return a.label < b.label end)

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

    table.sort(groupOrder)

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
