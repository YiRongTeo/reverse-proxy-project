--[[
  ZDNS junction module.

  URI pattern:
    /zdns/{session_id}/...

  Valkey value examples:
    "https://10.10.10.20"
    {"url":"https://10.10.10.20:443","device_type":"zdns","host":"10.10.10.20"}
]]

local junction_device = require "lib.junction_device"

return junction_device.new({
    name = "zdns",
    junction_prefix = "/zdns",
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-CSRF-Token",
        "X-Auth-Token",
    },
})
