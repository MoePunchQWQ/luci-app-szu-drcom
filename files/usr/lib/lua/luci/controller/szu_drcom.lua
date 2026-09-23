--[[
LuCI controller for the Shenzhen University Dr.COM ePortal client.

Menu:  Services -> SZU DrCOM
Config: /etc/config/drcom_szu  (UCI package drcom_szu, section main)
--]]

module("luci.controller.szu_drcom", package.seeall)

local UCI_PKG = "drcom_szu"
local UCI_SEC = "main"
local STATE_FILE = "/tmp/szu-drcom.state"
local LOG_FILE = "/tmp/szu-drcom.log"
local INIT_PATH = "/etc/init.d/drcom_szu"
local CLIENT = "/usr/bin/szu-drcom"
local PROG = "szu-drcom"

local OPTION_NAMES = {
	"enabled",
	"username",
	"password",
	"portal_host",
	"portal_port",
	"ac_ip",
	"ac_name",
	"login_method",
	"status_path",
	"login_path",
	"logout_path",
	"wlan_user_ip",
	"wlan_user_mac",
	"ifname",
	"auto_login",
	"interval",
	"timeout",
	"startup_delay",
}

local json = nil
do
	local ok, lib = pcall(require, "luci.jsonc")
	if ok then
		json = lib
	else
		ok, lib = pcall(require, "luci.json")
		if ok then
			json = lib
		end
	end
end

local function trim(value)
	return tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function tr(text)
	local ok, i18n = pcall(require, "luci.i18n")
	if ok and i18n.translate then
		return i18n.translate(text)
	end
	return text
end

local function msg(key, text)
	return { key = key, text = tr(text) }
end

-- --------------------------------------------------------------------------
-- helpers
-- --------------------------------------------------------------------------

local function write_json(payload)
	local http = require "luci.http"
	http.prepare_content("application/json")
	if json and json.stringify then
		http.write(json.stringify(payload))
	else
		http.write("{}")
	end
end

-- UCI is read and written through the uci(1) CLI on purpose. luci.model.uci
-- pulls in libuci-lua, which is not shipped by every firmware (and is absent
-- from some package repos), while uci(1) is always available -- the client
-- script already relies on it. Keeping this out of Lua drops a dependency.
local function shquote(value)
	return "'" .. tostring(value or ""):gsub("'", "'\\''") .. "'"
end

-- Reads the whole section with one uci(1) call; snapshot() runs every few
-- seconds, so forking per option would be wasteful.
local function read_config()
	local sys = require "luci.sys"
	local values = {}
	for _, name in ipairs(OPTION_NAMES) do
		values[name] = ""
	end
	local dump = sys.exec(string.format("uci -q show %s 2>/dev/null", UCI_PKG)) or ""
	for line in dump:gmatch("[^\r\n]+") do
		local key, value = line:match("^" .. UCI_PKG .. "%.[%w_]+%.([%w_]+)%s*=%s*(.-)%s*$")
		if key and values[key] ~= nil then
			values[key] = (value:gsub("^'(.*)'$", "%1"):gsub('^"(.*)"$', "%1"))
		end
	end
	return values
end

