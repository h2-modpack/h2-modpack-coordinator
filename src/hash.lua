-- =============================================================================
-- CONFIG HASH: Key-Value Encoding / Decoding
-- =============================================================================
-- Pure hash logic — no engine dependencies. Testable in standalone Lua.
-- Depends on: Core.Discovery (module list), lib (readPath/writePath)
--
-- Two-layer design:
--   canonical  — key-value string encoding all non-default values (for export/import)
--   fingerprint — short base62 checksum of canonical string (for HUD display)
--
-- Format: "ModId=1|ModId.configKey=value|adamant-SpecialName.configKey=value"
-- Keys are sorted alphabetically for stable output.
-- Only non-default values are encoded — adding new fields with defaults is non-breaking.

local lib = rom.mods['adamant-Modpack_Lib']

local HASH_VERSION = 1

local Hash = {}

local BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

-- =============================================================================
-- BASE62 (used for fingerprint generation)
-- =============================================================================

function Hash.EncodeBase62(n)
    if n == 0 then return "0" end
    local result = ""
    while n > 0 do
        local idx = (n % 62) + 1
        result = string.sub(BASE62, idx, idx) .. result
        n = math.floor(n / 62)
    end
    return result
end

function Hash.DecodeBase62(str)
    local n = 0
    for i = 1, #str do
        local c = string.sub(str, i, i)
        local idx = string.find(BASE62, c, 1, true)
        if not idx then return nil end
        n = n * 62 + (idx - 1)
    end
    return n
end

-- =============================================================================
-- SERIALIZATION
-- =============================================================================

-- Sort keys for stable output, then join as "key=value|key=value"
local function Serialize(kv)
    local keys = {}
    for k in pairs(kv) do
        table.insert(keys, k)
    end
    table.sort(keys)
    local parts = {}
    for _, k in ipairs(keys) do
        table.insert(parts, k .. "=" .. kv[k])
    end
    return table.concat(parts, "|")
end

-- Parse "key=value|key=value" into a table. Returns {} on empty input.
local function Deserialize(str)
    local pairs = {}
    if not str or str == "" then return pairs end
    for entry in string.gmatch(str .. "|", "([^|]*)|") do
        local k, v = string.match(entry, "^([^=]+)=(.*)$")
        if k and v then
            pairs[k] = v
        end
    end
    return pairs
end

-- Two independent djb2 passes with different seeds, concatenated.
-- Each pass produces up to 6 base62 chars (30-bit range), padded to fixed width.
-- Combined: always exactly 12 chars, ~60 bits of collision resistance.
local function HashChunk(str, seed, multiplier)
    local h = seed
    for i = 1, #str do
        h = (h * multiplier + string.byte(str, i)) % 1073741824  -- 2^30
    end
    return h
end

local function EncodeBase62Fixed(n, width)
    local s = Hash.EncodeBase62(n)
    while #s < width do s = "0" .. s end
    return s
end

local function Fingerprint(str)
    local h1 = HashChunk(str, 5381,  33)
    local h2 = HashChunk(str, 52711, 37)
    return EncodeBase62Fixed(h1, 6) .. EncodeBase62Fixed(h2, 6)
end

-- Stable string key for a configKey that may be a string or table path.
-- {"Parent", "Child"} -> "Parent.Child",  "SimpleKey" -> "SimpleKey"
local function KeyStr(configKey)
    if type(configKey) == "table" then
        return table.concat(configKey, ".")
    end
    return tostring(configKey)
end

-- Encode/decode delegates to the field type defined in lib.FieldTypes
local function EncodeValue(field, value)
    return lib.FieldTypes[field.type].toHash(field, value)
end

local function DecodeValue(field, str)
    return lib.FieldTypes[field.type].fromHash(field, str)
end

-- =============================================================================
-- CONFIG HASH
-- =============================================================================

