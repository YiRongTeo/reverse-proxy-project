local _M = {}

local function escape_lua_pattern(value)
    return value:gsub("([%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1")
end

function _M.junction_paths(junction_prefix, session_id)
    local base = junction_prefix .. "/" .. session_id
    return base, base .. "/"
end

function _M.needs_prefix(path, junction_base)
    if not path or path == "" then
        return false
    end

    if path:sub(1, 1) ~= "/" then
        return false
    end

    if path:sub(1, 2) == "//" then
        return false
    end

    if path == junction_base or path:sub(1, #junction_base + 1) == junction_base .. "/" then
        return false
    end

    return true
end

function _M.prefix_path(path, junction_base, junction_root)
    if path == "/" then
        return junction_root
    end

    return junction_base .. path
end

function _M.proxy_origin()
    local scheme = ngx.var.http_x_forwarded_proto or ngx.var.scheme or "http"
    local host = ngx.var.http_host or ngx.var.host
    return scheme .. "://" .. host
end

function _M.backend_origin(backend_base, backend_host)
    if backend_host and backend_host ~= "" then
        local scheme = "https"
        if backend_base and backend_base ~= "" then
            scheme = backend_base:match("^(https?)://") or scheme
        end
        return scheme .. "://" .. backend_host
    end

    local origin = _M.normalize_origin(backend_base or "")
    return origin:match("^(https?://[^/]+)") or origin
end

function _M.junction_to_backend_url(url, junction_prefix, session_id, backend_base, backend_host)
    if not url or url == "" then
        return url
    end

    local junction_base = junction_prefix .. "/" .. session_id
    local backend_origin = _M.backend_origin(backend_base, backend_host)
    if backend_origin == "" then
        return url
    end

    local proxy_origin = _M.proxy_origin()
    local proxy_scheme_host = proxy_origin:match("^(https?://[^/]+)")

    if url:match("^https?://") then
        local origin = url:match("^(https?://[^/]+)")
        local path = url:match("^https?://[^/]+(.*)$") or "/"
        if path == "" then
            path = "/"
        end

        if origin == proxy_scheme_host and path:sub(1, #junction_base) == junction_base then
            local subpath = path:sub(#junction_base + 1)
            if subpath == "" then
                subpath = "/"
            end
            return backend_origin .. subpath
        end

        return url
    end

    if url:sub(1, #junction_base) == junction_base then
        local subpath = url:sub(#junction_base + 1)
        if subpath == "" then
            subpath = "/"
        end
        return backend_origin .. subpath
    end

    return url
end

function _M.junction_to_backend_origin(url, backend_base, backend_host)
    if not url or url == "" then
        return url
    end

    local backend_origin = _M.backend_origin(backend_base, backend_host)
    if backend_origin == "" then
        return url
    end

    local proxy_origin = _M.proxy_origin()
    local request_origin = url:match("^(https?://[^/]+)")
    local proxy_scheme_host = proxy_origin:match("^(https?://[^/]+)")
    if request_origin == proxy_scheme_host then
        return backend_origin
    end

    return url
end

function _M.normalize_origin(url)
    if not url or url == "" then
        return ""
    end

    url = url:gsub("/+$", "")
    url = url:gsub("^https://([^:/]+):443", "https://%1")
    url = url:gsub("^http://([^:/]+):80", "http://%1")
    return url
end

function _M.extract_host(url)
    if not url then
        return nil
    end

    return url:match("^https?://([^:/]+)")
end

local REGEX_METACHAR = {
    ["^"] = true,
    ["$"] = true,
    ["\\"] = true,
    ["|"] = true,
    ["("] = true,
    [")"] = true,
    ["["] = true,
    ["]"] = true,
    ["*"] = true,
    ["+"] = true,
    ["{"] = true,
    ["}"] = true,
}

local JS_URL_ROOTS = {
    api = true,
    admin = true,
    apps = true,
    assets = true,
    css = true,
    dashboard = true,
    forti = true,
    fortiproxy = true,
    js = true,
    login = true,
    logout = true,
    modules = true,
    ng = true,
    proxy = true,
    resources = true,
    scripts = true,
    static = true,
    ui = true,
}

function _M.looks_like_url_path(path)
    if not path or path == "" or path:sub(1, 1) ~= "/" or path:sub(1, 2) == "//" then
        return false
    end

    -- Regex literal style suffix: /pattern/gimsuy
    if path:match("/[gimsuy]+$") then
        return false
    end

    for i = 1, #path do
        if REGEX_METACHAR[path:sub(i, i)] then
            return false
        end
    end

    if path:find("?", 1, true) and not path:match("%?[%w%%&=.+-]") then
        return false
    end

    if path:match("/%.%.?/?") or path:match("^/%.") then
        return false
    end

    return true
end

function _M.looks_like_js_url_path(path)
    if not _M.looks_like_url_path(path) then
        return false
    end

    if path:match("%?[%w%%]") then
        return true
    end

    if path:match("%.%w+$") then
        return true
    end

    if path:match("^/[%w_-]+$") then
        return true
    end

    local root = path:match("^/([^/]+)")
    if root and JS_URL_ROOTS[root:lower()] then
        return true
    end

    return false
end

function _M.is_javascript_content(content_type, uri)
    if content_type then
        local ct = content_type:lower()
        if ct:find("javascript", 1, true) or ct:find("ecmascript", 1, true) then
            return true
        end
    end

    uri = uri or ""
    return uri:lower():match("%.js$") ~= nil
        or uri:lower():match("%.mjs$") ~= nil
end

local function should_rewrite_quoted_path(path, opts)
    if not path or path == "" then
        return false
    end

    opts = opts or {}
    if opts.strict_javascript then
        return _M.looks_like_js_url_path(path)
    end

    return _M.looks_like_url_path(path)
end

function _M.hosts_match(host_a, host_b)
    if not host_a or not host_b then
        return false
    end

    return host_a:lower() == host_b:lower()
end

function _M.rewrite_location(location, junction_base, junction_root, backend_base, backend_host)
    if not location or location == "" then
        return location
    end

    if location:sub(1, 1) == "/" and location:sub(1, 2) ~= "/" then
        return _M.proxy_origin() .. _M.prefix_path(location, junction_base, junction_root)
    end

    local backend = _M.normalize_origin(backend_base or "")
    backend_host = backend_host or _M.extract_host(backend)

    if backend ~= "" then
        local norm_location = location
        if location:match("^https?://") then
            local scheme, host, port, path = location:match("^(https?)://([^:/]+):?(%d*)(.*)$")
            if scheme and host then
                local port_suffix = ""
                if port ~= "" and not (scheme == "https" and port == "443") and not (scheme == "http" and port == "80") then
                    port_suffix = ":" .. port
                end
                norm_location = scheme .. "://" .. host .. port_suffix .. (path or "")
            end
        end

        norm_location = _M.normalize_origin(norm_location:match("^(https?://[^/]+)"))
            .. (norm_location:match("^https?://[^/]+(.*)$") or "")

        if norm_location:sub(1, #backend) == backend then
            local path = norm_location:sub(#backend + 1)
            if path == "" then
                path = "/"
            end
            return _M.proxy_origin() .. _M.prefix_path(path, junction_base, junction_root)
        end
    end

    local location_host = _M.extract_host(location)
    if backend_host and location_host and _M.hosts_match(backend_host, location_host) then
        local path = location:match("^https?://[^/]+(.*)$") or "/"
        if path == "" then
            path = "/"
        end
        return _M.proxy_origin() .. _M.prefix_path(path, junction_base, junction_root)
    end

    return location
end

local function ci_attr_pattern(attr)
    local parts = {}
    for i = 1, #attr do
        local c = attr:sub(i, i)
        parts[#parts + 1] = "[" .. c:lower() .. c:upper() .. "]"
    end
    return table.concat(parts)
end

function _M.rewrite_url_reference(url, junction_base, junction_root, backend_base, backend_host, aggressive, opts)
    if not url or url == "" then
        return url
    end

    opts = opts or {}

    if url:sub(1, 1) == "/" and url:sub(1, 2) ~= "//" then
        if not should_rewrite_quoted_path(url, opts) then
            return url
        end
        if _M.needs_prefix(url, junction_base) then
            return _M.prefix_path(url, junction_base, junction_root)
        end
        return url
    end

    if not url:match("^https?://") then
        return url
    end

    local rewritten = _M.rewrite_location(
        url,
        junction_base,
        junction_root,
        backend_base,
        backend_host
    )

    if rewritten ~= url then
        local path = rewritten:match("^https?://[^/]+(.*)$")
        if path and path ~= "" then
            return path
        end
        return rewritten
    end

    if aggressive then
        local path = url:match("^https?://[^/]+(.*)$") or "/"
        if path == "" then
            path = "/"
        end
        if should_rewrite_quoted_path(path, opts) and _M.needs_prefix(path, junction_base) then
            return _M.prefix_path(path, junction_base, junction_root)
        end
    end

    return url
end

local function rewrite_attribute(body, attr, junction_base, junction_root, backend_base, backend_host, aggressive, opts)
    local attr_pattern = ci_attr_pattern(attr)
    local patterns = {
        { quote = '"', value = '([^"]+)' },
        { quote = "'", value = "([^']+)" },
    }

    for _, item in ipairs(patterns) do
        local pattern = attr_pattern .. '%s*=%s*' .. item.quote .. item.value .. item.quote
        body = body:gsub(pattern, function(value)
            local rewritten = _M.rewrite_url_reference(
                value,
                junction_base,
                junction_root,
                backend_base,
                backend_host,
                aggressive,
                opts
            )
            return attr .. "=" .. item.quote .. rewritten .. item.quote
        end)
    end

    return body
end

local function rewrite_quoted_urls(body, junction_base, junction_root, backend_base, backend_host, aggressive, opts)
    body = body:gsub("([\"'])(/[^\"']*)", function(quote, path)
        if not should_rewrite_quoted_path(path, opts) then
            return quote .. path
        end

        local rewritten = _M.rewrite_url_reference(
            path,
            junction_base,
            junction_root,
            backend_base,
            backend_host,
            aggressive,
            opts
        )
        return quote .. rewritten
    end)

    body = body:gsub("([\"'])(https?://[^\"']*)", function(quote, url)
        local rewritten = _M.rewrite_url_reference(
            url,
            junction_base,
            junction_root,
            backend_base,
            backend_host,
            aggressive,
            opts
        )
        return quote .. rewritten
    end)

    return body
end

local function rewrite_dom_src_setters(body, junction_base, junction_root, backend_base, backend_host, aggressive, opts)
    return body:gsub("%.src%s*=%s*([\"'])([^\"']+)([\"'])", function(open_quote, value, close_quote)
        local rewritten = _M.rewrite_url_reference(
            value,
            junction_base,
            junction_root,
            backend_base,
            backend_host,
            aggressive,
            opts
        )
        return ".src=" .. open_quote .. rewritten .. close_quote
    end)
end

local function rewrite_css_urls(body, junction_base, junction_root)
    return body:gsub("url%((%s*)(['\"]?)(/[^%)\"']*)", function(space, quote, path)
        if not _M.needs_prefix(path, junction_base) then
            return "url(" .. space .. quote .. path
        end

        return "url(" .. space .. quote .. _M.prefix_path(path, junction_base, junction_root)
    end)
end

local function rewrite_template_host(body, proxy_origin)
    local host = proxy_origin:match("^https?://([^/]+)") or ngx.var.host
    body = body:gsub("{{:host_addr}}", host)
    body = body:gsub("{{:host}}", host)
    return body
end

function _M.rewrite(body, junction_prefix, session_id, backend_base, backend_host, opts)
    if not body or body == "" then
        return body
    end

    opts = opts or {}
    local aggressive = opts.aggressive_absolute_rewrite == true
    backend_host = backend_host or _M.extract_host(backend_base)

    if opts.strict_javascript == nil then
        opts.strict_javascript = _M.is_javascript_content(opts.content_type, opts.uri)
    end

    local junction_base, junction_root = _M.junction_paths(junction_prefix, session_id)
    local proxy_origin = _M.proxy_origin()

    -- Prevent double-rewriting if the same response passes through twice.
    local marker = escape_lua_pattern(junction_base)
    if body:find(marker, 1, true) and body:find('href="' .. junction_base, 1, true) then
        -- Still rewrite quoted paths that may not yet be prefixed.
    end

    body = rewrite_template_host(body, proxy_origin)

    for _, attr in ipairs({
        "href", "src", "action", "poster", "data-src", "data-href", "formaction",
    }) do
        body = rewrite_attribute(
            body,
            attr,
            junction_base,
            junction_root,
            backend_base,
            backend_host,
            aggressive,
            opts
        )
    end

    body = rewrite_css_urls(body, junction_base, junction_root)
    body = rewrite_quoted_urls(
        body,
        junction_base,
        junction_root,
        backend_base,
        backend_host,
        aggressive,
        opts
    )
    body = rewrite_dom_src_setters(
        body,
        junction_base,
        junction_root,
        backend_base,
        backend_host,
        aggressive,
        opts
    )

    return body
end

function _M.should_rewrite_content_type(content_type)
    if not content_type then
        return false
    end

    local ct = content_type:lower()
    return ct:find("text/html", 1, true)
        or ct:find("application/javascript", 1, true)
        or ct:find("text/javascript", 1, true)
        or ct:find("application/x%-javascript", 1, true)
        or ct:find("text/css", 1, true)
        or ct:find("application/json", 1, true)
        or ct:find("text/plain", 1, true)
end

local HTML_LIKE_EXTENSIONS = {
    html = true,
    htm = true,
    php = true,
    asp = true,
    aspx = true,
    jsp = true,
}

function _M.should_rewrite_response(content_type, uri)
    if _M.should_rewrite_content_type(content_type) then
        return true
    end

    if content_type and content_type ~= "" then
        return false
    end

    uri = uri or ""
    local extension = uri:match("%.([^./?]+)$")
    if not extension then
        return true
    end

    return HTML_LIKE_EXTENSIONS[extension:lower()] == true
end

return _M
