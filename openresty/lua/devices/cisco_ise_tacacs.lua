--[[
  Cisco ISE (TACACS admin) junction module.

  URI pattern:
    /ise/{session_id}/...

  Valkey value examples:
    "https://10.10.10.30"
    {"url":"https://10.10.10.30:443/admin/","device_type":"cisco_ise_tacacs","host":"10.10.10.30"}

  Tip: point the session URL at the ISE admin path if the appliance redirects
  from / to /admin/ on first access.
]]

local junction_device = require "lib.junction_device"

return junction_device.new({
    name = "cisco_ise_tacacs",
    junction_prefix = "/ise",
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-csrf-token",
        "X-CSRF-Token",
        "OWASP_CSRFTOKEN",
    },
})
