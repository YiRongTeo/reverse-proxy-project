--[[
  Infoblox NIOS junction module.

  URI pattern:
    /infoblox/{session_id}/...

  Valkey value examples:
    "https://10.10.10.10"
    {"url":"https://10.10.10.10:443","device_type":"infoblox","host":"10.10.10.10"}
]]

local junction_device = require "lib.junction_device"

return junction_device.new({
    name = "infoblox",
    junction_prefix = "/infoblox",
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-CSRF-Token",
        "IBAP-Auth",
        "IBAP-Session",
    },
})
