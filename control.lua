-- This Source Code Form is subject to the terms of the Mozilla Public
-- License, v. 2.0. If a copy of the MPL was not distributed with this
-- file, You can obtain one at http://mozilla.org/MPL/2.0/.

local perSurface = {}
local gui = nil

local MOD = "modular-underground-storage"
local TILE = "modular-underground-storage-tile"
local TILE_STACK = { name = TILE }

local ITEM_MAX_SOURCE = {}
ITEM_MAX_SOURCE["constant-combinator"] = true
ITEM_MAX_SOURCE["large-constant-combinator"] = true

local LOADERS = {}
LOADERS["deadlock-loader-1"] = function(patch) return patch.loaders end
LOADERS["deadlock-loader-2"] = LOADERS["deadlock-loader-1"]
LOADERS["deadlock-loader-3"] = LOADERS["deadlock-loader-1"]
LOADERS["deadlock-loader-4"] = LOADERS["deadlock-loader-1"]
LOADERS["deadlock-loader-5"] = LOADERS["deadlock-loader-1"]

LOADERS["constant-combinator"] = function(patch) return patch.scanners end
LOADERS["large-constant-combinator"] = LOADERS["constant-combinator"]
LOADERS["logistic-chest-buffer"] = function(patch) return patch.outputChests end
LOADERS["logistic-chest-requester"] = LOADERS["logistic-chest-buffer"]
LOADERS["steel-chest"] = function(patch) return patch.inputChests end
LOADERS["infinity-chest"] = LOADERS["steel-chest"]
LOADERS["logistic-chest-storage"] = LOADERS["steel-chest"]

-- Storage Energistics Mod
LOADERS["entity_se_requester_chest"] = LOADERS["logistic-chest-buffer"]
LOADERS["entity_se_interface_chest"] = LOADERS["steel-chest"]
LOADERS["entity_se_chest_mk1"] = LOADERS["steel-chest"]
LOADERS["entity_se_chest_mk2"] = LOADERS["steel-chest"]

-- This code uses positions as table keys.
-- Because Lua compares tables by their reference only that means positions have to be encoded as numbers.
-- Factorio runs scripts in Lua 5.2 which means numbers are float64.
-- A float holds up to 52 significant bits so use half of them for the y coordinate.
-- Lua 5.2 has no bit shift operations so we have to fall back to multiplication.
local Y_SHIFT = 2^26
local Y_SHIFT_HALF = Y_SHIFT / 2

-- naming rule: things named "pos" work with encoded positions, those named "position" work with structured positions

local function toPos(x, y)
    assert(x > -Y_SHIFT_HALF and x < Y_SHIFT_HALF, "x position cannot be encoded")
    assert(y > -Y_SHIFT_HALF and y < Y_SHIFT_HALF, "y position cannot be encoded")

    -- decoding using division breaks down when encoding produces a negative number
    local px = x < 0 and x + Y_SHIFT or x
    local py = y < 0 and y + Y_SHIFT or y
    return py * Y_SHIFT + px
end

local function toCoords(pos)
    local y = math.floor(pos / Y_SHIFT)
    local x = pos - y * Y_SHIFT
    if y > Y_SHIFT_HALF then y = y - Y_SHIFT end
    if x > Y_SHIFT_HALF then x = x - Y_SHIFT end
    return x, y
end

local function encodePos(position)
    return toPos(position.x, position.y)
end

local function decodePos(pos)
    local x, y = toCoords(pos)
    return { x = x, y = y }
end

local function toPosition(x, y)
    return { x = x, y = y }
end

local function posToString(posOrPosition)
    local x, y
    if posOrPosition == nil then
        return "nil"
    end
    if (type(posOrPosition) == "number") then
        x, y = toCoords(posOrPosition)
    else
        x = posOrPosition.x
        y = posOrPosition.y
    end
    return "(" .. x .. "," .. y .. ")"
end

function player_print(msg)
    for _, p in pairs(game.players) do
        if (msg) then p.print(msg) end
    end
end

