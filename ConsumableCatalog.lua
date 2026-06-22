-- ConsumableCatalog.lua
-- Convenience catalog of Midnight Season 1 consumables for ReadyCheck Loadouts.
--
-- ROLE: This is the OPTIONAL "quick-add" data source. The PRIMARY way users add tracked
-- consumables is the bag-scan, which surfaces whatever they actually carry. This catalog
-- exists for two reasons:
--   1. Pre-adding an item the user does NOT own yet (e.g. a flask they're about to buy),
--      which a bag-scan can't surface because it isn't in their bags.
--   2. Supplying the equivalence groups below for the future "count as a group" feature.
--
-- CRAFTING QUALITY: Midnight crafted consumables have TWO live itemIDs (Silver + Gold quality
-- tiers), not one. Each entry stores the full id set as `ids = { ... }`, and counts are summed
-- across every id in the set. A single GetItemCount(id) sees only one tier and undercounts
-- whenever both tiers are carried (that was the bug this catalog now fixes). Non-crafted items
-- (looted/quest) and anything pre-Dragonflight have no quality tiers and are single-id: a
-- one-element set, e.g. ids = { 132514 }.
--
-- ID SOURCING: the original Gold-tier ids are screenshot-verified from a live client EXCEPT the four
-- marked [web] (cross-checked across Wowhead and Warcraft Wiki, not yet seen in-client, though their
-- Silver partners are now client-confirmed). The Silver-tier second ranks are new in this refactor; the
-- five formerly flagged "pattern-derived, scan-verify" inline (241320, 241323, 241324, 241289, 241301)
-- came from the Alchemy even=Gold / odd=Silver id rule and are now client-verified.
--
-- CROSS-EXPANSION UTILITY: battle rez, drums, and repair recur each expansion. Older versions
-- SOMETIMES keep working and sometimes fall out at the level cap, item by item (TWW jumper cables
-- work despite a wrong level-80 tooltip; Dragonflight cables/drums do NOT work at cap). Only
-- verified-functional legacy items belong in the equivalence groups. The catalog lists the current
-- Midnight canonical; the bag-scan catches whatever variant a user actually carries. Niche utility
-- (e.g. invisibility potions) is intentionally left to the scan rather than curated here.
--
-- LOAD ORDER: list this file before ReadyCheckLoadouts.lua in the .toc so RCL.CONSUMABLE_CATALOG
-- exists when the main file reads it.

local addonName, RCL = ...

RCL.CONSUMABLE_CATALOG = {
    {
        key = "flask", label = "Flask",
        items = {
            { ids = { 241326, 241327 }, name = "Flask of the Shattered Sun",     note = "Crit" },
            { ids = { 241324, 241325 }, name = "Flask of the Blood Knights",     note = "Haste" },       -- 241324 client-verified: Gold, +165 Haste
            { ids = { 241320, 241321 }, name = "Flask of Thalassian Resistance", note = "Versatility" }, -- 241320 client-verified: Gold, +165 Vers
            { ids = { 241322, 241323 }, name = "Flask of the Magisters",         note = "Mastery" },     -- [web] (241322, partner client-verified); 241323 client-verified: Silver, +151 Mastery
        },
    },
    {
        key = "combatPotion", label = "Combat Potion",
        items = {
            { ids = { 241308, 241309 }, name = "Light's Potential",          note = "Primary stat, safe default" },
            { ids = { 241292, 241293 }, name = "Draught of Rampant Abandon", note = "Primary stat, drops void zones" }, -- [web] (241292, partner client-verified via live DB)
            { ids = { 241288, 241289 }, name = "Potion of Recklessness",     note = "Highest secondary, sheds lowest" }, -- [web] (241288, partner client-verified); 241289 client-verified: Silver, gain 1584
        },
    },
    {
        key = "sustain", label = "Healing / Mana",
        items = {
            { ids = { 241304, 241305 }, name = "Silvermoon Health Potion", note = "Healing" },
            { ids = { 241300, 241301 }, name = "Lightfused Mana Potion",   note = "Mana (healers / casters)" }, -- 241301 client-verified: Silver, 22,361 mana
        },
    },
    -- Midnight food and tea are single-tier (client-confirmed); single-id is correct here.
    {
        key = "feast", label = "Feast",
        items = {
            { ids = { 255846 }, name = "Harandar Celebration",        note = "Primary stat (vegetarian)" },
            { ids = { 266996 }, name = "Hearty Harandar Celebration", note = "Primary stat, persists through death (hearty)" },
            { ids = { 255845 }, name = "Silvermoon Parade",           note = "Primary stat" },
            { ids = { 242273 }, name = "Blooming Feast",              note = "Highest secondary (vegetarian)" },
            { ids = { 242272 }, name = "Quel'dorei Medley",           note = "Highest secondary" },
        },
    },
    {
        key = "personalFood", label = "Personal Food",
        items = {
            { ids = { 255847 }, name = "Impossibly Royal Roast",        note = "Primary stat (vegetarian)" },
            { ids = { 268679 }, name = "Hearty Impossibly Royal Roast", note = "Primary stat, persists through death (hearty)" },
            { ids = { 242275 }, name = "Royal Roast",                   note = "Primary stat" },
            { ids = { 242274 }, name = "Champion's Bento",              note = "Highest secondary" },
        },
    },
    {
        key = "tea", label = "Tea (mana recovery)",
        items = {
            { ids = { 242297 }, name = "Mana Lily Tea" },
            { ids = { 242298 }, name = "Argentleaf Tea" },
            { ids = { 242299 }, name = "Sanguithorn Tea" },
            { ids = { 242300 }, name = "Tranquility Bloom Tea" },
            { ids = { 242301 }, name = "Azeroot Tea" },
        },
    },
    {
        key = "oil", label = "Weapon Oil",
        items = {
            { ids = { 243733, 243734 }, name = "Thalassian Phoenix Oil", note = "Crit + Haste, current BiS" },
            -- TODO (thoroughness, nobody optimal runs these): Refulgent Whetstone (bladed),
            -- Refulgent Weightstone (blunt). IDs pending.
        },
    },
    {
        key = "augmentRune", label = "Augment Rune",
        items = {
            { ids = { 259085 }, name = "Void-Touched Augment Rune", note = "Primary stat, 1h, no death persist" }, -- [web]; looted/quest, single-id (no quality tier)
        },
    },
    {
        key = "utility", label = "Utility",
        items = {
            { ids = { 248486, 269586 }, name = "Emergency Soul Link", note = "Battle rez (current). Castable in combat." }, -- Midnight battle rez, two tiers
            { ids = { 244639 },         name = "Void-Touched Drums",  note = "15% haste, lust substitute" },                -- single-id: lust does not scale with quality
            { ids = { 132514 },         name = "Auto-Hammer",         note = "Field repair, reusable (presence-track at 1)" }, -- Legion, pre-Dragonflight, single-id (no quality)
            -- Older variants (caught by bag-scan, linked in groups below):
            --   221955 Convincingly Realistic Jumper Cables (TWW battle rez, works at cap)
            --   219905 Thunderous Drums (TWW lust, works at cap)
            -- Deliberately NOT included (non-functional at the level-90 cap): Dragonflight jumper
            -- cables and Dragonflight drums. Do not re-add legacy items without verifying they fire.
        },
    },
}

-- Equivalence groups: sets of itemIDs that are mechanically interchangeable for tracking.
-- NOT used by v1 (the bag-scan tracks each item the user actually adds). Reserved for the
-- v2 "track as a group, sum the counts" feature, so that logic does not have to
-- reverse-engineer which items are equivalent. Only verified-functional items belong here.
RCL.CONSUMABLE_GROUPS = {
    primaryFeast   = { 255846, 255845 },                        -- Harandar / Silvermoon Parade
    secondaryFeast = { 242273, 242272 },                        -- Blooming / Quel'dorei
    primaryFood    = { 255847, 242275 },                        -- Impossibly Royal Roast / Royal Roast
    manaTea        = { 242297, 242298, 242299, 242300, 242301 },-- all teas (tertiary buffs drop in combat)
    drums          = { 244639, 219905 },                        -- Void-Touched (Midnight) / Thunderous (TWW). DF drums omitted (non-functional at cap).
    battleRez      = { 248486, 221955 },                        -- Emergency Soul Link (Midnight) / Convincingly Realistic Jumper Cables (TWW, tooltip cap is wrong, verified working). DF cables omitted.
}
