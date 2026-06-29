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

local function rewrite_attribute(body, attr, junction_base, junction_root)
    local patterns = {
        { quote = '"', pattern = attr .. '="(/[^"]*)"' },
        { quote = "'", pattern = attr .. "='(/[^']*)'" },
    }

    for _, item in ipairs(patterns) do
        body = body:gsub(item.pattern, function(path)
            if not _M.needs_prefix(path, junction_base) then
                return attr .. "=" .. item.quote .. path .. item.quote
            end

            return attr .. "=" .. item.quote .. _M.prefix_path(path, junction_base, junction_root) .. item.quote
        end)
    end

    return body
end

local function rewrite_quoted_root_paths(body, junction_base, junction_root)
    return body:gsub("([\"'])(/[^\"']*)", function(quote, path)
        if not _M.needs_prefix(path, junction_base) then
            return quote .. path
        end

        return quote .. _M.prefix_path(path, junction_base, junction_root)
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

function _M.rewrite(body, junction_prefix, session_id, backend_base)
    if not body or body == "" then
        return body
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
        body = rewrite_attribute(body, attr, junction_base, junction_root)
    end

    body = rewrite_css_urls(body, junction_base, junction_root)
    body = rewrite_quoted_root_paths(body, junction_base, junction_root)

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
