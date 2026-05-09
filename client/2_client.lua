package.cpath = "skynet/luaclib/?.so;luaclib/?.so"
package.path = "skynet/lualib/?.lua;examples/?.lua;lualib/?.lua;./etc/?.lua"
io.stdout:setvbuf("no")

local socket = require "client.socket"
local pb = require "protobuf"
local cjson = require "cjson"
local proto_map = require "proto_map"
local srp = require "srp"
local kcp=require"kcp"
local client, A
local M1, err
local username
--kcp会话
local battle

local function now_ms()
    --应该用单调时钟
    return socket.time_ms()
end

--战斗会话
local function new_session(conv)
    return {
        conv=conv,
        host = nil,
        port=nil,
        token=nil,
        udp_fd=nil,
        kcp = nil,
        ready_seq=0,--第二次握手的challege
        next_update=0,--kcp下一次update的时间
        input_seq=0,
        scene_ready=false,--场景首帧是否到达
        ready=false,--三次握手是否完成
        last_ack=0,
        input_state = {
            target_x = 0,
            target_y = 0,
            moving = false,
            pending_split = false,
            pending_spit = false,
        }
    }
end
--输入间隔时间
local INPUT_INTERVAL_MS = 50


local function proto_unpack(buff)
    local len = string.len(buff)
    if len < 2 then
        return
    end
    local namelen_format = string.format("> I2 c%d", len - 2)
    local namelen, other = string.unpack(namelen_format, buff)

    local bodylen = len - 2 - namelen
    local format = string.format("> c%d c%d", namelen, bodylen)
    local cmd, bodybuff = string.unpack(format, other)

    local map = proto_map[cmd]
    if not map then
        print("未注册的命令： " .. cmd)
        return
    end

    local proto_type = map.res or map.notify
    if not proto_type then
        print("命令没有可解包的响应/广播类型： " .. cmd)
        return
    end

    local isok, msg = pcall(pb.decode, proto_type, bodybuff)
    if not isok or not msg then
        print("解包失败")
        return
    end

    if pb.extract then
        pb.extract(msg)
    end

    return cmd, msg
end