local function perSurfaceData(surface, createIfNecessary)
    local surfaceData = perSurface[surface.index]
    if not surfaceData then
        surfaceData = {
            next_id = 1,
            patches = {},
            lookup = {}, 
        }
        if createIfNecessary then 
            perSurface[surface.index] = surfaceData
        end
    end
    return surfaceData
end

local Storage = {}
local Patch = {}

Storage.init =  function()
    if not global.perSurface then
        global.perSurface = {}
    end
    perSurface = global.perSurface
end

local N  = defines.direction.north
local E  = defines.direction.east
local S  = defines.direction.south
local W  = defines.direction.west
local NW = defines.direction.northwest
local NE = defines.direction.northeast
local SW = defines.direction.southwest
local SE = defines.direction.southeast

local DIR = defines.direction

local DIR_CARDINAL = {}
DIR_CARDINAL[N] = { 0,-1}
DIR_CARDINAL[E] = { 1, 0}
DIR_CARDINAL[S] = { 0, 1}
DIR_CARDINAL[W] = {-1, 0}

local DIR_ORDINAL = {}
DIR_ORDINAL[NE] = { 1,-1}
DIR_ORDINAL[SE] = { 1, 1}
DIR_ORDINAL[SW] = {-1, 1}
DIR_ORDINAL[NW] = {-1,-1}

local function iterAdjacentStorageTiles(surface, centerPos, directions)
    local px, py = toCoords(centerPos)
    local iter, iterState, iterVar = pairs(directions)

    return function()
        while true do
            local dir, offsets = iter(iterState, iterVar)
            if dir == nil then return nil end
            iterVar = dir

            local x = px + offsets[1]
            local y = py + offsets[2]
            if surface.get_tile(x,y).name == TILE then 
                return dir, toPos(x,y)
            end
        end
    end
end

local function mapAdjacentStorageTiles(surface, centerPos, directions)
    local px, py = toCoords(centerPos)
    local result = {}

    for dir, offsets in pairs(directions) do
        local x, y = px + offsets[1], py + offsets[2]
        if surface.get_tile(x,y).name == TILE then
            result[dir] = toPos(x,y)
        end
    end

    return result
end

local function mightBeSplit(surface, pos)
    local disconnected = 0
    local cardinals = mapAdjacentStorageTiles(surface, pos, DIR_CARDINAL)
    local ordinals = mapAdjacentStorageTiles(surface, pos, DIR_ORDINAL)

    if cardinals[N] and not ((ordinals[NW] and cardinals[W]) or (ordinals[NE] and cardinals[E])) then disconnected = disconnected + 1 end
    if cardinals[E] and not ((ordinals[NE] and cardinals[N]) or (ordinals[SE] and cardinals[S])) then disconnected = disconnected + 1 end
    if cardinals[W] and not ((ordinals[NW] and cardinals[N]) or (ordinals[SW] and cardinals[S])) then disconnected = disconnected + 1 end
    if cardinals[S] and not ((ordinals[SW] and cardinals[W]) or (ordinals[SE] and cardinals[E])) then disconnected = disconnected + 1 end

    return disconnected > 1
end

Patch.create = function()
    return {
        tiles = {}, -- pos -> true
        tileCount = 0,
        items = {}, -- item.name -> count
        itemCount = 0,
        itemMaxima = {},
        defaulItemMaximum = -1,
        loaders = {},
        scanners = {},
        outputChests = {},
        inputChests = {},
    }
end

Storage.newTile = function(surface, pos)
    local surfaceData = perSurfaceData(surface, true)

    local lastPatch = nil
    for direction, adjacentPos in iterAdjacentStorageTiles(surface, pos, DIR_CARDINAL) do
        local patch = surfaceData.lookup[adjacentPos]
        if patch then 
            if not lastPatch then
                Storage.addToPatch(surfaceData, patch, adjacentPos)
                lastPatch = patch
            elseif lastPatch.id ~= patch.id then
                lastPatch = Storage.mergePatches(surfaceData, patch, lastPatch)
            end
        else
            -- loose tile, this only happens when the tile cursor is larger than 1x1
            if lastPatch then
                Storage.addToPatch(surfaceData, lastPatch, adjacentPos)
            else
                lastPatch = Storage.newPatch(surfaceData, adjacentPos)
            end
        end
    end

    if lastPatch then
        Storage.addToPatch(surfaceData, lastPatch, pos)
    else
        lastPatch = Storage.newPatch(surfaceData, pos)
    end

    local x, y = toCoords(pos)
    for _, entity in pairs(surface.find_entities({{x,y},{x+1,y+1}})) do
        local accessor = LOADERS[entity.name]
        if accessor then
            accessor(lastPatch)[pos] = entity
        end
    end