--- Compute config hash from a staging table or from live module configs.
--- @param source table|nil If provided, reads source.modules[id] for bools and source.options[id][key] for options.
--- @return string canonical, string fingerprint
function Hash.GetConfigHash(source)
    local kv = {}

    -- Boolean module enabled states (omit if matches module default)
    for _, m in ipairs(Core.Discovery.modules) do
        local enabled
        if source then
            enabled = source.modules and source.modules[m.id]
        else
            enabled = Core.Discovery.isModuleEnabled(m)
        end
        if enabled == nil then enabled = false end
        local default = m.default ~= false  -- treat nil default as false
        if enabled ~= default then
            kv[m.id] = enabled and "1" or "0"
        end
    end

    -- Inline option values (omit if matches field default)
    for _, m in ipairs(Core.Discovery.modulesWithOptions) do
        for _, opt in ipairs(m.options) do
            local current
            if source then
                current = source.options and source.options[m.id]
                    and source.options[m.id][opt.configKey]
            end
            if current == nil then
                current = Core.Discovery.getOptionValue(m, opt.configKey)
            end
            if current ~= opt.default then
                kv[m.id .. "." .. KeyStr(opt.configKey)] = EncodeValue(opt, current)
            end
        end
    end

    -- Special module state schema values (omit if matches field default)
    for _, special in ipairs(Core.Discovery.specials) do
        local schema = special.stateSchema
        if schema then
            local cfg = special.mod.config
            for _, field in ipairs(schema) do
                local current = lib.readPath(cfg, field.configKey)
                if current ~= field.default then
                    kv[special.modName .. "." .. KeyStr(field.configKey)] = EncodeValue(field, current)
                end
            end
        end
    end

    local payload = Serialize(kv)
    local canonical = "_v=" .. HASH_VERSION
        .. (payload ~= "" and "|" .. payload or "")
    return canonical, Fingerprint(canonical)
end

--- Apply a canonical config hash to module configs.
--- @param hash string The canonical key-value string to decode
--- @return boolean success
function Hash.ApplyConfigHash(hash)
    if hash == nil then
        lib.warn("ApplyConfigHash: nil hash")
        return false
    end

    local kv = Deserialize(hash)

    local version = tonumber(kv["_v"]) or 1
    if version > HASH_VERSION then
        lib.warn("ApplyConfigHash: hash version " .. version .. " is newer than supported (" .. HASH_VERSION .. ") — some settings may not apply")
    end

    -- Boolean module enabled states
    for _, m in ipairs(Core.Discovery.modules) do
        local stored = kv[m.id]
        if stored ~= nil then
            Core.Discovery.setModuleEnabled(m, stored == "1")
        else
            -- Not in hash = was at default when hash was made, reset to default
            local default = m.default ~= false
            Core.Discovery.setModuleEnabled(m, default)
        end
    end

    -- Inline option values
    for _, m in ipairs(Core.Discovery.modulesWithOptions) do
        for _, opt in ipairs(m.options) do
            local stored = kv[m.id .. "." .. KeyStr(opt.configKey)]
            if stored ~= nil then
                Core.Discovery.setOptionValue(m, opt.configKey, DecodeValue(opt, stored))
            else
                Core.Discovery.setOptionValue(m, opt.configKey, opt.default)
            end
        end
    end

    -- Special module state schema values
    for _, special in ipairs(Core.Discovery.specials) do
        local schema = special.stateSchema
        if schema then
            local cfg = special.mod.config
            for _, field in ipairs(schema) do
                local stored = kv[special.modName .. "." .. KeyStr(field.configKey)]
                if stored ~= nil then
                    lib.writePath(cfg, field.configKey, DecodeValue(field, stored))
                else
                    lib.writePath(cfg, field.configKey, field.default)
                end
            end
            if special.mod.SnapshotStaging then
                special.mod.SnapshotStaging()
            end
        end
    end

    return true
end

Core.Hash = Hash
