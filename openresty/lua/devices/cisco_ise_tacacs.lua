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

local function is_javascript_servlet_uri(uri)
    return (uri or ""):find("JavaScriptServlet", 1, true) ~= nil
end

local function looks_like_html(body)
    if not body or body == "" then
        return false
    end

    local head = body:sub(1, 256):lower()
    return head:find("<!doctype", 1, true)
        or head:find("<html", 1, true)
        or head:find("<head", 1, true)
end

local function looks_like_javascript(body)
    if not body or body == "" or looks_like_html(body) then
        return false
    end

    return body:find("isValidDomain", 1, true)
        or body:find("function", 1, true)
        or body:find("Owasp_CSRFTOKEN", 1, true)
        or body:find("csrfguard", 1, true)
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

local function rewrite_header_url(headers, name, ctx)
    local value = headers[name] or headers[name:lower()]
    if not value then
        return
    end

    headers[name] = html_rewrite.junction_to_backend_url(
        value,
        ctx.junction_prefix or "/ise",
        ctx.session_id,
        ctx.backend_base,
        ctx.backend_host
    )
    headers[name:lower()] = nil
end

local function rewrite_origin_header(headers, ctx)
    local value = headers["Origin"] or headers["origin"]
    if not value then
        return
    end

    headers["Origin"] = html_rewrite.junction_to_backend_origin(value, ctx.backend_base, ctx.backend_host)
    headers["origin"] = nil
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

function device.should_follow_redirects(uri, method, default)
    if is_javascript_servlet_uri(uri) then
        return false
    end
    return default
end

function device.prepare_upstream_headers(headers, ctx)
    local before_referer = headers["Referer"] or headers["referer"]
    rewrite_header_url(headers, "Referer", ctx)
    if before_referer and headers["Referer"] and headers["Referer"] ~= before_referer then
        ngx.log(ngx.INFO, "ise referer rewritten ", before_referer, " -> ", headers["Referer"])
    end

    local before_origin = headers["Origin"] or headers["origin"]
    rewrite_origin_header(headers, ctx)
    if before_origin and headers["Origin"] and headers["Origin"] ~= before_origin then
        ngx.log(ngx.INFO, "ise origin rewritten ", before_origin, " -> ", headers["Origin"])
    end

    local uri = ngx.var.uri or ""
    if is_javascript_servlet_uri(uri) then
        local referer = headers["Referer"]
        if not referer or referer == "" then
            local admin_base = html_rewrite.backend_origin(ctx.backend_base, ctx.backend_host) .. "/admin/"
            headers["Referer"] = admin_base
            ngx.log(ngx.INFO, "ise JavaScriptServlet synthesized Referer=", admin_base)
        end
    end
end

function device.should_rewrite_body(content_type, uri)
    if is_javascript_servlet_uri(uri) then
        return true
    end

    return base_should_rewrite_body(content_type, uri)
end

function device.rewrite_body(body, junction_prefix, session_id, backend_base)
    local uri = ngx.var.uri or ""
    if is_javascript_servlet_uri(uri) then
        return rewrite_csrfguard(body)
    end

    return base_rewrite_body(body, junction_prefix, session_id, backend_base)
end

function device.finalize_response_headers(ctx, body, res)
    local uri = ngx.var.uri or ""
    if not is_javascript_servlet_uri(uri) then
        return
    end

    local upstream_ct = res.headers["Content-Type"] or res.headers["content-type"] or ""

    if looks_like_html(body) then
        ngx.log(ngx.WARN, "ise JavaScriptServlet returned HTML instead of JavaScript",
            " status=", res.status, " content-type=", upstream_ct,
            " bytes=", body and #body or 0)
        return
    end

    if looks_like_javascript(body) then
        ngx.header.content_type = "application/javascript; charset=UTF-8"
        ngx.log(ngx.INFO, "ise JavaScriptServlet content-type set to application/javascript",
            " upstream_content-type=", upstream_ct)
    end
end

function device.on_response_headers(ctx)
    base_on_response_headers(ctx)
end

return device
