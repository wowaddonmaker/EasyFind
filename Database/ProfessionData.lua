local _, ns = ...

-- Generated from the EasyFindDev professions crawl (Midnight child skill
-- lines, captured passively from the live recipe-list data provider). Keyed
-- by the parent profession skillLine GetProfessions reports. recipeIDs are
-- spellIDs: display names resolve localized at populate via C_Spell; icons
-- are the recipe list's own (crafted output / gathered herb art).
ns.PROFESSION_RECIPES = {
    [182] = { -- Herbalism
        childSkillLine = 2912, -- Midnight Herbalism page (the openable UI ID)
        -- Expansion pages (the Sources/expansion radio): child professionIDs.
        -- Names are enUS capture fallbacks; live window names win when loaded.
        children = {
            { professionID = 2912, name = "Midnight" },
            { professionID = 2877, name = "Khaz Algar" },
            { professionID = 2760, name = "Shadowlands" },
            { professionID = 2549, name = "Kul Tiran" },
            { professionID = 2551, name = "Draenor" },
            { professionID = 2553, name = "Cataclysm" },
            { professionID = 2556, name = "Classic" },
        },
        recipes = {
            { recipeID = 1223099, name = "Tranquility Bloom", categoryID = 2190, icon = 7290677 },
            { recipeID = 1223146, name = "Lush Argentleaf", categoryID = 2193, icon = 6658327 },
            { recipeID = 1223138, name = "Argentleaf", categoryID = 2193, icon = 6658327 },
            { recipeID = 1223139, name = "Mana Lily", categoryID = 2194, icon = 7292343 },
            { recipeID = 1225182, name = "Thalassian Phoenix Tail", categoryID = 2196, icon = 6438685 },
            { recipeID = 1265814, name = "Artisan Herbalist's Moxie", categoryID = 2682, icon = 4643975 },
            { recipeID = 1265713, name = "Knowledge", categoryID = 2682, icon = 4374706 },
            { recipeID = 1265710, name = "Quality", categoryID = 2682, icon = 4374706 },
            { recipeID = 1265728, name = "Deftness", categoryID = 2683, icon = 4374706 },
            { recipeID = 1265720, name = "Finesse", categoryID = 2683, icon = 4374706 },
            { recipeID = 1265724, name = "Perception", categoryID = 2683, icon = 4374706 },
            { recipeID = 1265716, name = "Skill", categoryID = 2683, icon = 4374706 },
            { recipeID = 1221181, name = "Empowered Mulch", categoryID = 2189, icon = 7549018 },
            { recipeID = 1221180, name = "Imbued Mulch", categoryID = 2189, icon = 7549016 },
            { recipeID = 1221179, name = "Magical Mulch", categoryID = 2189, icon = 7549017 },
        },
    },
}
