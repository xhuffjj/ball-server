local skynet = require("skynet")
local socket = require("skynet.socket")
local s = require("service")
local pb = require("protobuf")
local kcp = require("kcp")
local runconfig = require("runconfig")
local proto_map = require("proto_map")
local crypt = require("skynet.crypt")
local cjson = require("cjson")
local next_conv_id = 0

local udp_fd
local bind_host
local public_host
local port

local sessions = {}
local players = {}

local PRE_READY_TIMEOUT_MS = 5000 --握手未完成的超时时间
local READY_NO_PACKET_TIMEOUT_MS = 5000 --握手后判断连接断开的时间
local RECONNECT_WAIT_MS = 15000 --重连等待时间

local SESSION_STATE = {
    WAIT_AUTH = 1, --会话等待认证
    WAIT_READY = 2, --会话等待客户端发第三次握手消息
    ACTIVE = 3, --活跃状态
    RECONNECT_WAIT = 4, --等待重连
    CLOSED = 5,
}

local function set_state(session, state)
    session.state = state
end

--重置会话的kcp相关
local function reset_kcp(session)
    session.kcp = nil
    session.addr = nil
    session.ready_seq = 0
    session.next_update = 0
end

local function enter_reconnect_wait(session, now)
    reset_kcp(session)
    --重连需要重新握手
    --删除旧kcp对象，握手时会重新建立kcp对象，相当于重新建立连接
    session.reconnect_deadline = now + RECONNECT_WAIT_MS
    set_state(session, SESSION_STATE.RECONNECT_WAIT)
end

local function now_ms()
    --skynet.now是单调时钟
    --返回skynet启动到现在的毫秒数
    return skynet.now() * 10
end

local function next_conv()
    local conv = next_conv_id
    next_conv_id = next_conv_id + 1
    return conv
end

local function get_token()
    return crypt.hexencode(crypt.randomkey())
end

local function battle_session(player, conv)
    return {
        player = player,
        conv = conv,
        addr = nil, --skynet的二进制ip加端口
        kcp = nil,
        state = nil, --会话的状态
        ready_seq = 0, --第二次握手的challege
        next_update = 0, --kcp下一次update的时间
        last_active = 0, --会话最近活跃时间
        has_joined = false, --仅用于区分首次进入还是断线重连后恢复
        reconnect_deadline = 0, --重连的截止时间
    }
end

local function battle_player(playerid, token, room, scene, agent_node, agent)
    return {
        playerid = playerid,
        session = nil,
        token = token,
        room = room,
        scene = scene,
        agent_node = agent_node,
        agent = agent,
    }
end

local function notify_agent_leave(player, reason)
    if not player or not player.agent or not player.agent_node then
        return
    end
    s.send(player.agent_node, player.agent, "battle_leave_room", reason)
end

