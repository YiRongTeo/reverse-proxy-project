local redis

local function load_redis()
    if redis then
        return redis
    end

    local ok, mod = pcall(require, "resty.redis")
    if not ok then
        return nil, "failed to load resty.redis: " .. tostring(mod)
            .. " (ensure lua_package_path includes OpenResty lualib)"
    end

    redis = mod
    return redis
end

local _M = {}

local DEFAULT_HOST = os.getenv("VALKEY_HOST") or "127.0.0.1"
local DEFAULT_PORT = tonumber(os.getenv("VALKEY_PORT")) or 6379
local DEFAULT_TIMEOUT = tonumber(os.getenv("VALKEY_TIMEOUT_MS")) or 1000
local DEFAULT_POOL_SIZE = tonumber(os.getenv("VALKEY_POOL_SIZE")) or 100
local DEFAULT_POOL_IDLE = tonumber(os.getenv("VALKEY_POOL_IDLE_MS")) or 10000

local function connect()
    local redis_mod, err = load_redis()
    if not redis_mod then
        return nil, err
    end

    local red = redis_mod:new()
    red:set_timeout(DEFAULT_TIMEOUT)

    local ok, connect_err = red:connect(DEFAULT_HOST, DEFAULT_PORT)
    if not ok then
        return nil, "valkey connect failed: " .. (connect_err or "unknown")
    end

    local password = os.getenv("VALKEY_PASSWORD")
    if password and password ~= "" then
        local auth_ok, auth_err = red:auth(password)
        if not auth_ok then
            red:close()
            return nil, "valkey auth failed: " .. (auth_err or "unknown")
        end
    end

    return red
end

function _M.with_client(fn)
    local red, err = connect()
    if not red then
        return nil, err
    end

    local results = { fn(red) }
    local fn_err = results[1] == nil and results[2]

    local keepalive_ok, keepalive_err = red:set_keepalive(DEFAULT_POOL_IDLE, DEFAULT_POOL_SIZE)
    if not keepalive_ok then
        ngx.log(ngx.WARN, "valkey keepalive failed: ", keepalive_err)
    end

    if fn_err then
        return nil, fn_err
    end

    return unpack(results)
end

function _M.get(key)
    return _M.with_client(function(red)
        local value, err = red:get(key)
        if not value then
            return nil, "valkey get failed: " .. (err or "unknown")
        end

        if value == ngx.null then
            return nil, "session not found"
        end

        return value
    end)
end

return _M
