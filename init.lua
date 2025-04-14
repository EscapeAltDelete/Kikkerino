local RECONNECT_DELAY_SECONDS = 10
local PUSHER_APP_KEY = "32cbd69e4b950bf97679"
local PUSHER_URL_BASE = "wss://ws-us2.pusher.com/app/" .. PUSHER_APP_KEY
local PUSHER_PARAMS = "?protocol=7&client=js&version=8.4.0"
local PUSHER_CHAT_EVENT = "App\Events\ChatMessageEvent"
local API_CHANNEL_URL = "https://kick.com/api/v2/channels/"
local API_SEND_URL_BASE = "https://kick.com/api/v2/messages/send/"

local json = require("dkjson")

local ws = nil
local chan = nil
local name = nil
local id = nil
local connected = false
local should_connect = false
local token = nil

local function add_msg(text) if chan then chan:add_system_message(text) end end

local function send_ws(payload_table)
if not ws or not connected then return end
local ok, payload_json = pcall(json.encode, payload_table)
if ok then ws:send_text(payload_json) end
end

local function send_pusher(event_name, data_table) send_ws({ event = event_name, data = data_table or {} }) end

local connect_ws
local disconnect_ws
local schedule_reconnect

local function handle_incoming(payload_str)
local ok, msg = pcall(json.decode, payload_str)
if not ok or type(msg) ~= "table" then return end
local event = msg.event
if event == "pusher:connection_established" then
if connected then return end
connected = true; send_pusher("pusher:subscribe", { channel = "chatrooms." .. id .. ".v2", auth = "" })
add_msg("Connected to kick.com/" .. name)
elseif event == "pusher:ping" then send_pusher("pusher:pong")
elseif event == PUSHER_CHAT_EVENT then
if msg.channel == ("chatrooms." .. id .. ".v2") and msg.data and type(msg.data) == "string" then
local ok_msg, msg_data = pcall(json.decode, msg.data)
if ok_msg and type(msg_data) == "table" and msg_data.content and msg_data.sender and msg_data.sender.username and chan then
chan:add_system_message(msg_data.sender.username .. ": " .. msg_data.content)
end
end
end
end

local function on_ws_close()
local reconnect_needed = (ws ~= nil)
connected = false; ws = nil
if reconnect_needed and should_connect and id then schedule_reconnect() end
end

connect_ws = function()
if ws or connected or not should_connect or not id or not chan then return end
ws = c2.WebSocket.new(PUSHER_URL_BASE .. PUSHER_PARAMS, { headers = { Origin = "https://kick.com", UserAgent = "C2/Plugin/Kikkerino" }, on_text = handle_incoming, on_close = on_ws_close })
end

disconnect_ws = function()
should_connect = false
local was_connected = ws ~= nil
local prev_name = name
name = nil; id = nil
if ws then ws:close(); ws = nil end
connected = false
if was_connected and prev_name then add_msg("Disconnected from kick.com/" .. prev_name) end
end

schedule_reconnect = function()
if not should_connect or connected or ws or not id then return end
c2.later(function() if should_connect and not connected and not ws and id then connect_ws() end end, RECONNECT_DELAY_SECONDS * 1000)
end

local function fetch_id(lookup_name, callback)
local req = c2.HTTPRequest.create(c2.HTTPMethod.Get, API_CHANNEL_URL .. lookup_name)
req:set_header("Accept", "application/json"); req:set_header("User-Agent", "C2/Plugin/Kikkerino")
req:on_success(function(res)
if res:status() == 200 then
local ok, data = pcall(json.decode, res:data())
if ok and type(data) == 'table' and data.chatroom and data.chatroom.id then
callback(lookup_name, data.chatroom.id)
else
name = nil; id = nil; should_connect = false; add_msg("API structure error.")
end
else
name = nil; id = nil; should_connect = false; add_msg("API lookup failed.")
end
end)
req:on_error(function(res) name = nil; id = nil; should_connect = false; add_msg("API network error.") end)
req:execute()
end

local function send_msg(content)
if not id or not content or content == "" or not token then return end
local payload_json = json.encode({ content = content, type = "message" })
local req = c2.HTTPRequest.create(c2.HTTPMethod.Post, API_SEND_URL_BASE .. id)
req:set_header("Content-Type", "application/json"); req:set_header("Accept", "application/json"); req:set_header("User-Agent", "C2/Plugin/Kikkerino")
req:set_header("Authorization", "Bearer " .. token)
req:set_payload(payload_json)
req:execute()
end

local function cmd_k(ctx)
chan = ctx.channel
if not ctx.words or #ctx.words == 0 then return end
if #ctx.words >= 2 then
local new_name = string.lower(ctx.words[2])
if not new_name or (name == new_name and (connected or should_connect)) then return end
if connected or should_connect then disconnect_ws() end
name = new_name; id = nil; should_connect = true
fetch_id(new_name, function(found_name, found_id)
if should_connect and name == found_name then
id = found_id; connect_ws()
end
end)
elseif #ctx.words == 1 then
if should_connect or connected then disconnect_ws(); chan = nil end
end
end

local function cmd_ks(ctx)
chan = ctx.channel
if not ctx.words or #ctx.words < 2 or not id then return end
table.remove(ctx.words, 1)
send_msg(table.concat(ctx.words, " "))
end

local function cmd_kt(ctx)
chan = ctx.channel
if not ctx.words or #ctx.words < 2 or ctx.words[2] == "" then token = nil; return end
token = ctx.words[2]; add_msg("Token set.")
end

c2.register_command("/k", cmd_k)
c2.register_command("/ks", cmd_ks)
c2.register_command("/kt", cmd_kt)
add_msg("Kikkerino loaded.")