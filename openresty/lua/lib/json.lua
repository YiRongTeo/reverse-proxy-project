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
    local json_mod, err = load_cjson()
    if not json_mod then
        return nil, err
    end

    local decoded, decode_err = json_mod.decode(raw)
    if decoded ~= nil then
        return decoded, nil
    end

    if decode_err == nil or decode_err == "" then
        decode_err = "json decode returned nil"
    end

    return nil, decode_err
end

return _M
