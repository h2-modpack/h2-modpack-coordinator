-- =============================================================================
-- FIXED DEFINITIONS
-- =============================================================================
-- Constants and default data shared across Core files.
-- Imported via `import 'def.lua'`.

Core.Def = {
    NUM_PROFILES = #config.Profiles,

    defaultProfiles = {
        { Name = "AnyFear",  Hash = "1AfB0V.3", Tooltip = "RTA Disabled. Arachne Pity Disabled" },
        { Name = "HighFear", Hash = "1AfB0t.3", Tooltip = "RTA Disabled. Arachne Spawn Forced" },
        { Name = "RTA",      Hash = "1AfB20.3", Tooltip = "RTA Enabled. Arachne Pity Enabled. Medea/Arachne Spawns Not Forced" },
    },
}
