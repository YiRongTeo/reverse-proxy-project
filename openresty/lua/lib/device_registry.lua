local _M = {}

local devices = {
    f5_bigip = require "devices.f5_bigip",
    -- palo_alto = require "devices.palo_alto",
}

function _M.get(device_name)
    local device = devices[device_name]
    if not device then
        return nil, "unknown device junction: " .. tostring(device_name)
    end

    return device
end

return _M
