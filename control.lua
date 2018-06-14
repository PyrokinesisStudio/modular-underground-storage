local perSurface = {}

local MOD = "modular-underground-storage"
local TILE = "modular-underground-storage-tile"
local TILE_STACK = { name = TILE }

local LOADERS = {}
LOADERS["deadlock-loader-1"] = true
LOADERS["deadlock-loader-2"] = true
LOADERS["deadlock-loader-3"] = true
LOADERS["deadlock-loader-4"] = true
LOADERS["deadlock-loader-5"] = true

-- This code uses positions as table keys.
-- Because Lua compares tables by their reference only that means positions have to be encoded as numbers.
-- Factorio runs scripts in Lua 5.2 which means numbers are float64.
-- A float holds up to 52 significant bits so use half of them for the y coordinate.
-- Lua 5.2 has no bit shift operations so we have fall back to multiplication.
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
        inputs = {},
        outputs = {},
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
    local undergroundBelt = surface.find_entities_filtered {area={{x,y},{x+1,y+1}}, type="underground-belt"}[1]

    if undergroundBelt then
        Storage.addInputOrOutput(surfaceData, lastPatch, pos, undergroundBelt)
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

    for pos, entity in pairs(from.inputs) do
        into.inputs[pos] = entity
    end
    for pos, entity in pairs(from.outputs) do
        into.outputs[pos] = entity
    end

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

            if patch.inputs[pos] then
                newPatch.inputs[pos] = patch.inputs[pos]
                patch.inputs[pos] = nil
            end

            if patch.outputs[pos] then
                newPatch.outputs[pos] = patch.outputs[pos]
                patch.outputs[pos] = nil
            end
        end

        if newPatch.tileCount > maxTileCount then
            largestPatch = newPatch
            maxTileCount = newPatch.tileCount
        end
    end

    -- move all stored items to the largest patch, even when they don't all fit
    if largestPatch and maxTileCount > patch.tileCount then
        largestPatch.items = patch.items
        largestPatch.itemCount = patch.itemCount
        patch.items = {}
        patch.itemCount = 0
    end
end

local function inputOutput(entity)
    return (entity.valid and entity.type == "loader" and entity.loader_type) or nil
end

Storage.addInputOrOutput = function(surfaceData, patch, pos, entity)
    if (entity.type == "loader") then
        patch.inputs[pos] = entity
    end

    -- recheck all inputs and outputs, snapping might have changed them

    for pos, entity in pairs(patch.inputs) do
        local inOut = inputOutput(entity)
        if inOut == "input" then
            patch.inputs[pos] = entity
            patch.outputs[pos] = nil
        elseif inOut == "output" then
            patch.inputs[pos] = nil
            patch.outputs[pos] = entity
        else
            patch.inputs[pos] = nil
            patch.outputs[pos] = nil
        end
    end
        
    for pos, entity in pairs(patch.inputs) do
        local inOut = inputOutput(entity)
        if inOut == "input" then
            patch.inputs[pos] = entity
            patch.outputs[pos] = nil
        elseif inOut == "output" then
            patch.inputs[pos] = nil
            patch.outputs[pos] = entity
        else
            patch.inputs[pos] = nil
            patch.outputs[pos] = nil
        end
    end
end

function doOutput(patch, output, filter, unfiltered, linedef, tick)
    local item = filter
    if not item and unfiltered then 
        item = next(patch.items)
    end
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

function doInput(patch, input, maxItems, linedef)
    if patch.itemCount >= maxItems then return end

    local line = input.get_transport_line(linedef)

    local frontItem = #line > 0 and line[1]
    if not frontItem then return end

    local item = frontItem.name

    local removed = line.remove_item({name = item})
    if removed < 1 then return end

    local count = patch.items[item]
    if not count then
        patch.items[item] = 1
    else
        patch.items[item] = count + 1
    end
    patch.itemCount = patch.itemCount + 1
end

local LEFT_LINE = defines.transport_line.left_line
local RIGHT_LINE = defines.transport_line.right_line

function tick(event)
    for _, surfaceData in pairs(perSurface) do
        for _, patch in pairs(surfaceData.patches) do
            for _, output in pairs(patch.outputs) do
                if output.valid then
                    local filterL = output.get_filter(1)
                    local filterR = output.get_filter(2)
                    local unfiltered = (not filterL) and (not filterR)

                    doOutput(patch, output, filterL, unfiltered, LEFT_LINE, event.tick)
                    doOutput(patch, output, filterR, unfiltered, RIGHT_LINE, 2)
                end
            end

            local maxItems = patch.tileCount * 2000

            for _, input in pairs(patch.inputs) do
                if input.valid then
                    doInput(patch, input, maxItems, LEFT_LINE)
                    doInput(patch, input, maxItems, RIGHT_LINE)
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

function entity_built(event)
    if event.created_entity.type ~= "underground-belt" then return end

    local actor = player_or_robot(event)
    if actor.surface.get_tile(actor.position).name == TILE then
        surfaceData = perSurfaceData(actor.surface, false)
        Storage.addUndergroundBelt(surfaceData, event.created_entity)
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
    
    if LOADERS[entity.name] then 
        local surfaceData, patch, pos = getPatchUnderEntity(entity)
        if surfaceData then
            Storage.addInputOrOutput(surfaceData, patch, pos, entity)
        end
    end
end

function rotate_entity(event)
    local entity = event.entity

    if LOADERS[entity.name] then 
        local surfaceData, patch, pos = getPatchUnderEntity(entity)
        if surfaceData then
            Storage.addInputOrOutput(surfaceData, patch, pos, entity)
        end
    end
end

script.on_init(Storage.init)
script.on_load(Storage.init)
script.on_event(defines.events.on_surface_deleted, function() data[event.surface_index] = nil end)

script.on_event(defines.events.on_marked_for_deconstruction, marked)

script.on_event(defines.events.on_robot_mined_tile, tile_mined)
script.on_event(defines.events.on_player_mined_tile, tile_mined)
script.on_event(defines.events.on_robot_built_tile, tile_built)
script.on_event(defines.events.on_player_built_tile, tile_built)

script.on_event(defines.events.on_built_entity, entity_built)
script.on_event(defines.events.on_robot_built_entity, entity_built)
script.on_event(defines.events.on_player_rotated_entity, rotate_entity)

script.on_event(defines.events.on_player_mined_entity, entity_mined)
script.on_event(defines.events.on_robot_mined_entity, entity_mined)

script.on_event(defines.events.on_tick, tick)
-- no need to handle mined_entity events, the tick function removes entities that are no longer .valid

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
        player_print("#" .. patch.id .. ": " .. patch.tileCount .. " tiles, " .. patch.itemCount .. " items")
        
        local items = "   items: "
        for item, count in pairs(patch.items) do
            items = items .. item .. "=" .. count .. ", "
        end
        player_print(items)

        local inputs = "   inputs: "
        for pos, entity in pairs(patch.inputs) do
            inputs = inputs .. posToString(pos) .. ", "
        end
        player_print(inputs)

        local outputs = "   outputs: "
        for pos, entity in pairs(patch.outputs) do
            outputs = outputs .. posToString(pos) .. ", "
        end
        player_print(outputs)
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
