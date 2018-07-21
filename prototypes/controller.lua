require "util"

local function deep_copy(tab)
	local lookup_table = {}
	
	local function _copy(tab)
		if type(tab) ~= "table" then return tab
		elseif tab.__self then return tab
		elseif lookup_table[tab] then return lookup_table[tab]
		end
		
		local new_table = {}
		lookup_table[tab] = new_table
		
		for i, v in pairs(tab) do new_table[_copy(i)] = _copy(v); end
		
		return setmetatable(new_table, getmetatable(tab))
	end
	
	return _copy(tab)
end

local entity = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])

entity.name = "large-constant-combinator"
entity.item_slot_count = 90
entity.minable.result = entity.name

local item = table.deepcopy(data.raw.item["constant-combinator"])
item.name = entity.name
item.place_result = entity.name

local recipe = table.deepcopy(data.raw.recipe["constant-combinator"])
recipe.name = item.name
for _, ingredient in pairs(recipe.ingredients) do
    ingredient[2] = ingredient[2] * 5
end
recipe.result = item.name

data:extend({entity, item, recipe})

table.insert(data.raw.technology['circuit-network'].effects, { type = "unlock-recipe", recipe = recipe.name})