end

Storage.newPatch = function(surfaceData, pos)
    local newPatch = Patch.create()
    newPatch.id = surfaceData.next_id
    newPatch.tiles[pos] = true
    newPatch.tileCount = 1
    surfaceData.next_id = surfaceData.next_id + 1
    surfaceData.patches[newPatch.id] = newPatch
    surfaceData.lookup[pos] = newPatch

    return newPatch
end

Storage.addToPatch = function(surfaceData, patch, pos)
    if not patch.tiles[pos] then
        patch.tiles[pos] = true
        patch.tileCount = patch.tileCount + 1
    end
    surfaceData.lookup[pos] = patch
end

Storage.removeFromPatch = function(surfaceData, patch, pos)
    if patch.tiles[pos] then
        patch.tiles[pos] = nil
        patch.tileCount = patch.tileCount - 1
        surfaceData.lookup[pos] = nil
        patch.loaders[pos] = nil
        patch.scanners[pos] = nil
        patch.inputChests[pos] = nil
        patch.outputChests[pos] = nil
    end
end

Storage.mergePatches = function(surfaceData, patch1, patch2)
    local from, into
    if patch1.tileCount < patch2.tileCount then
        from = patch1
        into = patch2
    else
        from = patch2
        into = patch1
    end

    for pos, _ in pairs(from.tiles) do
        Storage.addToPatch(surfaceData, into, pos)
    end

    for name, count in pairs(from.items) do
        local storedCount = into.items[name]
        if not storedCount then
            into.items[name] = count
        else
            into.items[name] = storedCount + count
        end
    end
    into.itemCount = into.itemCount + from.itemCount

    for pos, entity in pairs(from.loaders) do
        into.loaders[pos] = entity
    end
    for pos, entity in pairs(from.scanners) do
        into.scanners[pos] = entity
    end
    for pos, entity in pairs(from.inputChests) do
        into.inputChests[pos] = entity
    end
    for pos, entity in pairs(from.outputChests) do
        into.outputChests[pos] = entity
    end

    Storage.updateItemMaxima(surfaceData, into)

    surfaceData.patches[from.id] = nil

    return into
end

Storage.removeTile = function(surface, pos)
    local surfaceData = perSurfaceData(surface, false)
    if not surfaceData then return end
    
    local patch = surfaceData.lookup[pos]
    if not patch then return end

    -- Removing the last tile while there are stored items would destroy those items
    if patch.tileCount == 1 and next(patch.items) then 
        return false
    end

    Storage.removeFromPatch(surfaceData, patch, pos)

    if not next(patch.tiles) then
        -- dissolve empty patch
        surfaceData.patches[patch.id] = nil
        -- surfaceData.lookup cannot have references when tiles is empty

    elseif mightBeSplit(surface, pos) then
        Storage.splitIfNecessary(surfaceData, patch)
    end

    return true
end

Storage.isTileRemovable = function(surface, pos)
    -- TODO this is hard to decide without actually doing it
    -- for now just allow it here and deny it later in removeTile()
    -- if that would completely destroy a patch that still has items

    -- implementing this would allow to unmark tiles marked for deconstruction
    -- if that would reduce the capacity of the patch below the stored item count
    return true
end

local function floodFill(sourcePatch, fill, x, y)
    for dir, offsets in pairs(DIR_CARDINAL) do
        local dx, dy = x + offsets[1], y + offsets[2]
        local dpos = toPos(dx, dy)
        if sourcePatch.tiles[dpos] and not fill.tiles[dpos] then
            fill.tiles[dpos] = true
            fill.tileCount = fill.tileCount + 1
            floodFill(sourcePatch, fill, dx, dy)
        end
    end
end

