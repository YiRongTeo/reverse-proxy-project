--[[
  Template for adding a new device junction.

  Steps:
    1. Copy this file to lua/devices/<device_name>.lua
    2. Register it in lua/lib/device_registry.lua
    3. Add a location block in nginx/conf/junctions.conf
]]

local _M = {}

_M.name = "example_device"
_M.junction_prefix = "/example"

_M.cors = {
    allow_credentials = true,
}

function _M.validate_session(session_id, session_data)
    if session_data.device_type and session_data.device_type ~= _M.name then
        return false
    end

    return true
end

function _M.before_proxy(ctx)
    return true
end

function _M.configure_request_headers(ctx)
    local backend_host = ctx.session.host
    if not backend_host and ctx.session.url then
        backend_host = ctx.session.url:match("^https?://([^:/]+)")
    end

    if backend_host then
        ngx.req.set_header("Host", backend_host)
    end
end

function _M.on_response_headers(ctx)
end

function _M.should_rewrite_body(content_type)
    return false
end

return _M
