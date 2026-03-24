local ui = rom.ImGui
local lib = rom.mods['adamant-Modpack_Lib']

local Discovery = Core.Discovery
local T = Core.Theme
local Def = Core.Def

-- Unpack theme for convenient access
local colors            = T.colors
local ImGuiTreeNodeFlags = T.ImGuiTreeNodeFlags
local SIDEBAR_RATIO     = T.SIDEBAR_RATIO
local FIELD_MEDIUM      = T.FIELD_MEDIUM
local FIELD_NARROW      = T.FIELD_NARROW
local FIELD_WIDE        = T.FIELD_WIDE
local DrawColoredText   = T.DrawColoredText
local PushTextColor     = T.PushTextColor
local PushTheme         = T.PushTheme
local PopTheme          = T.PopTheme


-- =============================================================================
-- STAGING TABLE (performance cache — avoids Chalk reads in render loop)
-- =============================================================================
-- Plain Lua tables mirroring each module's Chalk config.
-- UI reads/writes go through staging. Chalk is only touched in event handlers.

local staging = {
    ModEnabled = config.ModEnabled == true,  -- snapshot once
    modules    = {},  -- [module.id] = bool
    options    = {},  -- [module.id] = { [configKey] = value }
    specials   = {},  -- [special.modName] = bool (enabled state)
}

-- Profile staging: plain copies of config.Profiles
local profileStaging = {}

--- Snapshot all Chalk configs into staging (called at init and after profile load).
local function SnapshotToStaging()
    staging.ModEnabled = config.ModEnabled == true

    -- Boolean modules
    for _, m in ipairs(Discovery.modules) do
        staging.modules[m.id] = Discovery.isModuleEnabled(m)
    end

    -- Inline options
    for _, m in ipairs(Discovery.modulesWithOptions) do
        staging.options[m.id] = staging.options[m.id] or {}
        for _, opt in ipairs(m.options) do
            staging.options[m.id][opt.configKey] = Discovery.getOptionValue(m, opt.configKey)
        end
    end

    -- Special modules
    for _, special in ipairs(Discovery.specials) do
        staging.specials[special.modName] = Discovery.isSpecialEnabled(special)
        if special.mod.SnapshotStaging then
            special.mod.SnapshotStaging()
        end
    end

    -- Profiles
    for i, p in ipairs(config.Profiles) do
        profileStaging[i] = {
            Name    = p.Name or "",
            Hash    = p.Hash or "",
            Tooltip = p.Tooltip or "",
        }
    end
end

-- Initialize staging from current configs
SnapshotToStaging()

-- =============================================================================
-- CACHED DISPLAY DATA (rebuilt on dirty flag, never per-frame)
-- =============================================================================

local NUM_PROFILES = Def.NUM_PROFILES

local slotLabels = {}
local slotOccupied = {}
local slotLabelsDirty = true

local cachedHash = nil
local cachedFingerprint = nil

local selectedProfileSlot = 1
local selectedProfileCombo = 0
local importHashBuffer = ""
local importFeedback = nil
local importFeedbackColor = nil
local importFeedbackTime = nil

-- Bug fix status cache
local bugFixStatusText = ""
local bugFixStatusColor = colors.textDisabled
local bugFixStatusDirty = true

local FEEDBACK_DURATION = 2.0
local function SetImportFeedback(text, color)
    importFeedback = text
    importFeedbackColor = color
    importFeedbackTime = os.clock()
end

local function InvalidateHash()
    cachedHash = nil
    cachedFingerprint = nil
end

local function GetCachedHash()
    if not cachedHash then
        cachedHash, cachedFingerprint = Core.GetConfigHash(staging)
    end
    return cachedHash, cachedFingerprint
end

local function RebuildSlotLabels()
    for i, p in ipairs(profileStaging) do
        local hasName = p.Name ~= ""
        slotOccupied[i] = hasName
        if hasName then
            slotLabels[i] = i .. ": " .. p.Name
        else
            slotLabels[i] = i .. ": (empty)"
        end
    end
    slotLabelsDirty = false
end

local function RebuildBugFixStatus()
    local modules = Discovery.byCategory["Bug Fixes"] or {}
    if #modules == 0 then
        bugFixStatusText = "N/A"
        bugFixStatusColor = colors.textDisabled
        bugFixStatusDirty = false
        return
    end
    local hasEnabled = false
    local hasDisabled = false
    for _, m in ipairs(modules) do
        if staging.modules[m.id] then hasEnabled = true else hasDisabled = true end
    end
    if hasEnabled and not hasDisabled then
        bugFixStatusText = "All Enabled"
        bugFixStatusColor = colors.success
    elseif hasDisabled and not hasEnabled then
        bugFixStatusText = "All Disabled"
        bugFixStatusColor = colors.error
    else
        bugFixStatusText = "Mixed Configuration"
        bugFixStatusColor = colors.mixed
    end
    bugFixStatusDirty = false