Storage.splitIfNecessary = function(surfaceData, patch)
    local maxTileCount = -1
    local largestPatch = nil

    for i = 1, 4 do -- removing one tile can produce at most 4 split patches
        local pos = next(patch.tiles)
        local newPatch = Patch.create()
        newPatch.tiles[pos] = true
        newPatch.tileCount = 1

        local x, y = toCoords(pos)
        floodFill(patch, newPatch, x, y)

        -- remaining tiles in patch are contiguous, the algorithm is done
        if newPatch.tileCount == patch.tileCount then break end

        -- found split, move data to it and make it permanent
        newPatch.id = surfaceData.next_id
        surfaceData.patches[newPatch.id] = newPatch
        surfaceData.next_id = surfaceData.next_id + 1

        for pos, _ in pairs(newPatch.tiles) do
            patch.tiles[pos] = nil
            patch.tileCount = patch.tileCount - 1
            surfaceData.lookup[pos] = newPatch

            if patch.loaders[pos] then
                newPatch.loaders[pos] = patch.loaders[pos]
                patch.loaders[pos] = nil
            end
            if patch.scanners[pos] then
                newPatch.scanners[pos] = patch.scanners[pos]
                patch.scanners[pos] = nil
            end
            if patch.inputChests[pos] then
                newPatch.inputChests[pos] = patch.inputChests[pos]
                patch.inputChests[pos] = nil
            end
            if patch.outputChests[pos] then
                newPatch.outputChests[pos] = patch.outputChests[pos]
                patch.outputChests[pos] = nil
            end

            Storage.updateItemMaxima(surfaceData, newPatch)
        end

        if newPatch.tileCount > maxTileCount then
            largestPatch = newPatch
            maxTileCount = newPatch.tileCount
        end
    end

    if largestPatch then -- there was at least one split
        Storage.updateItemMaxima(surfaceData, patch)

        -- move all stored items to the largest patch, even when they don't all fit
        if maxTileCount > patch.tileCount then
            largestPatch.items = patch.items
            largestPatch.itemCount = patch.itemCount
            patch.items = {}
            patch.itemCount = 0
        end
    end
end

Storage.updateItemMaxima = function(surfaceData, patch)
    patch.itemMaxima = {}
    patch.defaultItemMaximum = -1

    for _, entity in pairs(patch.scanners) do
        local control = entity.valid and entity.get_control_behavior()
        -- enabled combinators have their signals overriden with the storage-patche's content
        -- so only disabled combinators are used to control the item maxima
        if control and not control.enabled then
            for _, param in pairs(control.parameters.parameters) do
                local signal = param.signal
                if signal.type == "item" and signal.name then
                    patch.itemMaxima[signal.name] = param.count
                elseif signal.type == "virtual" and signal.name == "signal-M" then
                    patch.defaultItemMaximum = param.count
                end
            end
        end
    end
end

function doOutput(patch, output, filter, linedef)
    local item = output.get_filter(filter)
    if not item then return end

    local count = patch.items[item]
    if not count then return end

    local line = output.get_transport_line(linedef)
    if not line.insert_at_back({name = item}) then return end

    count = count - 1
    if count > 0 then
        patch.items[item] = count
    else
        patch.items[item] = nil
    end
    patch.itemCount = patch.itemCount - 1
end

local CHEST_INVENTORY = defines.inventory.chest

function doOutputChest(patch, chest)
    local inventory = chest.get_inventory(CHEST_INVENTORY)
    local content = inventory.get_contents()

    for slotIndex = 1, 12 do
        local request = chest.get_request_slot(slotIndex)
        if request then
            local item = request.name
            local availableCount = patch.items[item] or 0
            local transferCount = math.min(availableCount, request.count - (content[item] or 0))

            if transferCount > 0 then
                transferCount = inventory.insert({name = item, count = transferCount})
                if transferCount > 0 then
                    local remainingCount = availableCount - transferCount
                    if remainingCount > 0 then
                        patch.items[item] = remainingCount
                    else
                        patch.items[item] = nil
                    end
                    patch.itemCount = patch.itemCount - transferCount
                end
            end
        end
    end
end

