--[[
=============================================================================
 r1c-gateway — LuCI 控制器（需求 §27 站点配置 / §50 状态可视化的网页化）
 菜单：服务 → R1C 网关 → 站点配置 / 应用与校验 / 运行状态

 设计取舍（重要，别轻易改）：
 1) **不用 CBI**，手写模板 + POST 处理。
    理由：CBI 需要额外装 luci-compat 包（多一个依赖、多一个失败点）；
    而我们需要精确控制两件 CBI 不擅长的事：
      - PLC_DEVICES 是**多行**的 name|ip|type|desc 清单
      - 私钥/PSK 要写进 /etc/r1c/*.key（600），页面只显示"已配置"、绝不回显明文
    手写后这些逻辑集中在一个文件里，也更好排查。

 2) **页面只写 site.conf / 密钥文件，不直接改 UCI**。
    真正生效仍走 r1c-apply —— 保持"配置源唯一"，避免网页改的和脚本改的打架。

 3) 应用动作放**后台**（setsid）执行：
    r1c-apply 会重启网络/防火墙，同步执行会把 HTTP 请求一起拖死，
    页面表现为"转圈直到超时"，而后端的活其实已经做完了。
=============================================================================
--]]
module("luci.controller.r1c-gateway", package.seeall)

local sys  = require "luci.sys"
local http = require "luci.http"
local tpl  = require "luci.template"
local fs   = require "nixio.fs"
-- build_url 走 dispatcher 模块表取，不用裸 build_url：
-- dispatcher 注入给控制器 env 的是 entry/call/template/cbi/firstchild 这几个，
-- build_url 未必在注入列表里，写错就是运行期 nil 报错（构建期完全查不出来）。
local disp = require "luci.dispatcher"

local CONF    = "/etc/r1c/site.conf"
local KEYDIR  = "/etc/r1c"
local PRIVF   = KEYDIR .. "/wg-private.key"
local PSKF    = KEYDIR .. "/wg-preshared.key"
local LOGF    = "/tmp/r1c-apply.log"
local RUNF    = "/tmp/r1c-apply.running"

-- 表单字段（顺序即页面顺序）
--   name 表单名 / key  site.conf 里的键 / type 控件 / options 下拉项 / hint 说明
local FIELDS = {
    { name = "site_id",  key = "SITE_ID",  type = "text",
      label = "站点 ID", hint = "例：SITE001。多站点必须唯一" },
    { name = "plc_role", key = "PLC_ROLE", type = "select", options = { "host", "gateway" },
      label = "PLC 角色",
      hint = "host = 只占网段内一个 IP（现场网关不动）；gateway = R1C 自己做 PLC 网段网关" },
    { name = "plc_network", key = "PLC_NETWORK", type = "text",
      label = "PLC 网段", hint = "例：192.168.10.0/24" },
    { name = "plc_local_ip", key = "PLC_LOCAL_IP", type = "text",
      label = "本机 IP（host 角色）", hint = "host 模式下 R1C 占用的地址，例 192.168.10.254" },
    { name = "plc_gateway", key = "PLC_GATEWAY", type = "text",
      label = "网关 IP（gateway 角色）", hint = "gateway 模式下 R1C 占用的地址" },
    { name = "plc_wan_access", key = "PLC_WAN_ACCESS", type = "select", options = { "deny", "allow" },
      label = "PLC 能否上公网", hint = "工业现场通常 deny" },
    { name = "plc_snat", key = "PLC_SNAT", type = "select", options = { "auto", "1", "0" },
      label = "工程师访问 PLC 时做 SNAT",
      hint = "auto = gateway 关、host 开（host 不开则 PLC 回包走现场原网关，工程师收不到响应）" },
    { name = "plc_devices", key = "PLC_DEVICES", type = "textarea", rows = 5, multi = true,
      label = "PLC 设备清单",
      hint = "每行：名称|IP|类型|描述，类型 s7=西门子(:102) ab=罗克韦尔(:44818)。空行与 # 开头忽略" },
    { name = "vpn_addr", key = "VPN_ADDR", type = "text",
      label = "本机隧道地址", hint = "例：10.0.0.9/32。必须带 /32，否则会误把默认路由塞进隧道" },
    { name = "wg_endpoint", key = "WG_ENDPOINT", type = "text",
      label = "WG 服务端端点", hint = "例：www.example.com:51820。写域名（家里公网 IP 会变）" },
    { name = "wg_peer_public_key", key = "WG_PEER_PUBLIC_KEY", type = "text",
      label = "服务端公钥", hint = "服务端 wg show 里的 public key" },
    { name = "wg_peer_allowed_ips", key = "WG_PEER_ALLOWED_IPS", type = "text",
      label = "AllowedIPs（本端侧）",
      hint = "**本端**走隧道路由的网段，例 10.0.0.0/24。⚠️ 千万别填 0.0.0.0/0，会把默认路由劫进隧道" },
    { name = "wg_keepalive", key = "WG_KEEPALIVE", type = "text",
      label = "Keepalive（秒）", hint = "NAT/4G/手机热点后必须开，25" },
    { name = "wifi_ssid", key = "WIFI_SSID", type = "text",
      label = "上行 Wi-Fi SSID", hint = "手机热点上网时填" },
    { name = "wifi_key", key = "WIFI_KEY", type = "password",
      label = "上行 Wi-Fi 密码", hint = "" },
    { name = "auto_apply", key = "AUTO_APPLY", type = "select", options = { "0", "1" },
      label = "开机自动应用",
      hint = "出厂必须 0。现场调通后再改 1；调试期保持 0 更安全" },
}

-- ---------------------------------------------------------------- 读写 site.conf
-- ⚠️ 只有 PLC_DEVICES 是多行值。绝不能"看到 KEY=\"\" 就当多行"：
--    配置文件里 PLC_UPSTREAM_GW="" / PLC_MAP_NETWORK="" 都是**单行空值**，
--    按空值判断多行会把后面所有行吞进它的值里（会把配置文件读坏）。
local MULTI_KEYS = { PLC_DEVICES = true }

local function read_conf()
    local t = {}
    local f = io.open(CONF, "r")
    if not f then return t end
    local multi = nil
    for line in f:lines() do
        if multi then
            if line:match('^%s*"%s*$') then
                multi = nil
            else
                t[multi] = (t[multi] or "") .. line .. "\n"
            end
        else
            local k, v = line:match('^%s*([%w_]+)="(.*)"%s*$')
            if k then
                if MULTI_KEYS[k] and v == "" then
                    multi = k
                    t[k] = ""
                else
                    t[k] = v
                end
            end
        end
    end
    f:close()
    for k, v in pairs(t) do t[k] = tostring(v):gsub("\n+$", "") end
    return t
end

-- 逐行重写，**保留原文件所有注释与未管理的键**
local function write_conf(new)
    local f = io.open(CONF, "r")
    if not f then return false, "无法读取 " .. CONF end
    local out, skip, seen = {}, nil, {}
    for line in f:lines() do
        if skip then
            if line:match('^%s*"%s*$') then
                table.insert(out, new[skip] or "")
                table.insert(out, '"')
                seen[skip] = true
                skip = nil
            end
        else
            local k = line:match('^%s*([%w_]+)="')
            if k and MULTI_KEYS[k] then
                table.insert(out, k .. '="')
                skip = k
            elseif k and new[k] ~= nil then
                table.insert(out, k .. '="' .. new[k] .. '"')
                seen[k] = true
            else
                table.insert(out, line)
            end
        end
    end
    f:close()
    -- 文件里不存在的键补到末尾（避免"页面填了但文件里没这行"导致静默丢失）
    for _, fd in ipairs(FIELDS) do
        if new[fd.key] ~= nil and not seen[fd.key] then
            table.insert(out, fd.key .. '="' .. new[fd.key] .. '"')
        end
    end
    fs.writefile(CONF, table.concat(out, "\n") .. "\n")
    return true
end

-- ---------------------------------------------------------------- 表单收集
local function trim(s)
    return tostring(s or ""):gsub("\r", ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function collect()
    local new, seen = {}, {}
    for _, fd in ipairs(FIELDS) do
        local v = http.formvalue(fd.name)
        if v == nil then v = "" end
        v = trim(v)
        if fd.multi then
            -- 多行：允许换行，但禁止双引号（会截断 shell 字符串）
            if v:find('"', 1, true) then
                return nil, fd.label .. " 不能包含双引号"
            end
        else
            -- 单行：禁止引号、反斜杠、换行 —— 这些会破坏 KEY="value" 的结构
            if v:find('["\\\n]') then
                return nil, fd.label .. " 不能包含引号/反斜杠/换行"
            end
        end
        new[fd.key] = v
        seen[fd.key] = true
    end
    return new
end

local function write_keyfile(path, content)
    content = trim(content)
    if content == "" then return false end
    fs.writefile(path, content .. "\n")
    os.execute(string.format("chmod 600 %q", path))
    return true
end

-- ---------------------------------------------------------------- 路由
function index()
    entry({ "admin", "services", "r1c-gateway" }, firstchild(), "R1C 网关", 60).dependent = false
    entry({ "admin", "services", "r1c-gateway", "config" }, call("action_config"), "站点配置", 10)
    entry({ "admin", "services", "r1c-gateway", "apply" },  call("action_apply"),  "应用与校验", 20)
    entry({ "admin", "services", "r1c-gateway", "status" }, call("action_status"), "运行状态", 30)
    -- 无标题 = 不进菜单（纯数据接口）
    entry({ "admin", "services", "r1c-gateway", "status_json" }, call("action_status_json"))
end

function action_config()
    local msg, errmsg
    if http.formvalue("save") then
        local new, err = collect()
        if new then
            local ok, e = write_conf(new)
            if not ok then
                errmsg = e
            else
                local n1 = write_keyfile(PRIVF, http.formvalue("wg_private_key"))
                local n2 = write_keyfile(PSKF,   http.formvalue("wg_preshared_key"))
                msg = "已写入 " .. CONF
                if n1 then msg = msg .. "；私钥已更新" end
                if n2 then msg = msg .. "；PSK 已更新" end
                msg = msg .. "。下一步：到「应用与校验」执行校验并应用。"
            end
        else
            errmsg = err
        end
    end

    tpl.render("r1c-gateway/config", {
        fields     = FIELDS,
        vals       = read_conf(),
        msg        = msg,
        errmsg     = errmsg,
        has_priv   = fs.access(PRIVF) == true,
        has_psk    = fs.access(PSKF) == true,
        apply_url  = disp.build_url("admin", "services", "r1c-gateway", "apply"),
        status_url = disp.build_url("admin", "services", "r1c-gateway", "status"),
    })
end

function action_apply()
    local out, running = "", fs.access(RUNF) == true
    local act = http.formvalue("do")

    if act == "check" then
        -- 校验不改动网络，同步执行、直接回显
        out = sys.exec("/usr/bin/r1c-apply --check 2>&1")
    elseif act == "apply" then
        -- ⚠️ 必须后台：r1c-apply 会重启网络/防火墙，同步跑会把 HTTP 请求一起拖死
        os.execute(string.format(
            'rm -f %q; setsid sh -c %q >/dev/null 2>&1 &',
            LOGF,
            string.format('touch %s; /usr/bin/r1c-apply >%s 2>&1; rm -f %s', RUNF, LOGF, RUNF)))
        http.redirect(disp.build_url("admin", "services", "r1c-gateway", "apply"))
        return
    end

    if fs.access(LOGF) then out = fs.readfile(LOGF) or "" end
    tpl.render("r1c-gateway/apply", {
        out        = out,
        running    = running,
        config_url = disp.build_url("admin", "services", "r1c-gateway", "config"),
    })
end

function action_status()
    tpl.render("r1c-gateway/status", {
        json_url   = disp.build_url("admin", "services", "r1c-gateway", "status_json"),
        config_url = disp.build_url("admin", "services", "r1c-gateway", "config"),
        apply_url  = disp.build_url("admin", "services", "r1c-gateway", "apply"),
    })
end

function action_status_json()
    http.prepare_content("application/json")
    http.write(sys.exec("/usr/bin/r1c-status --json 2>/dev/null"))
end
