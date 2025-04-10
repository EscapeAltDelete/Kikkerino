local RECONNECT_DELAY_SECONDS = 10
local PUSHER_APP_KEY = "32cbd69e4b950bf97679"
local PUSHER_URL_BASE = "wss://ws-us2.pusher.com/app/" .. PUSHER_APP_KEY
local PUSHER_PARAMS = "?protocol=7&client=js&version=8.4.0&flash=false"
local PUSHER_CHAT_EVENT = "App\\Events\\ChatMessageEvent"

local json = require("dkjson")
if not json then c2.log(c2.LogLevel.Critical, "[KickChatWS] FATAL: dkjson.lua not found!"); return end

local ws_connection = nil
local target_chatterino_channel = nil
local current_channel_name = nil
local current_chatroom_id = nil
local is_connected = false
local should_be_connected = false

local function log_err(...) c2.log(c2.LogLevel.Critical, "[KickChatWS" .. (current_channel_name and ("/" .. current_channel_name) or "") .. "]", ...) end

local function add_status_msg(text)
    if target_chatterino_channel then pcall(target_chatterino_channel.add_system_message, target_chatterino_channel, text) end
end

local function send_ws_message(payload_table)
    if not ws_connection or not is_connected then return end
    local ok, json_payload = pcall(json.encode, payload_table)
    if ok then
        local send_ok, send_err = pcall(ws_connection.send_text, ws_connection, json_payload)
        if not send_ok then log_err("Failed send:", send_err) end
    else
        log_err("Failed encode:", json_payload)
    end
end

local function send_pusher_event(event_name, data_table) send_ws_message({ event = event_name, data = data_table or {} }) end

local connect_websocket
local disconnect_websocket
local schedule_reconnect

local function handle_incoming_message(payload_str)
    local ok, pusher_msg = pcall(json.decode, payload_str)
    if not ok or type(pusher_msg) ~= "table" then log_err("Failed decode/parse incoming:", pusher_msg); return end
    local event = pusher_msg.event
    local data = pusher_msg.data
    if event == "pusher:connection_established" then
        if is_connected then return end
        is_connected = true; send_pusher_event("pusher:subscribe", { channel = "chatrooms." .. current_chatroom_id .. ".v2", auth = "" })
        add_status_msg("Connected to Kick/" .. current_channel_name)
    elseif event == "pusher:ping" then send_pusher_event("pusher:pong")
    elseif event == PUSHER_CHAT_EVENT then
        if pusher_msg.channel == ("chatrooms." .. current_chatroom_id .. ".v2") and data and type(data) == "string" then
            local inner_ok, msg_data = pcall(json.decode, data)
            if inner_ok and type(msg_data) == "table" then
                if msg_data.content and msg_data.sender and msg_data.sender.username then
                    if target_chatterino_channel then pcall(target_chatterino_channel.add_system_message, target_chatterino_channel, "[Kick] " .. msg_data.sender.username .. ": " .. msg_data.content) end
                end
            end
        end
    elseif event == "pusher:error" then
        local error_message = pusher_msg.data and type(pusher_msg.data) == 'table' and pusher_msg.data.message
        if not (error_message and string.find(error_message, "Pusher protocol versions <= 3 have been deprecated", 1, true)) then
           log_err("Pusher error:", error_message or "Unknown")
           add_status_msg("Pusher error: " .. (error_message or "Unknown"))
        end
    end
end

local function on_websocket_close()
    local was_unexpected = (ws_connection ~= nil)
    is_connected = false; ws_connection = nil
    if current_channel_name then add_status_msg("Disconnected from Kick/" .. current_channel_name) end
    if was_unexpected and should_be_connected and current_chatroom_id then schedule_reconnect() end
end

connect_websocket = function()
    if ws_connection or is_connected or not should_be_connected or not current_chatroom_id or not target_chatterino_channel then return end
    add_status_msg("Connecting to Kick/" .. current_channel_name .. "...")
    local success, result = pcall(c2.WebSocket.new, PUSHER_URL_BASE .. PUSHER_PARAMS, {
        headers = { Origin = "https://kick.com", UserAgent = "C2/Plugin" },
        on_text = handle_incoming_message, on_close = on_websocket_close
    })
    if not success or not result then
        log_err("WS connect failed:", result or "nil")
        add_status_msg("Connection error.")
        ws_connection = nil; is_connected = false
        if should_be_connected then schedule_reconnect() end
    else ws_connection = result end
end

disconnect_websocket = function(called_from_error)
    if not called_from_error then should_be_connected = false end
    local was_connected = ws_connection ~= nil
    local previous_name = current_channel_name
    current_channel_name = nil; current_chatroom_id = nil
    if ws_connection then pcall(ws_connection.close, ws_connection); ws_connection = nil end
    is_connected = false
    if not called_from_error and was_connected and previous_name then add_status_msg("Disconnected from Kick/" .. previous_name) end
end

schedule_reconnect = function()
    if not should_be_connected or is_connected or ws_connection or not current_chatroom_id then return end
    c2.later(function() if should_be_connected and not is_connected and not ws_connection and current_chatroom_id then connect_websocket() end end, RECONNECT_DELAY_SECONDS * 1000)
end

local function fetch_kick_channel_id(channel_name_to_lookup, callback_on_success)
    add_status_msg("Looking up Kick '" .. channel_name_to_lookup .. "'...")
    local request = c2.HTTPRequest.create(c2.HTTPMethod.Get, "https://kick.com/api/v2/channels/" .. channel_name_to_lookup)
    request:set_timeout(10000)
    request:set_header("Accept", "application/json"); request:set_header("User-Agent", "C2/Plugin")
    request:on_success(function(res)
        local status = res:status(); local body = res:data()
        if status == 200 then
            local decode_ok, data_table = pcall(json.decode, body)
            if decode_ok and type(data_table)=='table' and data_table.chatroom and data_table.chatroom.id then
                callback_on_success(channel_name_to_lookup, tostring(data_table.chatroom.id))
            else log_err("API JSON error:", body); add_status_msg("API response error."); should_be_connected=false end
        else add_status_msg("API Error: " .. (status==404 and "Not found." or "Status "..status)); should_be_connected=false end
    end)
    request:on_error(function(res) log_err("API net error:", res:error()); add_status_msg("API Network Error."); should_be_connected=false end)
    request:execute()
end

local function cmd_kick_handler(ctx)
    if not ctx.words or #ctx.words == 0 then add_status_msg("Usage: /k <channel> | /k"); return end
    if #ctx.words >= 2 then
        local requested_name = ctx.words[2]
        if not requested_name then add_status_msg("Usage: /k <channel> | /k"); return end
        requested_name = string.lower(requested_name)
        if current_channel_name == requested_name and (is_connected or should_be_connected) then add_status_msg("Already on '"..requested_name.."'."); return end
        if is_connected or should_be_connected then disconnect_websocket(false) end
        target_chatterino_channel = ctx.channel; should_be_connected = true
        fetch_kick_channel_id(requested_name, function(found_name, found_id)
            current_channel_name = found_name; current_chatroom_id = found_id
            if should_be_connected then connect_websocket() end
        end)
    elseif #ctx.words == 1 then
        if not should_be_connected and not is_connected then add_status_msg("Not connected."); return end
        disconnect_websocket(false)
        if target_chatterino_channel == ctx.channel then target_chatterino_channel = nil end
    else add_status_msg("Usage: /k <channel> | /k") end
end

c2.log(c2.LogLevel.Info, "[KickChatWS] Loading...")
c2.register_command("/k", cmd_kick_handler) 
add_status_msg("Loaded. /k <channel> | /k")