function doInputChest(patch, chest, maxItems)
    local inventory = chest.get_inventory(CHEST_INVENTORY)
    local content = inventory.get_contents()
    local defaultMax = patch.defaultItemMaximum or -1

    for item, count in pairs(content) do
        local transferCount = count

        local storedCount = patch.items[item] or 0
        local itemMax = patch.itemMaxima[item]
        if not itemMax then 
            itemMax = defaultMax
        end
        if itemMax >= 0 then
            transferCount = math.min(transferCount, itemMax - storedCount)
        end

        transferCount = math.min(transferCount, maxItems - patch.itemCount)

        if transferCount > 0 then
            transferCount = inventory.remove({ name = item, count = transferCount})
            if transferCount > 0 then
                patch.items[item] = storedCount + transferCount
                patch.itemCount = patch.itemCount + transferCount
            end
        end
    end
end

function doInput(patch, input, maxItems, linedef)
    if patch.itemCount >= maxItems then return end

    local line = input.get_transport_line(linedef)
    local frontItem = #line > 0 and line[1]
    if not frontItem then return end

    local item = frontItem.name

    local count = patch.items[item] or 0
    local itemMax = patch.itemMaxima[item]
    local defaultMax = patch.defaultItemMaximum or -1

    if (itemMax 
            and count >= itemMax) 
    or 
       ((not itemMax) 
            and defaultMax >= 0 
            and count >= defaultMax)
    then return end

    local removed = line.remove_item({name = item})
    if removed < 1 then return end

    patch.items[item] = count + 1
    patch.itemCount = patch.itemCount + 1
end

local LEFT_LINE = defines.transport_line.left_line
local RIGHT_LINE = defines.transport_line.right_line

function tick(event)
    local isCircuitNetworkUpdateTick = (event.tick % settings.global["modular-underground-storage-signal-update-rate"].value == 0)
    local tileCapacity = settings.global["modular-underground-storage-tile-capacity"].value

    for _, surfaceData in pairs(perSurface) do
        for _, patch in pairs(surfaceData.patches) do
            -- TODO remove dev migration code
            if not patch.inputChests then patch.inputChests = {} end
            if not patch.outputChests then patch.outputChests = {} end

            if isCircuitNetworkUpdateTick then
                for _, chest in pairs(patch.outputChests) do
                    doOutputChest(patch, chest)
                end
            end

            for _, output in pairs(patch.loaders) do
                if output.valid and output.loader_type == "output" then
                    doOutput(patch, output, 1, LEFT_LINE)
                    doOutput(patch, output, 2, RIGHT_LINE)
                end
            end

            local maxItems = patch.tileCount * tileCapacity

            if isCircuitNetworkUpdateTick then
                for _, chest in pairs(patch.inputChests) do
                    doInputChest(patch, chest, maxItems)
                end
            end

            for _, input in pairs(patch.loaders) do
                if input.valid and input.loader_type == "input" then
                    doInput(patch, input, maxItems, LEFT_LINE)
                    doInput(patch, input, maxItems, RIGHT_LINE)
                end
            end

            if isCircuitNetworkUpdateTick and next(patch.scanners) then
                local spaceLeft = math.max(maxItems - patch.itemCount, 0)
                local signals = {}
                signals[1] = {index = 1, signal = {type = "virtual",name = "signal-F"}, count = spaceLeft}
                signals[2] = {index = 2, signal = {type = "virtual",name = "signal-T"}, count = maxItems }
    
                local index = 3
                for item, count in pairs(patch.items) do
                    signals[index] = {index = index, signal = {type = "item", name = item}, count = count}
                    index = index+1
                end

                truncatedSignals = {}

                for spos, scanner in pairs(patch.scanners) do
                    if scanner.valid then
                        local control = scanner.get_control_behavior()

                        local maxSignals = control.signals_count
                        local params
                        if #signals > maxSignals then
                            params = truncatedSignals[maxSignals]
                            if not params then
                                params = {}
                                for i=1,maxSignals do
                                    params[i] = signals[i]
                                end
                                truncatedSignals[maxSignals] = params
                            end
                        else
                            params = signals
                        end

                        if not control then 
                            player_print("no control: " .. scanner.name .. " " .. posToString(pos))
                        elseif control.enabled then
                            control.parameters = {parameters = params}
                        end
                    end
                end
            end
        end
    end