end

-- =============================================================================
-- TOGGLE HELPERS (event handlers — OK to touch Chalk here)
-- =============================================================================

--- Apply enable/disable on the game side only (no Chalk, no staging).
--- Shared by ToggleModule and the master toggle.
local function SetModuleState(module, state)
    local fn = state and module.definition.apply or module.definition.revert
    local ok, err = pcall(fn)
    if not ok then
        lib.warn((module.modName or "unknown") .. " " .. (state and "apply" or "revert") .. " failed: " .. tostring(err))
    end
end

local function ToggleModule(module, enabled)
    -- Update staging
    staging.modules[module.id] = enabled
    -- Write to Chalk + call enable/disable
    Discovery.setModuleEnabled(module, enabled)
    if module.definition.dataMutation then
        SetupRunData()
    end
    InvalidateHash()
    bugFixStatusDirty = true
    Core.UpdateHash()
end

local function ChangeOption(module, configKey, value)
    -- Update staging
    staging.options[module.id] = staging.options[module.id] or {}
    staging.options[module.id][configKey] = value
    -- Write to Chalk
    Discovery.setOptionValue(module, configKey, value)
    -- Re-apply if data mutation (option may affect game tables).
    -- disable() restores vanilla, enable() re-applies with the new option value.
    if module.definition.dataMutation then
        SetModuleState(module, false)
        SetModuleState(module, true)
        SetupRunData()
    end
    InvalidateHash()
    Core.UpdateHash()
end

local function ToggleSpecial(special, enabled)
    staging.specials[special.modName] = enabled
    Discovery.setSpecialEnabled(special, enabled)
    InvalidateHash()
    Core.UpdateHash()
end

--- Generic callback passed to special modules' Draw* functions.
--- The module manages its own staging; we just tell it to sync and refresh hash.
local function MakeSpecialOnChanged(special)
    return function()
        if special.mod.SyncToConfig then
            special.mod.SyncToConfig()
        end
        InvalidateHash()
        Core.UpdateHash()
    end
end


--- Load a profile hash: decode, apply to all module configs, re-snapshot.
local function LoadProfile(hash)
    if Core.ApplyConfigHash(hash) then
        SetupRunData()
        SnapshotToStaging()
        InvalidateHash()
        bugFixStatusDirty = true
        slotLabelsDirty = true
        Core.UpdateHash()
        return true
    end
    return false
end

local function SetBugFixes(flag)
    local modules = Discovery.byCategory["Bug Fixes"] or {}
    for _, m in ipairs(modules) do
        staging.modules[m.id] = flag
        Discovery.setModuleEnabled(m, flag)
    end
    SetupRunData()
    InvalidateHash()
    bugFixStatusDirty = true
    Core.UpdateHash()
end

local defaultProfiles = Def.defaultProfiles


-- =============================================================================
-- GENERIC TAB CONTENT RENDERER
-- =============================================================================

local function DrawCheckboxGroup(layoutData, category)
    local modules = Discovery.byCategory[category] or {}
    local moduleMap = {}
    for _, m in ipairs(modules) do moduleMap[m.id] = m end

    for _, group in ipairs(layoutData) do
        PushTextColor(colors.info)
        local collapsingHeader = ui.CollapsingHeader(group.Header, ImGuiTreeNodeFlags.DefaultOpen)
        ui.PopStyleColor()
        if collapsingHeader then
            ui.Indent()
            for _, itemData in ipairs(group.Items) do
                local m = moduleMap[itemData.Key]
                if m then
                    -- Read from staging, not Chalk
                    local currentVal = staging.modules[m.id] or false
                    local val, chg = ui.Checkbox(itemData.Name, currentVal)
                    if chg then
                        ToggleModule(m, val)
                    end
                    if ui.IsItemHovered() and itemData.Tooltip and itemData.Tooltip ~= "" then
                        ui.SetTooltip(itemData.Tooltip)
                    end

                    -- Inline options (rendered below checkbox when module is enabled)
                    if currentVal and m.options then
                        ui.Indent()
                        local opts = staging.options[m.id] or {}
                        for _, opt in ipairs(m.options) do
                            ui.PushID(m.id .. "_" .. opt.configKey)
                            local newVal, newChg = lib.drawField(ui, opt, opts[opt.configKey], ui.GetWindowWidth() * FIELD_MEDIUM)
                            if newChg then
                                ChangeOption(m, opt.configKey, newVal)
                            end
                            ui.PopID()
                        end
                        ui.Unindent()
                    end
                end
            end
            ui.Unindent()
        end
        ui.Spacing()
    end
