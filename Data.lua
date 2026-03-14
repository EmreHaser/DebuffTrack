local addonName, addon = ...

------------------------------------------------------------
-- Debuff database
-- Each entry contains a dungeon/raid name and its debuffs.
-- Update spellId values to match current game content.
-- To add new dungeons/raids, simply append a new table entry.
------------------------------------------------------------

addon.DungeonData = {
    {
        name = "Ara-Kara, City of Echoes",
        debuffs = {
            { spellId = 434824, name = "Gossamer Onslaught" },
            { spellId = 438599, name = "Venom Volley" },
            { spellId = 436322, name = "Acid Bolt" },
            { spellId = 438618, name = "Undermining" },
        },
    },
    {
        name = "City of Threads",
        debuffs = {
            { spellId = 443427, name = "Shadows of Doubt" },
            { spellId = 443438, name = "Doubt" },
            { spellId = 452162, name = "Mending Web" },
            { spellId = 443401, name = "Void Wave" },
        },
    },
    {
        name = "The Stonevault",
        debuffs = {
            { spellId = 426308, name = "Void Discharge" },
            { spellId = 449455, name = "Censoring Gear" },
            { spellId = 427329, name = "Crystalline Eruption" },
        },
    },
    {
        name = "The Dawnbreaker",
        debuffs = {
            { spellId = 451097, name = "Ensnaring Shadows" },
            { spellId = 450854, name = "Tormenting Beam" },
            { spellId = 451117, name = "Collapsing Night" },
        },
    },
}

addon.RaidData = {
    {
        name = "Liberation of Undermine",
        debuffs = {
            { spellId = 468655, name = "Unstable Crawler Mine" },
            { spellId = 473650, name = "Doom" },
            { spellId = 466615, name = "Resonance" },
            { spellId = 470901, name = "Molten Rupture" },
        },
    },
}