end

function player_or_robot(event)
    local actor, surface
    if event.robot then
        actor = event.robot
        surface = actor.surface
    else
        actor = game.players[event.player_index]
        surface = game.surfaces[event.surface_index]
    end

    return actor, surface
end

function marked(event)
    local entity = event.entity

    if "deconstructible-tile-proxy" == entity.type then
        local surface = entity.surface
        if surface.get_tile(entity.position).name == TILE and not Storage.isTileRemovable(surface, encodePos(entity.position)) then
            entity.cancel_deconstruction("player")
        end
    end
end

function tile_mined(event)
    local actor, surface = player_or_robot(event)

    for _, minedTile in pairs(event.tiles) do
        if minedTile.old_tile.name == TILE and not Storage.removeTile(surface, encodePos(minedTile.position)) then
            actor.remove_item(TILE_STACK)
            surface.set_tiles({{ name = TILE, position = minedTile.position}})
        end
    end
end

function tile_built(event) 
    local actor, surface = player_or_robot(event)

    if event.item.place_as_tile_result.result.name == TILE then
        for _, replacedTile in pairs(event.tiles) do
            Storage.newTile(surface, encodePos(replacedTile.position))
        end
    end
end

function getPatchUnderEntity(entity)
    local x = math.floor(entity.position.x)
    local y = math.floor(entity.position.y)
    if entity.surface.get_tile(x,y).name ~= TILE then return end

    local surfaceData = perSurfaceData(entity.surface, false)
    if not surfaceData then return end

    local pos = toPos(x,y)
    local patch = surfaceData.lookup[pos]
    if not patch then return end

    return surfaceData, patch, pos
end

function entity_built(event)
    local entity = event.created_entity
    
    local accessor = LOADERS[entity.name]
    if accessor then 
        local surfaceData, patch, pos = getPatchUnderEntity(entity)
        if surfaceData then
            accessor(patch)[pos] = entity
        end
    end
end

function entity_mined(event)
    local entity = event.entity
    
    local accessor = LOADERS[entity.name]
    if accessor then 
        local surfaceData, patch, pos = getPatchUnderEntity(entity)
        if surfaceData then
            accessor(patch)[pos] = nil
            if ITEM_MAX_SOURCE[entity.name] then
                Storage.updateItemMaxima(surfaceData, patch)
            end
        end
    end
end

function gui_closed(event)
    local entity = event.entity
    if not (entity and entity.valid and ITEM_MAX_SOURCE[entity.name]) then return end

    local surfaceData, patch, pos = getPatchUnderEntity(entity)
    if not surfaceData then return end

    Storage.updateItemMaxima(surfaceData, patch)
end

script.on_init(Storage.init)
script.on_load(Storage.init)
script.on_event(defines.events.on_surface_deleted, function() perSurface[event.surface_index] = nil end)

script.on_event(defines.events.on_marked_for_deconstruction, marked)

script.on_event(defines.events.on_robot_mined_tile, tile_mined)
script.on_event(defines.events.on_player_mined_tile, tile_mined)
script.on_event(defines.events.on_robot_built_tile, tile_built)
script.on_event(defines.events.on_player_built_tile, tile_built)

script.on_event(defines.events.on_built_entity, entity_built)
script.on_event(defines.events.on_robot_built_entity, entity_built)
script.on_event(defines.events.on_player_mined_entity, entity_mined)
script.on_event(defines.events.on_robot_mined_entity, entity_mined)

script.on_event(defines.events.on_tick, tick)
script.on_event(defines.events.on_gui_closed, gui_closed)

