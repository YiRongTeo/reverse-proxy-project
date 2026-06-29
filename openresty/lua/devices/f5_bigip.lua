--[[
  F5 BIG-IP junction module.

  URI pattern:
    /f5/{session_id}/...

  Valkey value examples:
    "https://10.10.10.10"
    {"url":"https://10.10.10.10:443","device_type":"f5_bigip"}
]]

local _M = {}

_M.name = "f5_bigip"
_M.junction_prefix = "/f5"

_M.cors = {
    allow_credentials = true,
    allow_private_network = true,
    allow_headers = table.concat({
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-F5-Auth-Token",
        "X-Auth-Token",
    }, ", "),
}

function _M.validate_session(session_id, session_data)
    if session_data.device_type and session_data.device_type ~= _M.name then
        return false
    end

    return true
end

function _M.before_proxy(ctx)
    -- F5 TMUI often expects a browser-like Host header and HTTPS semantics.
    ngx.ctx.f5_original_host = ctx.session.host
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

    -- BIG-IP frequently uses self-signed certificates behind the proxy.
    ngx.req.set_header("X-Forwarded-Ssl", "on")
end

function _M.on_response_headers(ctx)
    -- Rewrite Set-Cookie paths so browser cookies stay scoped to the junction.
    local prefix = _M.junction_prefix .. "/" .. (ctx.session_id or "") .. "/"
    local set_cookie = ngx.header["Set-Cookie"]
    if not set_cookie then
        return
    end

    if type(set_cookie) == "table" then
        for i, cookie in ipairs(set_cookie) do
            set_cookie[i] = cookie:gsub("Path=/", "Path=" .. prefix)
        end
        ngx.header["Set-Cookie"] = set_cookie
        return
    end

    ngx.header["Set-Cookie"] = set_cookie:gsub("Path=/", "Path=" .. prefix)
end

return _M