end

-- =============================================================================
-- MAIN WINDOW
-- =============================================================================

-- =============================================================================
-- SIDE TAB DEFINITIONS
-- =============================================================================

local selectedTab = "Quick Setup"

local function BuildTabList()
    local tabs = { "Quick Setup" }
    -- Special module tabs
    for _, special in ipairs(Discovery.specials) do
        local label = special.definition.tabLabel or special.definition.name
        table.insert(tabs, label)
    end
    -- Category tabs
    for _, cat in ipairs(Discovery.categories) do
        table.insert(tabs, cat.label)
    end
    table.insert(tabs, "Profiles")
    table.insert(tabs, "Dev")
    return tabs
end

-- Build lookup: tab label -> special entry
local specialByTabLabel = {}
for _, special in ipairs(Discovery.specials) do
    local label = special.definition.tabLabel or special.definition.name
    specialByTabLabel[label] = special
end

-- =============================================================================
-- TAB CONTENT DRAWERS
-- =============================================================================

local function DrawQuickSetup()
    local winW = ui.GetWindowWidth()

    DrawColoredText(colors.info, "Select a profile to automatically configure the modpack:")
    ui.Spacing()

    if slotLabelsDirty then RebuildSlotLabels() end

    local comboPreview = "Select..."
    if selectedProfileCombo > 0 and selectedProfileCombo <= NUM_PROFILES and slotOccupied[selectedProfileCombo] then
        comboPreview = slotLabels[selectedProfileCombo]
    end

    ui.PushItemWidth(winW * FIELD_MEDIUM)
    if ui.BeginCombo("Profile", comboPreview) then
        for i = 1, NUM_PROFILES do
            if slotOccupied[i] then
                ui.PushID(i)
                if ui.Selectable(slotLabels[i], i == selectedProfileCombo) then
                    selectedProfileCombo = i
                end
                if ui.IsItemHovered() then
                    local tip = profileStaging[i].Tooltip
                    if tip ~= "" then ui.SetTooltip(tip) end
                end
                ui.PopID()
            end
        end
        ui.EndCombo()
    end
    ui.PopItemWidth()

    ui.SameLine()
    local sel = selectedProfileCombo
    if sel > 0 and sel <= NUM_PROFILES then
        local hash = profileStaging[sel].Hash
        if hash ~= "" then
            if ui.Button("Load") then LoadProfile(hash) end
        end
    end

    ui.Separator()
    ui.Spacing()

    -- Bug fix bulk toggles
    if Discovery.byCategory["Bug Fixes"] then
        DrawColoredText(colors.info, "Toggle all bug fixes at once. Go to the Bug Fixes tab for individual control.")
        if bugFixStatusDirty then RebuildBugFixStatus() end
        DrawColoredText(colors.text, "Current Status: ")
        ui.SameLine()
        DrawColoredText(bugFixStatusColor, bugFixStatusText)
        ui.Spacing()

        if ui.Button("Enable All") then SetBugFixes(true) end
        ui.SameLine()
        if ui.Button("Disable All") then SetBugFixes(false) end

        ui.Separator()
        ui.Spacing()
    end

    -- Quick content from special modules
    for _, special in ipairs(Discovery.specials) do
        if staging.specials[special.modName] and special.mod.DrawQuickContent then
            ui.Separator()
            ui.Spacing()
            special.mod.DrawQuickContent(ui, MakeSpecialOnChanged(special), T)
        end
    end
end

local function DrawSpecialTab(special)
    -- Enable checkbox (standardized by Core)
    local enabled = staging.specials[special.modName] or false
    local val, chg = ui.Checkbox("Enable " .. special.definition.name, enabled)
    if chg then
        ToggleSpecial(special, val)
    end
    if ui.IsItemHovered() and special.definition.tooltip then
        ui.SetTooltip(special.definition.tooltip)
    end

    if not enabled then return end

    ui.Spacing()

    -- Delegate tab content to the module
    if special.mod.DrawTab then
        special.mod.DrawTab(ui, MakeSpecialOnChanged(special), T)
    end
end