local open_gui = function(event)
    if true or gui then return end

    local player = game.players[event.player_index]
    local entity = player.selected
    if not entity then return end

    local surfaceData, patch, pos = getPatchUnderEntity(entity)
    if not surfaceData then return end

    local frame = player.gui.center.add({type = "frame", name="mus-patch-config", caption = "Patch " .. patch.id, direction = "vertical" })
    frame.style.minimal_width = 400
    gui = frame

    local top = gui.add({type = "flow", name="mus-patch-config-top", direction = "horizontal" })
    
    local preview = top.add({type = "entity-preview", name ="mus-patch-config-preview"})
    preview.entity = entity

    local signal_page = top.add({type = "slider", name ="mus-patch-config-page", minimum_value = 1, maximum_value = 100, value = 1})
    local signal_page_box = top.add({type = "text-box", name ="mus-patch-config-page-box", text = 1})
    signal_page_box.style.minimal_width = 50

    local middle = gui.add({type = "flow", name="mus-patch-config-middle", direction = "horizontal" })
    middle.style.top_padding = 0
    middle.style.right_padding = 0
    middle.style.bottom_padding = 0
    middle.style.left_padding = 0

    local e
    e = middle.add({type = "choose-elem-button", name ="mus-patch-config-elem-1", elem_type = "item"})
    e.style.top_padding = 0
    e.style.right_padding = 0
    e.style.bottom_padding = 0
    e.style.left_padding = 0

    e = middle.add({type = "choose-elem-button", name ="mus-patch-config-elem-2", elem_type = "item"})
    e.style.top_padding = 0
    e.style.right_padding = 0
    e.style.bottom_padding = 0
    e.style.left_padding = 0

    gui.focus()
end

local close_gui = function(event) 
    if gui then 
        gui.destroy() 
        gui = nil
    end
end

script.on_event("underground-storage-gui-open", open_gui)
script.on_event("underground-storage-gui-close", close_gui)
script.on_event("underground-storage-toggle-menu", close_gui)

local texts = {}

function hide(paramTable)
    for _, text in ipairs(texts) do
        text.active = true
    end
    texts = {}
end

function show(paramTable)
    if #texts > 0 then hide() end

    local surface = game.players[paramTable.player_index].surface
    local perSurface = perSurfaceData(surface, false)
    if not perSurface then return end

    for _, patch in pairs(perSurface.patches) do
        local patchId = tostring(patch.id)
        for tilePos, _ in pairs(patch.tiles) do
            local x, y = toCoords(tilePos)
            local text = surface.create_entity({name="flying-text", position=toPosition(x + 0.3, y + 0.3), text=patchId})
            table.insert(texts, text)
            text.active = false
        end
    end
end

function dump(paramTable) 
    local player = game.players[paramTable.player_index]
    local surface = player.surface
    local surfaceData = perSurfaceData(surface, false)
    if not surfaceData then return end

    for _, patch in pairs(surfaceData.patches) do
        player_print("#" .. patch.id .. ": " .. patch.tileCount .. " tiles, " .. patch.itemCount .. " items" .. ", max " .. patch.tileCount * settings.global["modular-underground-storage-tile-capacity"].value)
        
        local items = "   items: "
        for item, count in pairs(patch.items) do
            items = items .. item .. "=" .. count .. ", "
        end
        player_print(items)

        local inputs = "   inputs: "
        for pos, entity in pairs(patch.loaders) do
            if entity.loader_type == "input" then
                inputs = inputs .. posToString(pos) .. ", "
            end
        end
        player_print(inputs)

        local outputs = "   outputs: "
        for pos, entity in pairs(patch.loaders) do
            if entity.loader_type == "output" then
                outputs = outputs .. posToString(pos) .. ", "
            end
        end
        player_print(outputs)

        local inChests = "   input-chests: "
        for pos, entity in pairs(patch.inputChests) do
            inChests = inChests .. posToString(pos) .. ", "
        end
        player_print(inChests)

        local outChests = "   output-chests: "
        for pos, entity in pairs(patch.outputChests) do
            outChests = outChests .. posToString(pos) .. ", "
        end
        player_print(outChests)
    end
end

commands.add_command("mus",
"Subcommands 'show' and 'hide' overlay tiles with the storage patch id. " ..
"'dump' prints statistics about all the patches on the player's surface.",
function(paramTable)
    local cmd = paramTable.parameter
    if cmd == "show" then show(paramTable)
    elseif cmd == "hide" then hide(paramTable)
    elseif cmd == "dump" then dump(paramTable)
    else
        game.players[paramTable.player_index].print("unknown subcommand " .. cmd)
    end
end)
