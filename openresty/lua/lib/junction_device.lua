local html_rewrite = require "lib.html_rewrite"

local _M = {}

local DEFAULT_CORS_HEADERS = {
    "Authorization",
    "Content-Type",
    "X-Requested-With",
    "Accept",
    "Origin",
}

function _M.new(opts)
    local device = {
        name = opts.name,
        junction_prefix = opts.junction_prefix,
        junction_prefixes = opts.junction_prefixes,
        aggressive_absolute_rewrite = opts.aggressive_absolute_rewrite == true,
        follow_redirects = opts.follow_redirects ~= false,
        max_redirects = opts.max_redirects or 10,
        cors = {
            allow_credentials = true,
            allow_private_network = opts.allow_private_network ~= false,
            allow_headers = table.concat(opts.cors_allow_headers or DEFAULT_CORS_HEADERS, ", "),
        },
    }

    function device.validate_session(session_id, session_data)
        if session_data.device_type and session_data.device_type ~= device.name then
            return false
        end

        return true
    end

    function device.before_proxy(ctx)
        ngx.ctx[device.name .. "_original_host"] = ctx.session.host
        return true
    end

    function device.configure_request_headers(ctx)
        local backend_host = ctx.session.host
        if not backend_host and ctx.session.url then
            backend_host = ctx.session.url:match("^https?://([^:/]+)")
        end

        if backend_host then
            ngx.req.set_header("Host", backend_host)
        end

        ngx.req.clear_header("Accept-Encoding")
        ngx.req.set_header("Accept-Encoding", "identity")
        ngx.req.set_header("X-Forwarded-Ssl", "on")
    end

    function device.should_rewrite_body(content_type, uri)
        return html_rewrite.should_rewrite_response(content_type, uri)
    end

    function device.rewrite_body(body, junction_prefix, session_id, backend_base, backend_host, rewrite_opts)
        rewrite_opts = rewrite_opts or {}
        if rewrite_opts.aggressive_absolute_rewrite == nil then
            rewrite_opts.aggressive_absolute_rewrite = opts.aggressive_absolute_rewrite == true
        end

        return html_rewrite.rewrite(
            body,
            junction_prefix,
            session_id,
            backend_base,
            backend_host or ngx.ctx.backend_host,
            rewrite_opts
        )
    end

    function device.rewrite_location(location, ctx)
        local junction_base, junction_root = html_rewrite.junction_paths(
            ctx.junction_prefix or device.junction_prefix,
            ctx.session_id
        )

        local rewritten = html_rewrite.rewrite_location(
            location,
            junction_base,
            junction_root,
            ctx.backend_base,
            ctx.backend_host
        )

        if rewritten ~= location then
            return rewritten
        end

        -- Devices such as Cisco ISE redirect to https://<fqdn>/admin/... while the
        -- session is stored as https://<ip>/... — rewrite the path under the junction.
        if location:match("^https?://") then
            local path = location:match("^https?://[^/]+(.*)$") or "/"
            if path == "" then
                path = "/"
            end
            return html_rewrite.proxy_origin()
                .. html_rewrite.prefix_path(path, junction_base, junction_root)
        end

        return location
    end

    function device.on_response_headers(ctx)
        local prefix = device.junction_prefix .. "/" .. (ctx.session_id or "") .. "/"

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

        local refresh = ngx.header["Refresh"]
        if refresh then
            local junction_base, junction_root = html_rewrite.junction_paths(
                ctx.junction_prefix or device.junction_prefix,
                ctx.session_id
            )

            refresh = refresh:gsub("url=(https?://[^%s;]+)", function(url)
                local rewritten = html_rewrite.rewrite_location(
                    url,
                    junction_base,
                    junction_root,
                    ctx.backend_base,
                    ctx.backend_host
                )
                if rewritten ~= url then
                    return "url=" .. rewritten
                end
                local path = url:match("^https?://[^/]+(.*)$") or "/"
                if path == "" then
                    path = "/"
                end
                return "url=" .. html_rewrite.proxy_origin()
                    .. html_rewrite.prefix_path(path, junction_base, junction_root)
            end)

            ngx.header["Refresh"] = refresh:gsub("url=(/[^%s;]+)", function(path)
                if html_rewrite.needs_prefix(path, junction_base) then
                    return "url=" .. html_rewrite.prefix_path(path, junction_base, junction_root)
                end
                return "url=" .. path
            end)
        end
    end

    if opts.default_subpath then
        local junction_session = require "lib.junction_session"

        function device.resolve_upstream_url(base_url, subpath)
            if not subpath or subpath == "" or subpath == "/" then
                subpath = opts.default_subpath
            end

            return junction_session.build_upstream_url(base_url, subpath)
        end
    end

    return device
end

return _M