local function write_config(values)
	local sys = require "luci.sys"
	local commands = {}
	for _, name in ipairs(OPTION_NAMES) do
		local value = values[name]
		if value ~= nil then
			commands[#commands + 1] = string.format(
				"uci -q set %s.%s.%s=%s", UCI_PKG, UCI_SEC, name, shquote(value))
		end
	end
	commands[#commands + 1] = "uci -q commit " .. UCI_PKG
	return sys.call(table.concat(commands, " ; ")) == 0
end

local function read_state()
	local fs = require "nixio.fs"
	local data = fs.readfile(STATE_FILE) or ""
	local state = {
		status = "unknown",
		message = "",
		ip = "",
		account = "",
		updated = "",
		last_login = "",
		login_count = "0",
	}
	for line in data:gmatch("[^\r\n]+") do
		local key, value = line:match("^%s*([%w_]+)%s*=%s*(.-)%s*$")
		if key and state[key] ~= nil then
			state[key] = value
		end
	end
	return state
end

local function read_log(limit)
	local fs = require "nixio.fs"
	local data = fs.readfile(LOG_FILE) or ""
	local lines = {}
	for line in data:gmatch("[^\r\n]+") do
		lines[#lines + 1] = line
	end
	local start = #lines - limit + 1
	if start < 1 then
		start = 1
	end
	local out = {}
	for i = start, #lines do
		out[#out + 1] = lines[i]
	end
	return table.concat(out, "\n")
end

local function service_running()
	local sys = require "luci.sys"
	return sys.call("pidof " .. PROG .. " >/dev/null 2>&1") == 0
end

local function service_enabled()
	local sys = require "luci.sys"
	return sys.call("ls /etc/rc.d/S*drcom_szu >/dev/null 2>&1") == 0
end

local function shell(command)
	local sys = require "luci.sys"
	return trim(sys.exec(command .. " 2>&1"))
end

local function shell_ok(command)
	local sys = require "luci.sys"
	return sys.call(command .. " >/dev/null 2>&1") == 0
end

-- --------------------------------------------------------------------------
-- CSRF
-- --------------------------------------------------------------------------

local function valid_token()
	local http = require "luci.http"
	local disp = require "luci.dispatcher"
	local expected = trim((disp.context and disp.context.authtoken) or "")
	if expected == "" then
		return true
	end
	return trim(http.formvalue("token")) == expected
end

-- --------------------------------------------------------------------------
-- snapshot
-- --------------------------------------------------------------------------

local function snapshot()
	local config = read_config()
	local state = read_state()

	return {
		ok = true,
		state = state,
		config = config,
		service = {
			running = service_running(),
			enabled = service_enabled(),
			installed = require("nixio.fs").access(CLIENT),
		},
		paths = {
			config = "/etc/config/" .. UCI_PKG,
			log = LOG_FILE,
		},
		updated_at = os.date("%Y-%m-%d %H:%M:%S"),
	}
end

-- --------------------------------------------------------------------------
-- actions
-- --------------------------------------------------------------------------

local function do_action(action)
	local sys = require "luci.sys"

	if action == "login" or action == "logout" then
		if not require("nixio.fs").access(CLIENT) then
			return false, msg("action.clientMissing", "客户端程序缺失，请重新安装插件。")
		end
		local out = shell(CLIENT .. " " .. action)
		local ok = sys.call("test -f " .. STATE_FILE) == 0
		local state = read_state()
		if state.status == "online" and action == "login" then
			ok = true
		end
		if state.status == "offline" and action == "logout" then
			ok = true
		end
		if state.status == "error" then
			ok = false
		end
		local text = out
		if text == "" then
			text = state.message
		end
		if text == "" then
			text = tr(action == "login" and "登录指令已执行。" or "下线指令已执行。")
		end
		return ok, { key = "action.result", text = text }
	end

	if action == "probe" then
		local out = shell(CLIENT .. " probe")
		return true, { key = "action.probe", text = out }
	end

	local allowed = { start = true, stop = true, restart = true, enable = true, disable = true }
	if not allowed[action] then
		return false, msg("action.unsupported", "不支持的操作。")
	end

	if not require("nixio.fs").access(INIT_PATH) then
		return false, msg("action.scriptMissing", "服务脚本缺失或不可执行。")
	end

	if not shell_ok(INIT_PATH .. " " .. action) then
		return false, msg("action.commandFailed", "服务命令执行失败。")
	end

	return true, msg("action.done", "操作已提交。")
end

-- --------------------------------------------------------------------------
-- menu
-- --------------------------------------------------------------------------

function index()
	-- Note: "dependent" is not part of the modern menu schema (LuCI 23+ builds
	-- the tree in ucode and ignores it), and on older LuCI it can hide a
	-- childless node outright. Leave it unset so the entry is always visible.
	entry({ "admin", "services", "szu_drcom" }, call("action_index"), tr("SZU DrCOM"), 60)

	entry({ "admin", "services", "szu_drcom", "status" }, call("action_status")).leaf = true
	entry({ "admin", "services", "szu_drcom", "logs" }, call("action_logs")).leaf = true
	entry({ "admin", "services", "szu_drcom", "action" }, call("action_do")).leaf = true
end

function action_status()
	write_json(snapshot())
end

function action_logs()
	write_json({
		ok = true,
		logs = read_log(200),
		updated_at = os.date("%Y-%m-%d %H:%M:%S"),
	})
end

function action_do()
	local http = require "luci.http"

	if http.getenv("REQUEST_METHOD") ~= "POST" then
		http.status(405, "Method Not Allowed")
		write_json({ ok = false, error = tr("请使用 POST 请求。") })
		return
	end

	if not valid_token() then
		http.status(403, "Forbidden")
		write_json({ ok = false, error = tr("请求令牌校验失败，请刷新页面后重试。") })
		return
	end

	local action = trim(http.formvalue("action"))
	local ok, message = do_action(action)
	local payload = snapshot()
	payload.ok = ok
	payload.action = action
	payload.message = message and message.text or nil
	if not ok then
		payload.error = message and message.text or nil
	end
	write_json(payload)
end

function action_index()
	local http = require "luci.http"
	local tpl = require "luci.template"
	local disp = require "luci.dispatcher"

	local token = (disp.context and disp.context.authtoken) or ""
	local message = nil
	local message_type = "success"

	if http.getenv("REQUEST_METHOD") == "POST" then
		if not valid_token() then
			http.status(403, "Forbidden")
			message = tr("请求令牌校验失败，请刷新页面后重试。")
			message_type = "error"
		else
			local new_values = {}
			for _, name in ipairs(OPTION_NAMES) do
				local value = http.formvalue(name)
				if name == "enabled" or name == "auto_login" then
					-- An unchecked checkbox is not submitted at all, so an
					-- absent value has to be stored explicitly as "0".
					value = (value == "1") and "1" or "0"
				elseif value ~= nil then
					value = trim(value)
				end
				if value ~= nil then
					new_values[name] = value
				end
			end
			if write_config(new_values) then
				message = tr("配置已保存。")
				message_type = "success"
			else
				message = tr("配置写入失败，请检查 /etc/config 是否可写。")
				message_type = "error"
			end

			if require("nixio.fs").access(INIT_PATH) then
				shell_ok(INIT_PATH .. " restart")
			end
		end
	end

	tpl.render("szu_drcom/status", {
		token = token,
		message = message,
		message_type = message_type,
		status = snapshot(),
		logs = read_log(200),
		status_url = disp.build_url("admin", "services", "szu_drcom", "status"),
		logs_url = disp.build_url("admin", "services", "szu_drcom", "logs"),
		action_url = disp.build_url("admin", "services", "szu_drcom", "action"),
	})
end
