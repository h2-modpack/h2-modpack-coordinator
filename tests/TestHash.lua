local lu = require('luaunit')

-- =============================================================================
-- Load hash.lua in test harness
-- =============================================================================
-- TestUtils.lua has already set up Core, lib, and rom mocks.
-- We load hash.lua which attaches Hash to Core.
-- Each test sets Core.Discovery via withDiscovery().

dofile("src/hash.lua")

local Hash = Core.Hash

-- =============================================================================
-- BASE62 TESTS (EncodeBase62/DecodeBase62 still used for fingerprint)
-- =============================================================================

TestBase62 = {}

function TestBase62:testEncodeZero()
    lu.assertEquals(Hash.EncodeBase62(0), "0")
end

function TestBase62:testEncodeSingleDigit()
    lu.assertEquals(Hash.EncodeBase62(9), "9")
    lu.assertEquals(Hash.EncodeBase62(10), "A")
    lu.assertEquals(Hash.EncodeBase62(61), "z")
end

function TestBase62:testEncodeMultiDigit()
    lu.assertEquals(Hash.EncodeBase62(62), "10")
    lu.assertEquals(Hash.EncodeBase62(124), "20")
end

function TestBase62:testRoundTrip()
    for _, n in ipairs({0, 1, 42, 61, 62, 100, 999, 123456, 1073741823}) do
        lu.assertEquals(Hash.DecodeBase62(Hash.EncodeBase62(n)), n)
    end
end

function TestBase62:testDecodeInvalidChar()
    lu.assertIsNil(Hash.DecodeBase62("!invalid"))
end

-- =============================================================================
-- HELPERS
-- =============================================================================

local function withDiscovery(discovery)
    Core.Discovery = discovery
    return Hash.GetConfigHash, Hash.ApplyConfigHash
end

-- =============================================================================
-- KEY-VALUE ROUND-TRIPS
-- =============================================================================

TestHashKeyValue = {}

function TestHashKeyValue:testBoolOnlyAllEnabled()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true,  default = false },
        { id = "B", category = "Cat1", enabled = true,  default = false },
        { id = "C", category = "Cat1", enabled = true,  default = false },
    })
    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    for _, m in ipairs(discovery.modules) do m.mod.config.Enabled = false end
    ApplyHash(hash)

    for _, m in ipairs(discovery.modules) do
        lu.assertTrue(m.mod.config.Enabled)
    end
end

function TestHashKeyValue:testBoolOnlyMixedStates()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true,  default = false },
        { id = "B", category = "Cat1", enabled = false, default = false },
        { id = "C", category = "Cat2", enabled = true,  default = false },
        { id = "D", category = "Cat2", enabled = false, default = false },
    })
    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    for _, m in ipairs(discovery.modules) do
        m.mod.config.Enabled = not m.mod.config.Enabled
    end
    ApplyHash(hash)

    lu.assertTrue(discovery.modulesById["A"].mod.config.Enabled)
    lu.assertFalse(discovery.modulesById["B"].mod.config.Enabled)
    lu.assertTrue(discovery.modulesById["C"].mod.config.Enabled)
    lu.assertFalse(discovery.modulesById["D"].mod.config.Enabled)
end

function TestHashKeyValue:testDropdownOptionRoundTrip()
    local opts = {
        { type = "dropdown", configKey = "Mode", values = {"Vanilla", "Always", "Never"}, default = "Vanilla" },
    }
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false, options = opts },
    })
    discovery.modules[1].mod.config.Mode = "Always"

    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    discovery.modules[1].mod.config.Enabled = false
    discovery.modules[1].mod.config.Mode = "Vanilla"
    ApplyHash(hash)

    lu.assertTrue(discovery.modules[1].mod.config.Enabled)
    lu.assertEquals(discovery.modules[1].mod.config.Mode, "Always")
end

function TestHashKeyValue:testCheckboxOptionRoundTrip()
    local opts = {
        { type = "checkbox", configKey = "Strict", default = false },
    }
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false, options = opts },
    })
    discovery.modules[1].mod.config.Strict = true

    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    discovery.modules[1].mod.config.Strict = false
    ApplyHash(hash)

    lu.assertTrue(discovery.modules[1].mod.config.Strict)
end

function TestHashKeyValue:testSpecialSchemaRoundTrip()
    local discovery = MockDiscovery.create(
        { { id = "A", category = "Cat1", enabled = true, default = false } },
        {},
        {
            {
                modName = "adamant-Special",
                config = { Weapon = "Axe", Aspect = "Default" },
                stateSchema = {
                    { type = "dropdown", configKey = "Weapon", values = {"Axe", "Staff", "Daggers"}, default = "Axe" },
                    { type = "dropdown", configKey = "Aspect", values = {"Default", "Alpha", "Beta"}, default = "Default" },
                },
            },
        }
    )
    -- Set non-default values
    discovery.specials[1].mod.config.Weapon = "Staff"
    discovery.specials[1].mod.config.Aspect = "Beta"

    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    discovery.specials[1].mod.config.Weapon = "Axe"
    discovery.specials[1].mod.config.Aspect = "Default"
    ApplyHash(hash)

    lu.assertEquals(discovery.specials[1].mod.config.Weapon, "Staff")
    lu.assertEquals(discovery.specials[1].mod.config.Aspect, "Beta")
end

-- =============================================================================
-- OMIT DEFAULTS
-- =============================================================================

TestHashOmitDefaults = {}

function TestHashOmitDefaults:testAllDefaultsProduceVersionOnlyCanonical()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = false, default = false },
        { id = "B", category = "Cat1", enabled = true,  default = true  },
    })
    local GetHash = withDiscovery(discovery)
    local canonical = GetHash()

    lu.assertEquals(canonical, "_v=1")
