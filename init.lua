local storage = minetest.get_mod_storage()

local waypoints = {} 
local active_cameras = {} 

-- (Keep the math functions the same as before)
local function catmull_rom(p0, p1, p2, p3, t)
    local t2 = t * t
    local t3 = t2 * t
    return 0.5 * (
        (2 * p1) +
        (-p0 + p2) * t +
        (2 * p0 - 5 * p1 + 4 * p2 - p3) * t2 +
        (-p0 + 3 * p1 - 3 * p2 + p3) * t3
    )
end

local function normalize_angle(base, target)
    local diff = (target - base) % (math.pi * 2)
    if diff > math.pi then diff = diff - (math.pi * 2) end
    return base + diff
end

local function set_cinematic_state(player, enable)
    if enable then
        local meta = player:get_meta()
        meta:set_string("old_armor", minetest.serialize(player:get_armor_groups()))
        player:set_armor_groups({immortal = 1})
        player:set_physics_override({speed = 0, jump = 0, gravity = 0, sneak = false})
    else
        local meta = player:get_meta()
        local old_armor_str = meta:get_string("old_armor")
        if old_armor_str ~= "" then
            player:set_armor_groups(minetest.deserialize(old_armor_str))
        else
            player:set_armor_groups({fleshy = 100})
        end
        player:set_physics_override({speed = 1, jump = 1, gravity = 1, sneak = true})
    end
end

-- === UPDATED COMMANDS ===

-- Clear memory so you can start a NEW project
minetest.register_chatcommand("cclear", {
    description = "Clear current unsaved waypoints from memory",
    privs = {server = true},
    func = function(name)
        waypoints[name] = {}
        return true, "Waypoints cleared. You have a blank slate now."
    end,
})

minetest.register_chatcommand("cset", {
    params = "<number>",
    description = "Set a cinematic waypoint",
    privs = {server = true},
    func = function(name, param)
        local num = tonumber(param)
        if not num then return false, "You need to provide a number!" end
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end

        waypoints[name] = waypoints[name] or {}
        waypoints[name][num] = {
            pos = player:get_pos(),
            pitch = player:get_look_vertical(),
            yaw = player:get_look_horizontal()
        }
        return true, "Waypoint " .. num .. " logged."
    end,
})

minetest.register_chatcommand("csave", {
    params = "<project_name>",
    description = "Save waypoints and CLEAR memory",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        if not waypoints[name] or next(waypoints[name]) == nil then 
            return false, "Nothing to save!" 
        end
        
        local data = minetest.serialize(waypoints[name])
        storage:set_string("cine_" .. name .. "_" .. param, data)
        
        -- THE FIX: Wipe the local table after saving so Project B doesn't 
        -- include Project A's points.
        waypoints[name] = {} 
        
        return true, "Project '" .. param .. "' saved to server. Memory cleared for next project."
    end,
})

minetest.register_chatcommand("cload", {
    params = "<project_name>",
    description = "Load a project into memory",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        local data_str = storage:get_string("cine_" .. name .. "_" .. param)
        if data_str == "" then return false, "Project not found." end
        
        -- This overwrites whatever is currently in memory
        waypoints[name] = minetest.deserialize(data_str)
        return true, "Project '" .. param .. "' loaded. Use /cplay to start."
    end,
})

-- (Keep /cplay, /cstop, and the globalstep logic from the previous version)
-- [Redacted for brevity, but use the same Globalstep with Catmull-Rom logic]
