local _M = {}

local cjson

local function load_cjson()
    if cjson then
        return cjson
    end

    local ok, mod = pcall(require, "cjson.safe")
    if ok then
        cjson = mod
        return cjson
    end

    ok, mod = pcall(require, "cjson")
    if ok then
        cjson = mod
        return cjson
    end

    return nil, "failed to load cjson: " .. tostring(mod)
end

function _M.decode(raw)
    local json, err = load_cjson()
    if not json then
        return nil, err
    end

    local decoded, decode_err = json.decode(raw)
    if decoded ~= nil then
        return decoded
    end

    return nil, decode_err
end

return _M
