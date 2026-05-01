local storage = minetest.get_mod_storage()

local waypoints = {} 
local active_cameras = {} 

-- === MATH FUNCTIONS FOR SMOOTHING ===

-- Calculates a Catmull-Rom spline for smooth curving
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

-- Fixes angles so the camera takes the shortest rotational path (prevents wild spinning)
local function normalize_angle(base, target)
    local diff = (target - base) % (math.pi * 2)
    if diff > math.pi then 
        diff = diff - (math.pi * 2) 
    end
    return base + diff
end

-- === PLAYER STATE HANDLING ===

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

-- === CHAT COMMANDS ===

minetest.register_chatcommand("cset", {
    params = "<number>",
    description = "Set a cinematic waypoint (e.g. /cset 1)",
    privs = {server = true},
    func = function(name, param)
        local num = tonumber(param)
        if not num then return false, "You need to provide a valid number!" end
        
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
    description = "Save current waypoints",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        if not waypoints[name] or next(waypoints[name]) == nil then 
            return false, "No waypoints to save." 
        end
        
        local data = minetest.serialize(waypoints[name])
        storage:set_string("cine_" .. name .. "_" .. param, data)
        return true, "Project '" .. param .. "' saved."
    end,
})

minetest.register_chatcommand("cload", {
    params = "<project_name>",
    description = "Load a cinematic project",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        
        local data_str = storage:get_string("cine_" .. name .. "_" .. param)
        if data_str == "" then return false, "Project not found." end
        
        waypoints[name] = minetest.deserialize(data_str)
        return true, "Project '" .. param .. "' loaded."
    end,
})

minetest.register_chatcommand("cplay", {
    params = "<speed>",
    description = "Play cinematic. Default speed is 1.",
    privs = {server = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        
        if not waypoints[name] or next(waypoints[name]) == nil then
            return false, "No waypoints loaded."
        end

        local speed = tonumber(param) or 1
        local sorted_points = {}
        for k, v in pairs(waypoints[name]) do
            table.insert(sorted_points, {num = k, data = v})
        end
        table.sort(sorted_points, function(a, b) return a.num < b.num end)

        if #sorted_points < 2 then
            return false, "You need at least 2 points."
        end

        set_cinematic_state(player, true)

        active_cameras[name] = {
            points = sorted_points,
            current_idx = 1,
            timer = 0,
            speed = speed
        }
        return true, "Cinematic started..."
    end,
})

minetest.register_chatcommand("cstop", {
    description = "Stop the cinematic early",
    privs = {server = true},
    func = function(name)
        if not active_cameras[name] then return false, "Not playing." end
        active_cameras[name] = nil
        local player = minetest.get_player_by_name(name)
        if player then set_cinematic_state(player, false) end
        return true, "Cinematic stopped."
    end,
})

-- === THE SMOOTH MOVEMENT LOGIC ===

minetest.register_globalstep(function(dtime)
    for name, cam in pairs(active_cameras) do
        local player = minetest.get_player_by_name(name)
        
        if not player then
            active_cameras[name] = nil
        else
            -- Grab 4 points for the Catmull-Rom Spline
            -- If we are at the edge of the array, duplicate the nearest point
            local idx = cam.current_idx
            local p0 = cam.points[math.max(idx - 1, 1)].data
            local p1 = cam.points[idx].data
            local p2 = cam.points[idx + 1].data
            local p3 = cam.points[math.min(idx + 2, #cam.points)].data
            
            -- Calculate time needed based on distance
            local dist = vector.distance(p1.pos, p2.pos)
            local time_needed = dist / (5 * cam.speed)
            
            cam.timer = cam.timer + dtime
            local t = math.min(cam.timer / time_needed, 1)
            
            -- Apply Spline to Position
            local current_pos = {
                x = catmull_rom(p0.pos.x, p1.pos.x, p2.pos.x, p3.pos.x, t),
                y = catmull_rom(p0.pos.y, p1.pos.y, p2.pos.y, p3.pos.y, t),
                z = catmull_rom(p0.pos.z, p1.pos.z, p2.pos.z, p3.pos.z, t)
            }
            
            -- Normalize angles relative to P1 to prevent 360 spins during interpolation
            local y0 = normalize_angle(p1.yaw, p0.yaw)
            local y1 = p1.yaw
            local y2 = normalize_angle(p1.yaw, p2.yaw)
            local y3 = normalize_angle(p2.yaw, p3.yaw)
            
            local pt0 = normalize_angle(p1.pitch, p0.pitch)
            local pt1 = p1.pitch
            local pt2 = normalize_angle(p1.pitch, p2.pitch)
            local pt3 = normalize_angle(p2.pitch, p3.pitch)

            -- Apply Spline to Look Angles
            local current_yaw = catmull_rom(y0, y1, y2, y3, t)
            local current_pitch = catmull_rom(pt0, pt1, pt2, pt3, t)
            
            player:set_pos(current_pos)
            player:set_look_vertical(current_pitch)
            player:set_look_horizontal(current_yaw)
            
            -- Move to next point
            if t >= 1 then
                cam.current_idx = cam.current_idx + 1
                cam.timer = 0
                
                if cam.current_idx >= #cam.points then
                    active_cameras[name] = nil
                    set_cinematic_state(player, false)
                    minetest.chat_send_player(name, "Cinematic finished.")
                end
            end
        end
    end
end)
