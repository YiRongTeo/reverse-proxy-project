--[[
  Template for adding a new device junction.

  Steps:
    1. Copy this file to lua/devices/<device_name>.lua
    2. Add a location block in nginx/conf/junctions.conf
    3. Preload the module in nginx/nginx.conf init_by_lua_block

  Prefer using lib.junction_device.new() as in infoblox.lua / zdns.lua.
]]

local junction_device = require "lib.junction_device"

return junction_device.new({
    name = "example_device",
    junction_prefix = "/example",
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
    },
})
