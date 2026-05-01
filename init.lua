local storage = minetest.get_mod_storage()

-- Tables to hold runtime data
local waypoints = {} -- Stores active waypoints for players
local active_cameras = {} -- Tracks players currently in a cinematic

-- Helper function to lock player and make them immortal
local function set_cinematic_state(player, enable)
    if enable then
        -- Save current state to restore later
        local meta = player:get_meta()
        meta:set_string("old_armor", minetest.serialize(player:get_armor_groups()))
        
        -- Make immortal and freeze physics
        player:set_armor_groups({immortal = 1})
        player:set_physics_override({speed = 0, jump = 0, gravity = 0, sneak = false})
    else
        local meta = player:get_meta()
        local old_armor_str = meta:get_string("old_armor")
        if old_armor_str ~= "" then
            player:set_armor_groups(minetest.deserialize(old_armor_str))
        else
            player:set_armor_groups({fleshy = 100}) -- fallback
        end
        player:set_physics_override({speed = 1, jump = 1, gravity = 1, sneak = true})
    end
end

-- Command: /cset <number>
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

-- Command: /csave <project_name>
minetest.register_chatcommand("csave", {
    params = "<project_name>",
    description = "Save current waypoints to server storage",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        if not waypoints[name] or next(waypoints[name]) == nil then 
            return false, "You have no waypoints to save." 
        end
        
        -- Serialize and save to ModStorage
        local data = minetest.serialize(waypoints[name])
        storage:set_string("cine_" .. name .. "_" .. param, data)
        return true, "Project '" .. param .. "' saved successfully."
    end,
})

-- Command: /cload <project_name>
minetest.register_chatcommand("cload", {
    params = "<project_name>",
    description = "Load a cinematic project",
    privs = {server = true},
    func = function(name, param)
        if param == "" then return false, "Provide a project name." end
        
        local data_str = storage:get_string("cine_" .. name .. "_" .. param)
        if data_str == "" then return false, "Project not found." end
        
        waypoints[name] = minetest.deserialize(data_str)
        return true, "Project '" .. param .. "' loaded. Ready to play."
    end,
})

-- Command: /cplay <speed>
minetest.register_chatcommand("cplay", {
    params = "<speed>",
    description = "Play the loaded cinematic. Default speed is 1.",
    privs = {server = true},
    func = function(name, param)
        local player = minetest.get_player_by_name(name)
        if not player then return false, "Player not found." end
        
        if not waypoints[name] or next(waypoints[name]) == nil then
            return false, "No waypoints loaded. Use /cload or /cset."
        end

        local speed = tonumber(param) or 1

        -- Extract and sort points
        local sorted_points = {}
        for k, v in pairs(waypoints[name]) do
            table.insert(sorted_points, {num = k, data = v})
        end
        table.sort(sorted_points, function(a, b) return a.num < b.num end)

        if #sorted_points < 2 then
            return false, "You need at least 2 points to make a cinematic."
        end

        set_cinematic_state(player, true)

        -- Initialize playback state
        active_cameras[name] = {
            points = sorted_points,
            current_idx = 1,
            timer = 0,
            speed = speed
        }
        return true, "Cinematic started..."
    end,
})

-- Command: /cstop
minetest.register_chatcommand("cstop", {
    description = "Stop the cinematic early",
    privs = {server = true},
    func = function(name)
        if not active_cameras[name] then return false, "You aren't playing a cinematic." end
        active_cameras[name] = nil
        local player = minetest.get_player_by_name(name)
        if player then set_cinematic_state(player, false) end
        return true, "Cinematic stopped. Physics and mortality restored."
    end,
})

-- The actual movement logic (Globalstep)
minetest.register_globalstep(function(dtime)
    for name, cam in pairs(active_cameras) do
        local player = minetest.get_player_by_name(name)
        
        -- If player disconnects or nil, clean up to prevent crashes
        if not player then
            active_cameras[name] = nil
        else
            local p1 = cam.points[cam.current_idx].data
            local p2 = cam.points[cam.current_idx + 1].data
            
            -- Calculate distance to adjust time needed to travel
            local dist = vector.distance(p1.pos, p2.pos)
            local time_needed = dist / (5 * cam.speed) -- Adjust '5' for base speed preference
            
            cam.timer = cam.timer + dtime
            local progress = math.min(cam.timer / time_needed, 1)
            
            -- Linear Interpolation (Lerp) for position and look angles
            local current_pos = vector.add(p1.pos, vector.multiply(vector.subtract(p2.pos, p1.pos), progress))
            local current_pitch = p1.pitch + (p2.pitch - p1.pitch) * progress
            local current_yaw = p1.yaw + (p2.yaw - p1.yaw) * progress
            
            player:set_pos(current_pos)
            player:set_look_vertical(current_pitch)
            player:set_look_horizontal(current_yaw)
            
            -- Move to next point if reached
            if progress >= 1 then
                cam.current_idx = cam.current_idx + 1
                cam.timer = 0
                
                -- End of cinematic
                if cam.current_idx >= #cam.points then
                    active_cameras[name] = nil
                    set_cinematic_state(player, false)
                    minetest.chat_send_player(name, "Cinematic finished.")
                end
            end
        end
    end
end)