end

function TestHashOmitDefaults:testNonDefaultAppearsInCanonical()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false },
    })
    local GetHash = withDiscovery(discovery)
    local canonical = GetHash()

    lu.assertStrContains(canonical, "A=1")
end

function TestHashOmitDefaults:testOptionAtDefaultOmitted()
    local opts = {
        { type = "dropdown", configKey = "Mode", values = {"Vanilla", "Always"}, default = "Vanilla" },
    }
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = false, default = false, options = opts },
    })
    discovery.modules[1].mod.config.Mode = "Vanilla"  -- at default

    local GetHash = withDiscovery(discovery)
    local canonical = GetHash()

    lu.assertEquals(canonical, "_v=1")
end

function TestHashOmitDefaults:testOptionNonDefaultIncluded()
    local opts = {
        { type = "dropdown", configKey = "Mode", values = {"Vanilla", "Always"}, default = "Vanilla" },
    }
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = false, default = false, options = opts },
    })
    discovery.modules[1].mod.config.Mode = "Always"  -- non-default

    local GetHash = withDiscovery(discovery)
    local canonical = GetHash()

    lu.assertStrContains(canonical, "A.Mode=Always")
end

-- =============================================================================
-- ROBUSTNESS
-- =============================================================================

TestHashRobustness = {}

function TestHashRobustness:testHashFromFewerModulesAppliesCleanly()
    -- Hash produced with 2 modules, applied to setup with 3 modules
    -- New module should reset to its default
    local discovery2 = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true,  default = false },
        { id = "B", category = "Cat1", enabled = false, default = false },
    })
    local GetHash = withDiscovery(discovery2)
    local hash = GetHash()

    -- Now apply to a 3-module discovery
    local discovery3 = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = false, default = false },
        { id = "B", category = "Cat1", enabled = true,  default = false },
        { id = "C", category = "Cat1", enabled = true,  default = false },  -- new module
    })
    local _, ApplyHash = withDiscovery(discovery3)
    ApplyHash(hash)

    lu.assertTrue(discovery3.modulesById["A"].mod.config.Enabled)   -- restored from hash
    lu.assertFalse(discovery3.modulesById["B"].mod.config.Enabled)  -- restored from hash
    lu.assertFalse(discovery3.modulesById["C"].mod.config.Enabled)  -- reset to default (false)
end

function TestHashRobustness:testHashWithDefaultTrueModule()
    -- Module with default=true: absent from hash means enabled
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = true },
    })
    local GetHash, ApplyHash = withDiscovery(discovery)
    local hash = GetHash()

    -- Hash should be version-only (value matches default, no payload)
    lu.assertEquals(hash, "_v=1")

    -- Disable the module, then apply empty hash — should restore to default (true)
    discovery.modules[1].mod.config.Enabled = false
    ApplyHash(hash)
    lu.assertTrue(discovery.modules[1].mod.config.Enabled)
end

-- =============================================================================
-- FINGERPRINT
-- =============================================================================

TestHashFingerprint = {}

function TestHashFingerprint:testSameConfigSameFingerprint()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true,  default = false },
        { id = "B", category = "Cat1", enabled = false, default = false },
    })
    local GetHash = withDiscovery(discovery)
    local _, fp1 = GetHash()
    local _, fp2 = GetHash()
    lu.assertEquals(fp1, fp2)
end

function TestHashFingerprint:testDifferentConfigDifferentFingerprint()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true,  default = false },
        { id = "B", category = "Cat1", enabled = false, default = false },
    })
    local GetHash = withDiscovery(discovery)
    local _, fp1 = GetHash()

    discovery.modules[2].mod.config.Enabled = true
    local _, fp2 = GetHash()

    lu.assertNotEquals(fp1, fp2)
end

function TestHashFingerprint:testFingerprintIsNonEmptyString()
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false },
    })
    local GetHash = withDiscovery(discovery)
    local _, fp = GetHash()
    lu.assertIsString(fp)
    lu.assertTrue(#fp > 0)
end

function TestHashFingerprint:testAllDefaultsHasStableFingerprint()
    -- Even with empty canonical, fingerprint should be stable
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = false, default = false },
    })
    local GetHash = withDiscovery(discovery)
    local _, fp1 = GetHash()
    local _, fp2 = GetHash()
    lu.assertEquals(fp1, fp2)
end

-- =============================================================================
-- ERROR HANDLING
-- =============================================================================

TestHashErrors = {}

function TestHashErrors:testNilHashRejected()
    local discovery = MockDiscovery.create({})
    withDiscovery(discovery)
    ---@diagnostic disable-next-line: param-type-mismatch
    lu.assertFalse(Hash.ApplyConfigHash(nil))
end

function TestHashErrors:testEmptyHashAppliesDefaults()
    -- Empty canonical string is valid — means all values are at defaults
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false },
    })
    local _, ApplyHash = withDiscovery(discovery)
    local result = ApplyHash("")
    lu.assertTrue(result)
    lu.assertFalse(discovery.modules[1].mod.config.Enabled)  -- reset to default
end

function TestHashErrors:testMalformedHashStillAppliesDefaults()
    -- Malformed entries are ignored, modules reset to defaults
    local discovery = MockDiscovery.create({
        { id = "A", category = "Cat1", enabled = true, default = false },
    })
    local _, ApplyHash = withDiscovery(discovery)

    -- "A" is not a valid key=value pair but the hash string is non-empty
    -- Should return true (non-empty input) and reset A to default
    local result = ApplyHash("notavalidentry")
    lu.assertTrue(result)
    lu.assertFalse(discovery.modules[1].mod.config.Enabled)  -- reset to default
end
