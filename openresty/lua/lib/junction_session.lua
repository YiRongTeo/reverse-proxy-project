local json = require "lib.json"
local valkey = require "lib.valkey"

local _M = {}

local SESSION_PREFIX = os.getenv("SESSION_KEY_PREFIX") or "session:"

local function parse_session_value(raw)
    if not raw or raw == "" then
        return nil, "empty session value"
    end

    local decoded = json.decode(raw)
    if type(decoded) == "table" and decoded.url then
        return decoded
    end

    return { url = raw }
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
    subpath = subpath or "/"
    if subpath:sub(1, 1) ~= "/" then
        subpath = "/" .. subpath
    end

    return base_url .. subpath
end

return _M
