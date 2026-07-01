local _M = {}

function _M.set_upstream(target_url)
    if not target_url or target_url == "" then
        return nil, "missing target url"
    end

    ngx.var.device_upstream = target_url
    return true
end

function _M.preserve_client_ip()
    local client_ip = ngx.var.remote_addr
    if client_ip and client_ip ~= "" then
        ngx.req.set_header("X-Real-IP", client_ip)
        ngx.req.set_header("X-Forwarded-For", client_ip)
    end
    ngx.req.set_header("X-Forwarded-Proto", ngx.var.scheme)
    ngx.req.set_header("X-Forwarded-Host", ngx.var.host)
end

function _M.deny(status, message)
    message = message or "request rejected"
    message = message:gsub("\\", "\\\\"):gsub('"', '\\"')

    ngx.status = status or ngx.HTTP_BAD_REQUEST
    ngx.header["Content-Type"] = "application/json"
    ngx.say('{"error":"' .. message .. '"}')
    return ngx.exit(status or ngx.HTTP_BAD_REQUEST)
end

return _M
