local _M = {}

local devices = {}

local function load_device(name)
    if devices[name] then
        return devices[name]
    end

    local ok, device = pcall(require, "devices." .. name)
    if not ok then
        return nil, device
    end

    devices[name] = device
    return device
end

function _M.get(device_name)
    local device, err = load_device(device_name)
    if not device then
        return nil, "unknown device junction: " .. tostring(device_name)
            .. (err and (" (" .. tostring(err) .. ")") or "")
    end

    return device
end

return _M
