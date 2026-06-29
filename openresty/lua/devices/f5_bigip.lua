--[[
  F5 BIG-IP junction module.

  URI pattern:
    /f5/{session_id}/...

  Valkey value examples:
    "https://10.10.10.10"
    {"url":"https://10.10.10.10:443","device_type":"f5_bigip"}
]]

local html_rewrite = require "lib.html_rewrite"

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

    -- Request uncompressed bodies so HTML/JS/CSS can be rewritten in body_filter.
    ngx.req.clear_header("Accept-Encoding")

    ngx.req.set_header("X-Forwarded-Ssl", "on")
end

function _M.should_rewrite_body(content_type)
    return html_rewrite.should_rewrite_content_type(content_type)
end

function _M.rewrite_body(body, junction_prefix, session_id, backend_base)
    return html_rewrite.rewrite(body, junction_prefix, session_id, backend_base)
end

function _M.on_response_headers(ctx)
    local prefix = _M.junction_prefix .. "/" .. (ctx.session_id or "") .. "/"

    local set_cookie = ngx.header["Set-Cookie"]
    if set_cookie then
        if type(set_cookie) == "table" then
            for i, cookie in ipairs(set_cookie) do
                set_cookie[i] = cookie:gsub("Path=/", "Path=" .. prefix)
            end
            ngx.header["Set-Cookie"] = set_cookie
        else
            ngx.header["Set-Cookie"] = set_cookie:gsub("Path=/", "Path=" .. prefix)
        end
    end

    -- Some F5/TMUI pages emit Refresh redirects with root-absolute paths.
    local refresh = ngx.header["Refresh"]
    if refresh then
        local junction_base, junction_root = html_rewrite.junction_paths(
            ctx.junction_prefix or _M.junction_prefix,
            ctx.session_id
        )

        ngx.header["Refresh"] = refresh:gsub("url=(/[^%s;]+)", function(path)
            if html_rewrite.needs_prefix(path, junction_base) then
                return "url=" .. html_rewrite.prefix_path(path, junction_base, junction_root)
            end
            return "url=" .. path
        end)
    end
end

return _M
