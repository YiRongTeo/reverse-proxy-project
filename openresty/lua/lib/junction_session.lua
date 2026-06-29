local json = require "lib.json"
local valkey = require "lib.valkey"

local _M = {}

local SESSION_PREFIX = os.getenv("SESSION_KEY_PREFIX") or "session:"

local function trim(raw)
    if not raw then
        return raw
    end
    return raw:match("^%s*(.-)%s*$")
end

local function strip_wrapping_quotes(raw)
    raw = trim(raw)
    if not raw or raw == "" then
        return raw
    end

    if raw:sub(1, 1) == '"' and raw:sub(-1) == '"' then
        return raw:sub(2, -2)
    end

    if raw:sub(1, 1) == "'" and raw:sub(-1) == "'" then
        return raw:sub(2, -2)
    end

    return raw
end

local function extract_json_fields(raw)
    if not raw or raw == "" then
        return nil
    end

    if not raw:find("{", 1, true) then
        return nil
    end

    local session = {
        url = raw:match('"url"%s*:%s*"([^"]+)"')
            or raw:match("'url'%s*:%s*'([^']+)'"),
        host = raw:match('"host"%s*:%s*"([^"]+)"')
            or raw:match("'host'%s*:%s*'([^']+)'"),
        device_type = raw:match('"device_type"%s*:%s*"([^"]+)"')
            or raw:match("'device_type'%s*:%s*'([^']+)'"),
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

    if url:find("{", 1, true) then
        return nil
    end

    decoded.url = url
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

    if raw:match("^[%d%.]+$") or raw:match("^[%w%.%-]+$") then
        return { url = "https://" .. raw }
    end

    return nil
end

local function parse_session_value(raw)
    if not raw or raw == "" then
        return nil, "empty session value"
    end

    raw = strip_wrapping_quotes(raw)

    local decoded, decode_err = json.decode(raw)

    if type(decoded) == "string" then
        local nested = json.decode(decoded)
        if type(nested) == "table" then
            decoded = nested
        elseif decoded:match("^https?://") then
            return { url = decoded }
        end
    end

    local session = normalize_session_table(decoded)
    if session then
        return session
    end

    session = extract_json_fields(raw)
    if session then
        if decode_err then
            ngx.log(ngx.WARN, "session json decode failed, extracted fields from value: ", decode_err)
        end
        return session
    end

    if not raw:find("{", 1, true) then
        session = plain_url_session(raw)
        if session then
            return session
        end
    end

    if decode_err then
        ngx.log(ngx.WARN, "session value parse failed: ", decode_err, " value=", raw:sub(1, 120))
    elseif raw:find("{", 1, true) then
        ngx.log(ngx.WARN, "session value looks like json but no url field was found: ",
            raw:sub(1, 120))
    end

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