local function proto_pack(cmd, msg)
    local map = proto_map[cmd]
    assert(map, "unknown cmd: " .. tostring(cmd))
    local proto_type = map.res or map.notify
    assert(proto_type, "proto_pack proto_type missing for cmd: " .. tostring(cmd))
    msg[1] = nil
    local body = pb.encode(proto_type, msg)
    local namelen = string.len(cmd)
    local bodylen = string.len(body)

    local format = string.format("> I2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, namelen, cmd, body)
    return buff
end

local function proto_unpack(buff)
    if type(buff) ~= "string" then
        skynet.error("协议格式非法")
        return
    end
    local len = string.len(buff)
    if len <= 2 then
        return
    end
    --这是string.unpack的格式化字符串，意为大端，2字节整数+len-2字节的字符串
    local namelen_format = string.format("> I2 c%d", len - 2)
    local ok, namelen, other = pcall(string.unpack, namelen_format, buff)
    if not ok or namelen <= 0 or string.len(other) == 0 then
        skynet.error("协议格式非法")
        return
    end
    local bodylen = len - 2 - namelen
    if bodylen < 0 then
        skynet.error("协议格式非法")
        return
    end
    local format = string.format("> c%d c%d", namelen, bodylen)
    local cmd, bodybuff = string.unpack(format, other)
    local map = proto_map[cmd]
    if not map then
        skynet.error("未注册的命令： " .. cmd)
        return
    end
    local proto_type = map.req

    local isok, msg = pcall(pb.decode, proto_type, bodybuff)

    if not isok or not msg then
        skynet.error("解包失败")
        return
    end

    return cmd, msg
end

local function drive_kcp(session)
    if not session.kcp then
        return
    end
    local now = now_ms()
    session.kcp:update(now)
    session.next_update = session.kcp:check(now)
end

local function free_session(session)
    if not session then
        return
    end
    local player = session.player
    if player and player.session == session then
        --防止旧会话的关闭消息误伤玩家新会话
        player.session = nil
        players[player.playerid] = nil
    end
    session.player = nil
    reset_kcp(session)
    session.reconnect_deadline = 0
    session.state = SESSION_STATE.CLOSED
    sessions[session.conv] = nil
end

local function create_kcp(session, from)
    session.addr = from

    local kc = kcp.create(session.conv, function(raw)
        if session.addr then
            socket.sendto(udp_fd, session.addr, raw)
        end
    end)

    kc:nodelay(1, 10, 2, 1)
    kc:wndsize(128, 128)
    kc:setmtu(1200)
    kc:minrto(10)

    session.kcp = kc
    drive_kcp(session)
end

local function send_payload(session, payload)
    --发送有效载荷
    if not session or not session.kcp then
        return false
    end
    --把字符拼进kcp
    session.kcp:send(payload)
    --驱动kcp,把消息立即发送
    drive_kcp(session)
    return true
end

local function send_msg(session, msg)
    skynet.error(
        "[battle_gateway] send: " .. session.conv .. "[" .. msg[1] .. "]" .. cjson.encode(msg)
    )
    return send_payload(session, proto_pack(msg[1], msg))
end

local function battle_auth(session, msg)
    local player = session.player

    if msg.token ~= player.token then
        send_msg(session, { "battle_auth", code = 1, msg = "auth失败" })
        return
    end
    --只允许WAIT_AUTH和RECONNECT_WAIT进行第一次握手
    if
        session.state == SESSION_STATE.WAIT_AUTH
        or session.state == SESSION_STATE.RECONNECT_WAIT
    then
        set_state(session, SESSION_STATE.WAIT_READY)
        session.ready_seq = math.random(1, 0x7fffffff)
        send_msg(session, { "battle_auth", code = 0, msg = "ok", ready_seq = session.ready_seq })
    elseif session.state == SESSION_STATE.WAIT_READY or session.state == SESSION_STATE.ACTIVE then
        --如果已经完成了第一次握手，重发第二次握手包，保持幂等性
        send_msg(session, { "battle_auth", code = 0, msg = "ok", ready_seq = session.ready_seq })
    end
end

local function battle_ready_ack(session, msg)
    if session.state ~= SESSION_STATE.WAIT_READY then
        return
    end

    local player = session.player
    if not player then
        return
    end
    if msg.ready_seq ~= session.ready_seq then
        return
    end

    local isreconnect = session.has_joined
    --在call之前修改状态，防止场景首帧发不过来，被阻拦，因为room的最后一个玩家战斗链路准备好后
    --就会立即发首个场景快照，这边可能还没返回。
    --至于在call之前设置状态，然而这个会话不一定battle_ready不一定返回成功，
    --比如那边是个新会话（虽然现在的room不允许离开后再进入，不会出现这种情况，过去的直连scene并且leave是非同步（send）可能会）
    --导致放行，旧会话的消息转发给了新会话，
    --解决方法是接受那边或许可以做一些校验，看会话号是否一致（现在不用做）
    set_state(session, SESSION_STATE.ACTIVE)
    session.has_joined = true
    --取消重连窗口的截止时间
    session.reconnect_deadline = 0

    local ready_ok =
        skynet.call(player.room, "lua", "battle_ready", player.playerid, session.conv, true)
    if not ready_ok then
        --场景服务那里玩家已经有了新会话，这个会话的准备好消息不再接受
        free_session(session)
        return
    end

    if isreconnect then
        --请求场景发一份快照
        skynet.send(player.scene, "lua", "battle_resync", player.playerid, session.conv)
    end
end

local function dispatch_kcp_message(session, cmd, msg)
    if cmd == "battle_auth" then
        return battle_auth(session, msg)
    end
    if cmd == "battle_ready_ack" then
        return battle_ready_ack(session, msg)
    end

    local player = session.player
    --只有ACTIVE状态才能的会话才接受分发
    if session.state ~= SESSION_STATE.ACTIVE then
        return
    end

    skynet.send(player.scene, "lua", "client", player.playerid, cmd, msg)
end

local function drain_recv(session)
    --尝试拿完整消息
    while true do
        --dispatch里面可能释放会话，这里需要再判断
        if not session.kcp then
            break
        end
        --n是消息长度，payload是消息
        local n, payload = session.kcp:recv()
        if n < 0 then
            break
        end
        local cmd, msg = proto_unpack(payload)

        if cmd and msg then
            skynet.error(
                "[battle_gateway] received: "
                    .. session.conv
                    .. "["
                    .. cmd
                    .. "]"
                    .. cjson.encode(msg)
            )
            dispatch_kcp_message(session, cmd, msg)
        end
    end
end

local function on_udp(raw, from)
    --on_udp每收到一个完整的udp包时回调
    local ok, conv = pcall(kcp.getconv, raw)
    --用pcall，如果收到非kcp包会失败
    if not ok or not conv then
        return
    end
    local session = sessions[conv]
    if not session then
        return
    end

    if not session.kcp then
        if
            session.state == SESSION_STATE.WAIT_AUTH
            or session.state == SESSION_STATE.WAIT_READY
            or session.state == SESSION_STATE.RECONNECT_WAIT
        then
            create_kcp(session, from)
        else
            skynet.error("kcp不存在，且会话状态编号为：" .. session.state)
            return
        end
    else
        session.addr = from --udp的对端端口可能改变，需要更新
        --部分udp包可能会因为端口改变丢失，不过kcp会重传的
    end

    local handle_result = session.kcp:input(raw)
    if handle_result < 0 then
        --处理失败，数据格式不符合 KCP 协议
        skynet.error("kcp:input处理失败，数据格式不符合 KCP 协议")
        return
    end
    session.last_active = now_ms()
    drain_recv(session)

    local now = now_ms()
    --drain_recv里面可能释放会话，这里需要再判断
    if now >= session.next_update and session.kcp then
        session.kcp:update(now)
        session.next_update = session.kcp:check(now)
    end
end

--[[function s.resp.alloc(source,playerid,scene,agent_node,agent)
    local old=players[playerid]
    if old and old.session then
        --如果有旧会话，释放旧的会话对象和玩家对象
        free_session(old.session)
    end

    local conv=next_conv()
    local token=get_token()
    
    local player=battle_player(playerid,token,scene,agent_node,agent)
    local session=battle_session(player,conv)
    player.session=session
    session.last_active=now_ms()
    session.state=SESSION_STATE.WAIT_AUTH
    players[playerid]=player
    sessions[conv]=session

    return {
        host=public_host,
        port=port,
        conv=conv,
        token=token
    }
end]]
function s.resp.batch_alloc(source, room, scene, player_list)
    local ret = {}
    for _, item in ipairs(player_list) do
        local old = players[item.playerid]
        if old and old.session then
            --如果有旧会话，释放旧的会话对象和玩家对象
            free_session(old.session)
        end

        local conv = next_conv()
        local token = get_token()

        local player = battle_player(item.playerid, token, room, scene, item.agent_node, item.agent)
        local session = battle_session(player, conv)
        player.session = session
        session.last_active = now_ms()
        session.state = SESSION_STATE.WAIT_AUTH
        players[item.playerid] = player
        sessions[conv] = session

        table.insert(ret, {
            playerid = item.playerid,
            host = public_host,
            port = port,
            conv = conv,
            token = token,
        })
    end

    return ret
end
function s.resp.free(source, conv)
    local session = sessions[conv]
    if not session then
        return true
    end
    free_session(session)
    return true
end

function s.resp.send(source, playerid, msg)
    local player = players[playerid]
    local session = player and player.session
    if not session then
        return false
    end
    if session.state ~= SESSION_STATE.ACTIVE then
        return false
    end
    return send_msg(session, msg)
end

s.init = function()
    pb.register_file("./proto/game.pb")

    local node = skynet.getenv("node")
    local cfg = runconfig[node].battle_gateway[s.id]

    bind_host = cfg.bind_host
    public_host = cfg.public_host
    port = cfg.port
    next_conv_id = s.id * 1000000 + 1

    udp_fd = socket.udp(on_udp, bind_host, port)
    skynet.error(
        string.format("[battle_gateway] listen %s,%d ,public =%s", bind_host, port, public_host)
    )

    skynet.fork(function()
        while true do
            local now = now_ms()
            for conv, session in pairs(sessions) do
                if session.kcp and session.next_update <= now then
                    session.kcp:update(now)
                    session.next_update = session.kcp:check(now)
                end

                --检查是否未完成握手且超时
                if
                    (
                        session.state == SESSION_STATE.WAIT_AUTH
                        or session.state == SESSION_STATE.WAIT_READY
                            and session.has_joined == false
                    ) and now - session.last_active > PRE_READY_TIMEOUT_MS
                then
                    --释放会话，从场景踢掉
                    local player = session.player
                    free_session(session)
                    if player then
                        notify_agent_leave(player, "battle pre-ready timeout")
                    end
                    goto continue
                end

                --检查是否很久没收到包,判断断开
                if
                    session.state == SESSION_STATE.ACTIVE
                    and now - session.last_active > READY_NO_PACKET_TIMEOUT_MS
                then
                    enter_reconnect_wait(session, now)

                    local player = session.player
                    if player then
                        --设置场景服务中玩家的状态
                        skynet.send(
                            player.room,
                            "lua",
                            "battle_ready",
                            player.playerid,
                            session.conv,
                            false
                        )
                    end
                    goto continue
                end

                --断开的连接的超时检查
                if
                    (
                        session.state == SESSION_STATE.RECONNECT_WAIT
                        or session.state == SESSION_STATE.WAIT_READY
                            and session.has_joined == true
                    ) and now > session.reconnect_deadline
                then
                    --释放会话，从场景踢掉
                    local player = session.player
                    free_session(session)
                    if player then
                        notify_agent_leave(player, "battle reconnect timeout")
                    end
                    goto continue
                end

                ::continue::
            end
            skynet.sleep(1)
        end
    end)
end

s.start(...)
