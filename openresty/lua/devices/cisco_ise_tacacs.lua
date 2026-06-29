--[[
  Cisco ISE (TACACS admin) junction module.

  URI pattern:
    /ise/{session_id}/...

  Valkey value examples:
    "https://10.10.10.30"
    {"url":"https://10.10.10.30:443/admin/","device_type":"cisco_ise_tacacs","host":"10.10.10.30"}

  Tip: set "host" to the ISE FQDN if the appliance redirects using a hostname
  while you connect by IP. Example:
  {"url":"https://10.10.10.30","device_type":"cisco_ise_tacacs","host":"ise.corp.local"}
]]

local junction_device = require "lib.junction_device"

return junction_device.new({
    name = "cisco_ise_tacacs",
    junction_prefix = "/ise",
    max_redirects = 10,
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