local function proto_pack(cmd, msg)
    local map = proto_map[cmd]
    if not map or not map.req then
        return nil, "命令不存在或不可请求: " .. tostring(cmd)
    end

    local proto_type = map.req
    msg[1] = nil

    local ok, body = pcall(pb.encode, proto_type, msg)
    if not ok or not body then
        return nil, "编码失败: " .. tostring(body)
    end

    local namelen = string.len(cmd)
    local bodylen = string.len(body)
    local len = bodylen + namelen + 2
    local format = string.format("> I2 I2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, len, namelen, cmd, body)
    return buff, nil
end

--为udp打包的
local function proto_pack_udp(cmd, msg)
    local map = proto_map[cmd]
    if not map or not map.req then
        return nil, "命令不存在或不可请求: " .. tostring(cmd)
    end

    msg[1] = nil

    local ok, body = pcall(pb.encode, map.req, msg)
    if not ok or not body then
        return nil, "编码失败: " .. tostring(body)
    end

    local namelen = string.len(cmd)
    local bodylen = string.len(body)
    local format = string.format("> I2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, namelen, cmd, body)
    return buff, nil
end


pb.register_file("./proto/game.pb")
local host = arg[1] or "192.168.164.129"
local port = tonumber(arg[2]) or 8001
local fd = socket.connect(host, port)

if not fd then
    print(string.format("连接失败: %s:%d", host, port))
    return
end

print(string.format("Connected to %s:%d", host, port))

local recv_buffer = ""
--负责从缓冲区拿出完整消息
local function take_from_buffer()
    if #recv_buffer < 2 then
        return nil
    end

    local content_len = string.unpack(">I2", recv_buffer)
    if #recv_buffer < 2 + content_len then
        return nil
    end

    local content = string.sub(recv_buffer, 3, 2 + content_len)
    recv_buffer = string.sub(recv_buffer, 3 + content_len)
    return content
end
--负责把接受消息并将消息拼接到缓冲区，顺便看看有没有完整消息，有的话返回
local function recv_package(fd)
    local content = take_from_buffer()
    if content then
        return content
    end

    local data = socket.recv(fd)
    --[[这里的api是data=nil是无数据，data=""是对端关闭连接]]
    if data == "" then
        content = take_from_buffer()
        if content then
            return content
        end
        return nil, "closed"
    end

    if data and #data > 0 then
        recv_buffer = recv_buffer .. data
        return take_from_buffer()
    end

    return nil
end

local function json_encode(value)
    local ok, text = pcall(cjson.encode, value)
    if ok then
        return text
    end
    return tostring(value)
end

--关闭kcp会话
local function close_battle_session()
    if battle and battle.udp_fd then
        socket.close(battle.udp_fd)
    end
    battle = nil
end
--驱动kcp
local function drive_battle(session)
    if not session or not session.kcp then
        return
    end
    local now = now_ms()
    session.kcp:update(now)
    session.next_update = session.kcp:check(now)
end
--发送kcp消息
local function battle_send_msg(cmd, msg)
    local session = battle
    if not session or not session.kcp then
        return false, "战斗链路未建立"
    end

    local payload, err = proto_pack_udp(cmd, msg)
    if not payload then
        return false, err
    end

    session.kcp:send(payload)
    drive_battle(session)
    return true
end

--建立kcp对象并发送认证
local function open_battle_session(enter_msg)
    close_battle_session()

    local session = new_session(enter_msg.battle_conv)
    session.host = enter_msg.battle_host
    session.port = enter_msg.battle_port
    session.token = enter_msg.battle_token
    session.udp_fd = socket.udp()

    session.kcp = kcp.create(session.conv, function(raw)
        socket.sendto(session.udp_fd, session.host, session.port, raw)
    end)

    session.kcp:nodelay(1, 10, 2, 1)
    session.kcp:wndsize(128, 128)
    session.kcp:setmtu(1200)
    session.kcp:minrto(10)

    battle = session

    local msg = {
        token = session.token,
    }
    local ok, err = battle_send_msg("battle_auth", msg)
    if not ok then
        print("battle_auth 发送失败:", err)
        close_battle_session()
        return
    end

    print(string.format(
        "Battle connected: %s:%d conv=%d",
        session.host,
        session.port,
        session.conv
    ))
    print("Battle Sent:", "battle_auth", json_encode(msg))
end
--展示或者处理kcp发来的战斗相关协议
local function handle_battle_message(cmd, msg)
    print("Battle Received:", cmd, json_encode(msg))

    if cmd == "battle_auth" then
        if msg.code ~= 0 then
            print("battle_auth 失败:", msg.msg)
            return
        end

        battle.ready_seq = msg.ready_seq or 0
        local ack_msg = {
            ready_seq = battle.ready_seq
        }

        local ok, err = battle_send_msg("battle_ready_ack", ack_msg)
        if not ok then
            print("battle_ready_ack 发送失败:", err)
            return
        end

        battle.ready = true
        print("Battle Sent:", "battle_ready_ack", json_encode(ack_msg))
        return
    end

    if cmd == "frame_update" then
        battle.last_ack = msg.ack or battle.last_ack
    end
    if cmd=="scene_snapshot" then
        battle.scene_ready = true
        battle.next_input_ms = now_ms()
    end
end
--udp循环读，读到包放入kcp对象，然后尝试取消息，取到后进行展示或者处理
local function dispatch_battle_packages()
    local session = battle
    if not session or not session.udp_fd or not session.kcp then
        return false, true
    end

    local got = false

    while true do
        local raw, from_host, from_port = socket.recvfrom(session.udp_fd)
        if not raw then
            break
        end

        got = true

        if from_host ~= session.host or from_port ~= session.port then
            goto continue
        end

        local ok, conv = pcall(kcp.getconv, raw)
        if not ok or conv ~= session.conv then
            goto continue
        end

        local ret = session.kcp:input(raw)
        if ret < 0 then
            goto continue
        end

        while true do
            local n, payload = session.kcp:recv()
            if n < 0 then
                break
            end

            local cmd, msg = proto_unpack(payload)
            if cmd and msg then
                handle_battle_message(cmd, msg)
            end
        end

        ::continue::
    end

    if session.kcp and session.next_update <= now_ms() then
        drive_battle(session)
    end

    return got, true
end

--更新输入状态
local function update_input_state(msg)
    if not battle then
        print("战斗链路未建立，请先 login 然后 enter")
        return true
    end

    local state = battle.input_state

    if msg.target_x ~= nil or msg.x ~= nil then
        state.target_x = msg.target_x or msg.x
    end
    if msg.target_y ~= nil or msg.y ~= nil then
        state.target_y = msg.target_y or msg.y
    end
    if msg.moving ~= nil then
        state.moving = not not msg.moving
    end
    if msg.split then
        state.pending_split = true
    end
    if msg.spit then
        state.pending_spit = true
    end

    print("Input State:", json_encode(state))
    return true
end
--发送inputframe
local function send_current_input_frame()
    local session = battle
    if not session or not session.ready or not session.scene_ready then
        return false
    end

    local state = session.input_state
    session.input_seq = session.input_seq + 1

    local msg = {
        input_seq = session.input_seq,
        target_x = state.target_x,
        target_y = state.target_y,
        moving = state.moving,
        split = state.pending_split,
        spit = state.pending_spit,
    }

    local ok, err = battle_send_msg("input_frame", msg)
    if not ok then
        print("input_frame 发送失败:", err)
        return false
    end

    print("Battle Sent:", "input_frame", json_encode(msg))

    state.pending_split = false
    state.pending_spit = false
    return true
end
--每50ms发送一次inputframe
local function flush_input_tick()
    local session = battle
    if not session or not session.ready or not session.scene_ready then
        return false
    end

    local now = now_ms()
    if session.next_input_ms == 0 then
        session.next_input_ms = now
    end

    local sent = false
    while now >= session.next_input_ms do
        if not send_current_input_frame() then
            break
        end
        session.next_input_ms = session.next_input_ms + INPUT_INTERVAL_MS
        sent = true
    end

    return sent
end


--负责循环读取完整消息，将拿到的多条完整消息解码并展示，处理一些必要的协议
local function dispatch_packages(fd)
    local got = false
    while true do
        local buff, status = recv_package(fd)
        if status == "closed" then
            print("服务器已关闭连接")
            return got, false
        end
        if not buff then
            break
        end
        got = true
        local cmd, ret_msg = proto_unpack(buff)

        if cmd and ret_msg then
            print("Received:", cmd, json_encode(ret_msg))
            if cmd == "login_first" then
                if ret_msg.code ~= 0 then
                    print("login_first 失败:", ret_msg.msg)
                    goto continue
                end
                M1, err = client:process_challenge(ret_msg.salt, ret_msg.B)
                local msg = {
                    playerid = username,
                    M1 = M1
                }
                local buff, err = proto_pack("login_second", msg)
                print("Sent:", "login_second", json_encode(msg))
                socket.send(fd, buff)
            end
            if cmd == "login_second" then
                if ret_msg.code ~= 0 then
                    print("login_second 失败:", ret_msg.msg)
                    goto continue
                end
                local ok = client:verify(ret_msg.M2)
                print("客户端验证 M2:", ok and "成功✓" or "失败✗")
            end
            if cmd=="enter" then
                if ret_msg.code == 0
                    and ret_msg.battle_host
                    and ret_msg.battle_port
                    and ret_msg.battle_conv
                    and ret_msg.battle_token then
                    open_battle_session(ret_msg)
                end
                goto continue
            end
            if cmd == "leave" then
                if ret_msg.code == 0 then
                    close_battle_session()
                end
            goto continue
        end
        end
        ::continue::
    end
    return got, true
end

local function print_help()
    print("输入格式: 命令 JSON")
    print("示例:")
    print([[  login {"playerid":"101","password":"999"}]])
    print([[  enter {}]])
    print([[  input_frame {"target_x":100,"target_y":200,"moving":true}]])
    print("内置命令: help, quit")
    print("可发送的tcp请求命令:")

    local req_cmds = {}
    for cmd, map in pairs(proto_map) do
        if map.req then
            req_cmds[#req_cmds + 1] = cmd
        end
    end
    table.sort(req_cmds)
    print("  " .. table.concat(req_cmds, ", "))
end
--处理终端输入，进行一些处理后发送
local function handle_input_line(line)
    --[[^%s*--开头若干空格
    (.-)非贪婪匹配，返回括号里面的
    --%s*$--结尾若干空格
    ]]
    line = line:match("^%s*(.-)%s*$")
    if line == "" then
        return true
    end
    --[[%S 代表非空白字符（注意是大写的 S）。
    + 代表匹配一个或多个。
    ]]
    local cmd, json_text = line:match("^(%S+)%s*(.*)$")
    if cmd == "quit" or cmd == "exit" then
        return false
    elseif cmd == "help" then
        print_help()
        return true
    else
        if json_text == "" then
            json_text = "{}"
        end

        local ok, msg = pcall(cjson.decode, json_text)
        if not ok or type(msg) ~= "table" then
            print("JSON 解析失败，请使用对象格式，例如: login {\"playerid\":\"101\",\"password\":\"999\"}")
            return true
        end
        if cmd == "login" then
            username = msg.playerid
            local pw = msg.password
            cmd = "login_first"
            client, A = srp.create_client(username, pw)
            msg = {
                playerid = username,
                A = A,
            }
        end
        if cmd == "register" then
            username = msg.playerid
            local pw = msg.password
            local salt, verifier = srp.create_verifier(username, pw)
            msg = {
                playerid = username,
                salt = salt,
                verifier = verifier
            }
        end
         if cmd == "input_frame" then
            return update_input_state(msg)

        end
        local buff, err = proto_pack(cmd, msg)
        if not buff then
            print(err)
            return true
        end

        socket.send(fd, buff)
        print("Sent:", cmd, json_encode(msg))
        return true
    end
end

print_help()
print("Telnet 模式已启用：输入一行即发送，服务端消息会实时打印，输入 `quit` 退出")

local running = true
while running do
    local had_event = false
    --收到并处理或展示tcp消息
    local recv_got, alive = dispatch_packages(fd)
    had_event = had_event or recv_got
    --收到并处理或展示kcp消息
    local battle_got = dispatch_battle_packages()
    had_event = had_event or battle_got
    --检查并发送输入帧
    local input_sent = flush_input_tick()
    had_event = had_event or input_sent
    --驱动kcp
    if battle and battle.kcp and battle.next_update <= now_ms() then
        drive_battle(battle)
    end
    if not alive then
        break
    end

    while true do
        local line = socket.readstdin()
        if not line then
            break
        end
        had_event = true
        if not handle_input_line(line) then
            running = false
            break
        end
    end

    if not running then
        break
    end

    if not had_event then
        --没有事件就睡5ms，这轮如果有消息，下一轮就也可能有消息，不睡，赶紧处理
        socket.usleep(5000)
    end
end

if running then
    local _, alive = dispatch_packages(fd)
    if not alive then
        running = false
    end
end

if running then
    print("Disconnected")
else
    print("Connection ended")
end

socket.close(fd)
close_battle_session()