local function DrawProfiles()
    local winW = ui.GetWindowWidth()

    -- Export / Import
    PushTextColor(colors.info)
    ui.CollapsingHeader("Export / Import", ImGuiTreeNodeFlags.DefaultOpen)
    ui.PopStyleColor()
    ui.Indent()

    -- Read cached hash (computed from staging, not Chalk)
    local canonical, fingerprint = GetCachedHash()
    ui.Text("Config ID:")
    ui.SameLine()
    DrawColoredText(colors.success, fingerprint)
    ui.SameLine()
    if ui.Button("Copy") then
        ui.SetClipboardText(canonical)
        SetImportFeedback("Copied to clipboard!", colors.success)
    end

    ui.Spacing()
    ui.Text("Import Hash:")
    ui.SameLine()
    ui.PushItemWidth(winW * FIELD_MEDIUM)
    local newText, changed = ui.InputText("##ImportHash", importHashBuffer, 256)
    if changed then importHashBuffer = newText end
    ui.PopItemWidth()
    ui.SameLine()
    if ui.Button("Paste") then
        local clip = ui.GetClipboardText()
        if clip then importHashBuffer = clip end
    end
    ui.SameLine()
    if ui.Button("Import") then
        if LoadProfile(importHashBuffer) then
            SetImportFeedback("Imported successfully!", colors.success)
        else
            SetImportFeedback("Invalid hash.", colors.error)
        end
    end
    if importFeedback then
        if os.clock() - importFeedbackTime > FEEDBACK_DURATION then
            importFeedback = nil
        else
            ui.SameLine()
            DrawColoredText(importFeedbackColor, importFeedback)
        end
    end

    ui.Unindent()
    ui.Spacing()
    ui.Separator()
    ui.Spacing()

    -- Profile Slot Selector
    PushTextColor(colors.info)
    ui.CollapsingHeader("Saved Profiles", ImGuiTreeNodeFlags.DefaultOpen)
    ui.PopStyleColor()
    ui.Indent()

    if slotLabelsDirty then RebuildSlotLabels() end

    ui.PushItemWidth(winW * FIELD_NARROW)
    if ui.BeginCombo("Slot", slotLabels[selectedProfileSlot]) then
        for i, label in ipairs(slotLabels) do
            if ui.Selectable(label, i == selectedProfileSlot) then
                selectedProfileSlot = i
            end
        end
        ui.EndCombo()
    end
    ui.PopItemWidth()

    ui.Spacing()

    -- Read from profileStaging, not Chalk
    local ps = profileStaging[selectedProfileSlot]
    local hasData = ps.Hash ~= ""

    ui.Text("Name:")
    ui.SameLine()
    ui.PushItemWidth(winW * FIELD_NARROW)
    local newName, nameChanged = ui.InputText("##SlotName", ps.Name, 64)
    if nameChanged then
        ps.Name = newName
        config.Profiles[selectedProfileSlot].Name = newName  -- write to Chalk
        slotLabelsDirty = true
    end
    ui.PopItemWidth()

    ui.Text("Tooltip:")
    ui.SameLine()
    ui.PushItemWidth(winW * FIELD_WIDE)
    local newTooltip, tooltipChanged = ui.InputText("##SlotTooltip", ps.Tooltip, 256)
    if tooltipChanged then
        ps.Tooltip = newTooltip
        config.Profiles[selectedProfileSlot].Tooltip = newTooltip  -- write to Chalk
    end
    ui.PopItemWidth()

    if hasData then
        ui.Text("Hash:")
        ui.SameLine()
        DrawColoredText(colors.textDisabled, ps.Hash)
    end

    ui.Spacing()

    if ui.Button("Save Current") then
        local h = GetCachedHash()
        ps.Hash = h
        config.Profiles[selectedProfileSlot].Hash = h  -- write to Chalk
        if ps.Name == "" then
            ps.Name = "Profile " .. selectedProfileSlot
            config.Profiles[selectedProfileSlot].Name = ps.Name
        end
        slotLabelsDirty = true
    end

    if hasData then
        ui.SameLine()
        if ui.Button("Load") then LoadProfile(ps.Hash) end
        ui.SameLine()
        if ui.Button("Clear") then
            ps.Name = ""
            ps.Hash = ""
            ps.Tooltip = ""
            local cp = config.Profiles[selectedProfileSlot]
            cp.Name = ""
            cp.Hash = ""
            cp.Tooltip = ""
            slotLabelsDirty = true
        end
        if ui.IsItemHovered() then
            ui.SetTooltip("Permanently clears this profile slot.")
        end
    end

    ui.Unindent()
    ui.Spacing()
    ui.Separator()
    ui.Spacing()

    if ui.Button("Restore Default Profiles") then
        for i = 1, NUM_PROFILES do
            local d = defaultProfiles[i]
            local cp = config.Profiles[i]  -- Chalk write
            if d then
                profileStaging[i] = { Name = d.Name, Hash = d.Hash, Tooltip = d.Tooltip }
                cp.Name = d.Name
                cp.Hash = d.Hash
                cp.Tooltip = d.Tooltip
            else
                profileStaging[i] = { Name = "", Hash = "", Tooltip = "" }
                cp.Name = ""
                cp.Hash = ""
                cp.Tooltip = ""
            end
        end
        slotLabelsDirty = true
    end
    if ui.IsItemHovered() then
        ui.SetTooltip("Overwrites ALL profile slots with the shipped defaults. Custom profiles will be lost.")
    end
