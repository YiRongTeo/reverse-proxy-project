local json_lib = package.loaded["lib.json"]
if type(json_lib) ~= "table" then
    json_lib = require "lib.json"
end

if type(json_lib) ~= "table" or type(json_lib.decode) ~= "function" then
    json_lib = nil
end

local valkey = require "lib.valkey"

local _M = {}

local SESSION_PREFIX = os.getenv("SESSION_KEY_PREFIX") or "session:"

local function trim(raw)
    if not raw then
        return raw
    end

    raw = raw:gsub("^\239\187\191", "")
    return raw:match("^%s*(.-)%s*$")
end

local function strip_wrapping_quotes(raw)
    raw = trim(raw)
    if not raw or raw == "" then
        return raw
    end

    local first = raw:sub(1, 1)
    if first == "{" or first == "[" then
        return raw
    end

    if first == '"' and raw:sub(-1) == '"' then
        return raw:sub(2, -2)
    end

    if first == "'" and raw:sub(-1) == "'" then
        return raw:sub(2, -2)
    end

    return raw
end

local function unescape_json_string(value)
    if not value then
        return value
    end

    return (value:gsub("\\(.)", {
        ['"'] = '"',
        ["\\"] = "\\",
        ["/"] = "/",
        b = "\b",
        f = "\f",
        n = "\n",
        r = "\r",
        t = "\t",
    }))
end

local function extract_quoted_field(raw, field)
    if not raw or raw == "" then
        return nil
    end

    local key_pattern = '"' .. field .. '"%s*:%s*"'
    local start, finish = raw:find(key_pattern)
    if not start then
        key_pattern = "'" .. field .. "'%s*:%s*'"
        start, finish = raw:find(key_pattern)
        if not start then
            return nil
        end
    end

    local i = finish + 1
    local chars = {}
    while i <= #raw do
        local c = raw:sub(i, i)
        if c == "\\" then
            local next_char = raw:sub(i + 1, i + 1)
            if next_char == "" then
                break
            end
            chars[#chars + 1] = next_char
            i = i + 2
        elseif c == '"' or c == "'" then
            break
        else
            chars[#chars + 1] = c
            i = i + 1
        end
    end

    local value = table.concat(chars)
    if value == "" then
        return nil
    end

    return unescape_json_string(value)
end

local function extract_json_fields(raw)
    if not raw or raw == "" or not raw:find("{", 1, true) then
        return nil
    end

    local session = {
        url = extract_quoted_field(raw, "url"),
        host = extract_quoted_field(raw, "host"),
        device_type = extract_quoted_field(raw, "device_type"),
    }

    if session.url and session.url ~= "" then
        return session
    end

    return nil
end

local function normalize_session_table(decoded)
    if type(decoded) ~= "table" then
        return nil
    end

    local url = decoded.url or decoded.URL or decoded.backend_url or decoded.backend
    if type(url) ~= "string" or url == "" then
        return nil
    end

    url = trim(url)
    if url == "" or url:sub(1, 1) == "{" then
        return nil
    end

    decoded.url = url
    if type(decoded.host) == "string" then
        decoded.host = trim(decoded.host)
    end

    return decoded
end

local function plain_url_session(raw)
    raw = strip_wrapping_quotes(raw)
    if not raw or raw == "" then
        return nil
    end

    if raw:match("^https?://") then
        return { url = raw }
    end

    if raw:match("^[%d%.:]+$") or raw:match("^[%w%.%-:]+$") then
        return { url = "https://" .. raw }
    end

    return nil
end

local function try_decode_json(raw)
    if not json_lib then
        return nil, "json decoder unavailable"
    end

    local candidates = { raw }

    local unescaped = raw:gsub('\\"', '"')
    if unescaped ~= raw then
        candidates[#candidates + 1] = unescaped
    end

    for _, candidate in ipairs(candidates) do
        local decoded, decode_err = json_lib.decode(candidate)
        if type(decoded) == "table" then
            return decoded
        end

        if type(decoded) == "string" then
            local nested = json_lib.decode(decoded)
            if type(nested) == "table" then
                return nested
            end
            if decoded:match("^https?://") then
                return { url = decoded }
            end
        end
    end

    return nil, "json decode failed"
end

local function parse_session_value(raw)
    if not raw or raw == "" then
        return nil, "empty session value"
    end

    raw = strip_wrapping_quotes(raw)

    local session
    if raw:find("{", 1, true) then
        session = extract_json_fields(raw)
        if session then
            return session
        end
    end

    session = normalize_session_table(try_decode_json(raw))
    if session then
        return session
    end

    if not raw:find("{", 1, true) then
        session = plain_url_session(raw)
        if session then
            return session
        end
    end

    ngx.log(ngx.WARN, "session value could not be parsed: ", raw:sub(1, 160))
    return nil, "invalid session value"
end

function _M.extract_from_uri(prefix)
    local uri = ngx.var.uri or ""
    local pattern = "^" .. prefix .. "/([^/]+)(/.*)?$"
    local session_id, subpath = uri:match(pattern)

    if not session_id then
        return nil, nil, "invalid session path"
    end

    subpath = subpath or "/"
    return session_id, subpath
end

function _M.lookup(session_id)
    if not session_id or session_id == "" then
        return nil, "missing session id"
    end

    local raw, err = valkey.get(SESSION_PREFIX .. session_id)
    if not raw then
        return nil, err
    end

    return parse_session_value(raw)
end

function _M.build_upstream_url(base_url, subpath)
    if not base_url or base_url == "" then
        return nil, "missing backend url"
    end

    base_url = base_url:gsub("/+$", "")
    base_url = base_url:gsub("^https://([^:/]+):443", "https://%1")
    base_url = base_url:gsub("^http://([^:/]+):80", "http://%1")
    subpath = subpath or "/"
    if subpath:sub(1, 1) ~= "/" then
        subpath = "/" .. subpath
    end

    return base_url .. subpath
end

if type(_M.extract_from_uri) ~= "function"
    or type(_M.lookup) ~= "function"
    or type(_M.build_upstream_url) ~= "function" then
    error("lib.junction_session module is incomplete")
end

return _M
