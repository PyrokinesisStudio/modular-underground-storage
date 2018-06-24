-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

local GRAPHICS = "__modular-underground-storage__/graphics/"
local TERRAIN = GRAPHICS .. "terrain/asphalt/"
local BASE_CONCRETE = data.raw["tile"]["concrete"]
local BASE_CHEST = data.raw.item["steel-chest"]

local function determineIngredients()
    if data.raw["inserter"]["red-filter-inserter"] then
        return { -- Bob's inserter overhaul is active
            { "red-filter-inserter", 5 },
            { "fast-transport-belt", 5 },
            { "concrete", 10 },
            { "copper-cable", 20 },
        }
    else 
        return {
            { "filter-inserter", 6 },
            { "fast-transport-belt", 5 },
            { "concrete", 10 },
            { "copper-cable", 20 },
        }
    end
end

data:extend({
    {
        type = "tile",
        name = "modular-underground-storage-tile",
        needs_correction = false,
        minable = { hardness = 0.2, mining_time = 0.5, result = "modular-underground-storage-tile" },
        mined_sound = BASE_CONCRETE.mined_sound,
        collision_mask = { "ground-tile" },
        layer = 62, -- concrete
        decorative_removal_probability = 1.0,
        variants = 
        {
            main = 
            {
                { picture = TERRAIN .. "hazard-green/left-1.png", count = 16, size = 1 },
                { picture = TERRAIN .. "hazard-green/left-2.png", count =  4, size = 2, probability = 0.3 },
                { picture = TERRAIN .. "hazard-green/left-4.png", count =  4, size = 4, probability = 0.8 },
            },
            inner_corner = { picture = TERRAIN .. "trans-inner-corner.png", count =  8 },
            outer_corner = { picture = TERRAIN .. "trans-outer-corner.png", count =  8 },
            side =         { picture = TERRAIN .. "trans-side.png",         count =  8 },
            u_transition = { picture = TERRAIN .. "trans-u.png",            count =  8 },
            o_transition = { picture = TERRAIN .. "trans-o.png",            count =  1 },
        },
        walking_sound = BASE_CONCRETE.walking_sound,
        map_color = { r=40, g=49, b=40 },
        ageing = 0,
        vehicle_friction_modifier = 0.6,
        walking_speed_modifier = 1.3,
    },
    {
        type = "item",
        name = "modular-underground-storage-tile",
        icon = GRAPHICS .. "icons/asphalt-hazard-green.png",
        icon_size = 32,
        flags = { "goes-to-quickbar" },
        group = BASE_CHEST.group,
        subgroup = BASE_CHEST.subgroup,
        order = BASE_CHEST.order .. "-a",
        stack_size = 50,
        place_as_tile =
        {
            result = "modular-underground-storage-tile",
            condition_size = 1,
            condition = { "water-tile" }
        }
    },
    {
        type = "recipe",
        name = "modular-underground-storage-tile",
        energy_required = 0.25,
        enabled = false,
        category = "crafting",
        ingredients = determineIngredients(),
        result = "modular-underground-storage-tile",
        result_count = 1,
    }
})

table.insert(data.raw.technology['logistics-2'].effects, { type = "unlock-recipe", recipe = "modular-underground-storage-tile"})