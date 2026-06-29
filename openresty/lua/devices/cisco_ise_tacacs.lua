--[[
  Cisco ISE (TACACS admin) junction module.

  URI pattern:
    /ise/{session_id}/...

  Valkey value examples:
    "https://10.10.10.30"
    {"url":"https://10.10.10.30:443/admin/","device_type":"cisco_ise_tacacs","host":"10.10.10.30"}

  Tip: set "host" to the ISE FQDN if the appliance redirects using a hostname
  while you connect by IP. Example:
  {"url":"https://10.10.10.30","device_type":"cisco_ise_tacacs","host":"ise.corp.local"}
]]

local html_rewrite = require "lib.html_rewrite"
local junction_device = require "lib.junction_device"

local function proxy_document_domain()
    local proxy_host = html_rewrite.proxy_origin():match("^https?://([^/]+)") or ngx.var.host
    return proxy_host:match("^([^:]+)") or proxy_host
end

-- OWASP CSRFGuard JavaScriptServlet compares document.domain to the ISE hostname
-- baked into the script. Behind a junction proxy document.domain is the proxy host,
-- so rewrite the domain check to validate against the proxy host instead.
local function rewrite_csrfguard(body)
    if not body or body == "" or not body:find("isValidDomain", 1, true) then
        return body
    end

    local proxy_domain = proxy_document_domain()
    local replacement = string.format(
        'if(isValidDomain(document.domain, (function(h) { var i = h.indexOf(":"); return h.substring(0, i != -1 ? i : h.length) })("%s"))',
        proxy_domain
    )

    local rewritten, count = body:gsub(
        'if%s*%(%s*isValidDomain%s*%(%s*document%.domain%s*,%s*["\']([^"\']+)["\']%s*%)%s*%)',
        replacement
    )

    if count > 0 then
        ngx.log(ngx.INFO, "ise csrfguard domain check rewritten for proxy host=", proxy_domain,
            " occurrences=", count)
        return rewritten
    end

    ngx.log(ngx.WARN, "ise csrfguard script found but isValidDomain pattern was not rewritten")
    return body
end

local device = junction_device.new({
    name = "cisco_ise_tacacs",
    junction_prefix = "/ise",
    max_redirects = 10,
    aggressive_absolute_rewrite = true,
    cors_allow_headers = {
        "Authorization",
        "Content-Type",
        "X-Requested-With",
        "Accept",
        "Origin",
        "X-csrf-token",
        "X-CSRF-Token",
        "OWASP_CSRFTOKEN",
        "Fetch-Csrf-Token",
    },
})

local base_should_rewrite_body = device.should_rewrite_body
local base_rewrite_body = device.rewrite_body
local base_on_response_headers = device.on_response_headers

function device.should_rewrite_body(content_type, uri)
    uri = uri or ""
    if uri:find("JavaScriptServlet", 1, true) then
        return true
    end

    return base_should_rewrite_body(content_type, uri)
end

function device.rewrite_body(body, junction_prefix, session_id, backend_base)
    body = base_rewrite_body(body, junction_prefix, session_id, backend_base)

    local uri = ngx.var.uri or ""
    if uri:find("JavaScriptServlet", 1, true) then
        body = rewrite_csrfguard(body)
    end

    return body
end

function device.on_response_headers(ctx)
    base_on_response_headers(ctx)

    local uri = ngx.var.uri or ""
    if uri:find("JavaScriptServlet", 1, true) then
        local content_type = ngx.header["Content-Type"] or ""
        if content_type == "" or content_type:find("text/html", 1, true) then
            ngx.header["Content-Type"] = "application/javascript; charset=UTF-8"
        end
    end
end

return device