end

-- =============================================================================
-- CATEGORY LABEL LOOKUP
-- =============================================================================

local function DrawDev()
    DrawColoredText(colors.info, "Developer options for module authors and debugging.")
    ui.Spacing()

    local val, chg = ui.Checkbox("Debug Mode", config.DebugMode == true)
    if chg then
        config.DebugMode = val
    end
    if ui.IsItemHovered() then
        ui.SetTooltip("Enables diagnostic warnings in the console for schema validation, missing fields, and module errors.")
    end
end

local categoryKeyByLabel = {}
for _, cat in ipairs(Discovery.categories) do
    categoryKeyByLabel[cat.label] = cat.key
end

-- =============================================================================
-- MAIN WINDOW
-- =============================================================================

local function DrawMainWindow()
    -- Read from staging, not Chalk
    local val, chg = ui.Checkbox("Enable Mod", staging.ModEnabled)
    if chg then
        staging.ModEnabled = val
        config.ModEnabled = val  -- write to Chalk once (event handler)
        -- Apply game-side enable/disable based on staging state.
        -- Staging is preserved so re-enable restores previous selections.
        for _, m in ipairs(Discovery.modules) do
            if staging.modules[m.id] then
                SetModuleState(m, val)
            end
        end
        for _, special in ipairs(Discovery.specials) do
            if staging.specials[special.modName] then
                SetModuleState(special, val)
            end
        end
        SetupRunData()
        Core.SetModMarker(val)
    end
    if ui.IsItemHovered() then ui.SetTooltip("Toggle the entire modpack on or off.") end

    if not staging.ModEnabled then
        ui.Separator()
        DrawColoredText(colors.warning, "Mod is currently disabled. All changes have been reverted.")
        return
    end

    ui.Spacing()
    ui.Separator()
    ui.Spacing()

    local tabs = BuildTabList()
    local totalW = ui.GetWindowWidth()
    local sidebarW = totalW * SIDEBAR_RATIO

    -- Sidebar (proportional width, fill remaining height)
    ui.BeginChild("Sidebar", sidebarW, 0, true)
    for _, tabName in ipairs(tabs) do
        if ui.Selectable(tabName, selectedTab == tabName) then
            selectedTab = tabName
        end
    end
    ui.EndChild()

    ui.SameLine()

    -- Content panel (0 height = fill remaining space)
    ui.BeginChild("TabContent", 0, 0, true)
    ui.Spacing()

    if selectedTab == "Quick Setup" then
        DrawQuickSetup()
    elseif selectedTab == "Profiles" then
        DrawProfiles()
    elseif selectedTab == "Dev" then
        DrawDev()
    elseif specialByTabLabel[selectedTab] then
        -- Special module tab
        DrawSpecialTab(specialByTabLabel[selectedTab])
    else
        -- Dynamic category tab
        local catKey = categoryKeyByLabel[selectedTab]
        if catKey and Discovery.categoryLayouts[catKey] then
            DrawCheckboxGroup(Discovery.categoryLayouts[catKey], catKey)
        end
    end

    ui.EndChild()
end

-- =============================================================================
-- REGISTRATION (guarded against re-import)
-- =============================================================================

if not Core._uiRegistered then
    Core._uiRegistered = true
    Core._showModWindow = false

    rom.gui.add_imgui(function()
        if Core._showModWindow then
            PushTheme()
            if ui.Begin("Speedrun Modpack", true) then
                DrawMainWindow()
                ui.End()
            else
                Core._showModWindow = false
            end
            PopTheme()
        end
    end)

    rom.gui.add_to_menu_bar(function()
        if ui.MenuItem("Show Mod Menu") then
            Core._showModWindow = not Core._showModWindow
        end
    end)
end
