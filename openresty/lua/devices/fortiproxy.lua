--[[
  FortiProxy junction module.

  URI pattern:
    /fortiproxy/{session_id}/...

  FortiProxy ships large bundled main.js files that contain regex helpers and
  RegExp patterns as quoted strings. The shared rewriter uses strict JavaScript
  mode to avoid rewriting regex-like strings while still prefixing real API
  and asset paths.
]]

local junction_device = require "lib.junction_device"

local ACCEPTED_DEVICE_TYPES = {
    fortiproxy = true,
    fortiproxy_gui = true,
}

local device = junction_device.new({
    name = "fortiproxy",
    junction_prefix = "/fortiproxy",
    junction_prefixes = { "/fortiproxy", "/fortiproxy_gui" },
    max_redirects = 10,
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-CSRF-Token",
        "X-Requested-With",
    },
})

local base_rewrite_body = device.rewrite_body

function device.validate_session(session_id, session_data)
    if session_data.device_type and not ACCEPTED_DEVICE_TYPES[session_data.device_type] then
        return false
    end

    return true
end

function device.rewrite_body(body, junction_prefix, session_id, backend_base, backend_host, rewrite_opts)
    rewrite_opts = rewrite_opts or {}
    rewrite_opts.strict_javascript = true

    return base_rewrite_body(
        body,
        junction_prefix,
        session_id,
        backend_base,
        backend_host,
        rewrite_opts
    )
end

return device
