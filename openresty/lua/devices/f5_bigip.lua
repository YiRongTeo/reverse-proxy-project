--[[
  F5 BIG-IP Load Balancer junction module.

  URI pattern:
    /f5/{session_id}/...

  Valkey value examples:
    "https://10.10.10.10"
    {"url":"https://10.10.10.10:443","device_type":"f5_bigip","host":"10.10.10.10"}
    {"url":"https://10.10.10.10","device_type":"f5_load_balancer","host":"bigip.corp.local"}

  device_type may be "f5_bigip" or "f5_load_balancer".
  Set host to the F5 management hostname when connecting by IP.
]]

local html_rewrite = require "lib.html_rewrite"
local junction_device = require "lib.junction_device"

local ACCEPTED_DEVICE_TYPES = {
    f5_bigip = true,
    f5_load_balancer = true,
}

local device = junction_device.new({
    name = "f5_bigip",
    junction_prefix = "/f5",
    max_redirects = 10,
    aggressive_absolute_rewrite = true,
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-F5-Auth-Token",
        "X-Auth-Token",
        "X-CSRF-Token",
    },
})

local base_prepare_upstream_headers = device.prepare_upstream_headers

function device.validate_session(session_id, session_data)
    if session_data.device_type and not ACCEPTED_DEVICE_TYPES[session_data.device_type] then
        return false
    end

    return true
end

function device.prepare_upstream_headers(headers, ctx)
    if base_prepare_upstream_headers then
        base_prepare_upstream_headers(headers, ctx)
    end

    local referer = headers["Referer"] or headers["referer"]
    if referer then
        headers["Referer"] = html_rewrite.junction_to_backend_url(
            referer,
            ctx.junction_prefix or device.junction_prefix,
            ctx.session_id,
            ctx.backend_base,
            ctx.backend_host
        )
        headers["referer"] = nil
    end

    local origin = headers["Origin"] or headers["origin"]
    if origin then
        headers["Origin"] = html_rewrite.junction_to_backend_origin(
            origin,
            ctx.backend_base,
            ctx.backend_host
        )
        headers["origin"] = nil
    end
end

return device
