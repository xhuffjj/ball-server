local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")
local socketdriver = require("skynet.socketdriver")
local netpack = require("skynet.netpack")
local cjson = require("cjson")
local pb = require("protobuf")
local crypt = require("skynet.crypt")
local queue
local _ = setmetatable({}, {
    __gc = function()
        netpack.clear(queue)
    end,
})

local closing = false

--连接表,[fd]=conn
local conns = {}
--玩家表,[playerid]=gateplayer
local players = {}
--连接类
local function conn()
    local m = {
        fd = nil,
        playerid = nil,
        loginid = nil, --这个确保登录的两个阶段发给同一个登录服务
    }
    return m
end
--消息缓存类
local function a_buff(send_seq, buff)
    local m = {
        send_seq = send_seq,
        buff = buff,
    }
    return m
end

--玩家类
local function gateplayer()
    local m = {
        playerid = nil,
        agent = nil, --agent服务地址
        conn = nil,
        token = crypt.hexencode(crypt.randomkey()),
        msgcache = {}, --array:a_buff
        send_seq = 0, --当前发送序列号
        disconnect_ver = 0, --给每次断连事件一个网关唯一标号，防止断连a->重连->断连b这种情况下，断连a的定时器提前请求踢掉玩家
        login_version = nil,
    }
    return m
end

local next_disconnect_ver = 0
local function alloc_disconnect_ver()
    next_disconnect_ver = next_disconnect_ver + 1
    return next_disconnect_ver
end

--协议映射表，协议名->{proto类型(请求/响应，广播)}
local proto_map = require("proto_map")

local function json_unpack(buff)
    local len = string.len(buff)
    --这是string.unpack的格式化字符串，意为大端，2字节整数+len-2字节的字符串
    local namelen_format = string.format("> I2 c%d", len - 2)
    local namelen, other = string.unpack(namelen_format, buff)

    local bodylen = len - 2 - namelen
    local format = string.format("> c%d c%d", namelen, bodylen)
    local cmd, bodybuff = string.unpack(format, other)

    local isok, msg = pcall(cjson.decode, bodybuff)

    if not isok or not msg or not msg._cmd or not (cmd == msg._cmd) then
        skynet.error("解包失败")
        return
    end

    return cmd, msg
end

local function proto_unpack(buff)
    if type(buff) ~= "string" then
        skynet.error("协议格式非法")
        return
    end

    local len = string.len(buff)
    if len <= 2 then
        skynet.error("协议格式非法")
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

local function json_pack(cmd, msg)
    msg._cmd = cmd
    local body = cjson.encode(msg)
    local namelen = string.len(cmd)
    local bodylen = string.len(body)
    local len = bodylen + namelen + 2
    local format = string.format("> I2 I2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, len, namelen, cmd, body)
    return buff
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
    local len = bodylen + namelen + 2
    local format = string.format("> I2 I2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, len, namelen, cmd, body)
    return buff
end

-------------这是一个专门为打印日志的proto解包函数，没别的用处----------------
local function proto_unpack_log(buff)
    local packlen = string.len(buff)
    --这是string.unpack的格式化字符串，意为大端，2字节整数+len-2字节的字符串
    local len_namelen_format = string.format("> I2 I2 c%d", packlen - 4)
    local len, namelen, other = string.unpack(len_namelen_format, buff)

    local bodylen = len - 2 - namelen
    local format = string.format("> c%d c%d", namelen, bodylen)
    local cmd, bodybuff = string.unpack(format, other)
    local map = proto_map[cmd]
    if not map then
        skynet.error("未注册的命令： " .. cmd)
        return
    end
    local proto_type = map.res or map.notify
    local isok, msg = pcall(pb.decode, proto_type, bodybuff)
    if not isok or not msg then
        skynet.error("解包失败")
        return
    end
    return cmd, msg
end
--------------------------------

function s.resp.send_by_fd(sourse, fd, msg, buf) --没有playerid时用这个给客户端发信息，比如login验证密码错误时的回信
    if not fd then
        return
    end
    if buf then
        local cmd, mesg = proto_unpack_log(buf)
        skynet.error("send: " .. fd .. "[" .. cmd .. "]" .. cjson.encode(mesg))
        socketdriver.send(fd, buf)
    elseif msg then
        local cmd = msg[1]
        --消息打包为字符串
        --local buff = json_pack(msg[1], msg)
        local buff = proto_pack(msg[1], msg)
        skynet.error("send: " .. fd .. "[" .. cmd .. "]" .. cjson.encode(msg))
        socketdriver.send(fd, buff)
    end
end

function s.resp.send(sourse, playerid, msg) --登录后有了playerid要给客户端发消息用这个,playerid找玩家对象，玩家对象里面有连接对象，连接对象里面拿到fd，再调用s.resp.send_by_fd
    local gplayer = players[playerid]
    if not gplayer then
        return
    end

    --递增序列号
    gplayer.send_seq = gplayer.send_seq + 1
    --缓存序列化后的消息
    local buff = proto_pack(msg[1], msg)
    table.insert(gplayer.msgcache, a_buff(gplayer.send_seq, buff))

    local conn = gplayer.conn
    --缓冲区满后的行动
    if #gplayer.msgcache > 500 then
        if not conn then --不在线就请求下线agent
            s.call(
                runconfig.agentmgr.node,
                "agentmgr",
                "reqkick",
                playerid,
                "gate消息缓存过多",
                gplayer.login_version
            )
        else --在线就把第一条消息去除
            table.remove(gplayer.msgcache, 1)
        end
    end
    if not conn then
        return
    end
    s.resp.send_by_fd(nil, conn.fd, nil, buff)
end

function s.resp.sure_agent(sourse, fd, playerid, agent, login_version)
    local conn = conns[fd]

    --收到sure_agent后，登录流程完成，
    --如果这之前连接断开，调用了disconnect,那么这个连接会在表中被删去
    if not conn then --登陆过程中已经下线
        --参数false
        skynet.call("agentmgr", "lua", "confirm_login", playerid, false)
        return false
    end
    conn.playerid = playerid
    local gplayer = gateplayer()
    gplayer.playerid = playerid
    gplayer.agent = agent
    gplayer.conn = conn
    gplayer.login_version = login_version
    players[playerid] = gplayer
    --参数true
    local ok = skynet.call("agentmgr", "lua", "confirm_login", playerid, "true")
    if not ok then
        players[playerid] = nil
        conns[fd] = nil
        socketdriver.close(fd)
        return false
    end
    return true, gplayer.token
end

function s.resp.kick(sourse, playerid)
    --playerid索引到gateplayer对象，拿到玩家的conn对象，然后获得这个连接的fd,从players表，conns表请出
    local gplayer = players[playerid]

    if not gplayer then
        return
    end

    local c = gplayer.conn
    players[playerid] = nil

    if not c then
        return
    end

    local fd = c.fd

    conns[fd] = nil
    socketdriver.close(fd)
end

local function disconnect(fd) --判断是登录中，还是游戏中，如果登录中，我们直接返回，如果游戏中，我们向agentmgr请求登出
    local c = conns[fd]
    if not c then
        return
    end
    local playerid = c.playerid

    if not playerid then
        --登录中
        conns[fd] = nil
        socketdriver.close(fd)
        return
    else
        --游戏中
        players[playerid].conn = nil
        conns[fd] = nil --立即关闭旧fd，要不然重连了没办法关了
        socketdriver.close(fd)
        local ver = alloc_disconnect_ver()
        players[playerid].disconnect_ver = ver
        local login_version = players[playerid].login_version
        skynet.timeout(300 * 100, function()
            if not players[playerid] then --玩家已经被踢了
                return
            end
            if players[playerid].disconnect_ver ~= ver then --当前的断连清理不由此定时器处理
                return
            end
            if players[playerid].conn == nil then
                local reason = "断线超时"
                skynet.call("agentmgr", "lua", "reqkick", playerid, reason, login_version)
            end
        end)
    end
end

local function process_reconnect(fd, msg)
    local playerid = msg.playerid
    local token = msg.token
    local last_ack = msg.last_ack
    --新的连接不存在
    local conn = conns[fd]
    if not conn then
        skynet.error("reconnect failed,conn not exist")
        s.resp.send_by_fd(nil, fd, { "reconnect", code = 1 })
        return
    end

    --要求重连的玩家未登录
    if not players[playerid] then
        skynet.error("reconnect failed,player not exist")
        s.resp.send_by_fd(nil, fd, { "reconnect", code = 1 })
        return
    end
    --要求重连的玩家的连接未断开
    if players[playerid].conn then
        skynet.error("reconnect failed,conn not break")
        s.resp.send_by_fd(nil, fd, { "reconnect", code = 1 })
        return
    end

    --本连接已经有玩家占用了,不是空连接（防止其他已登录的连接在窃取token的情况下串号）
    if conn.playerid then
        skynet.error("reconnect failed,conn is not empty_conn")
        s.resp.send_by_fd(nil, fd, { "reconnect", code = 1 })
        return
    end
    --token错误
    if token ~= players[playerid].token then
        skynet.error("reconnect failed,token is wrong")
        s.resp.send_by_fd(nil, fd, { "reconnect", code = 1 })
        return
    end

    --绑定新连接
    players[playerid].conn = conn
    conn.playerid = playerid

    s.resp.send_by_fd(nil, fd, { "reconnect", code = 0 })

    --重发数据包
    for _, cached in ipairs(players[playerid].msgcache) do
        if cached.send_seq > last_ack then
            s.resp.send_by_fd(nil, fd, nil, cached.buff)
        end
    end
end

local function process_msg(fd, c_msgstr, sz)
    local str = netpack.tostring(c_msgstr, sz) --c语言字符串转lua字符串

    local cmd, msg = proto_unpack(str)
    if not cmd then
        return
    end
    skynet.error("received: " .. fd .. "[" .. cmd .. "]" .. cjson.encode(msg))

    if cmd == "reconnect" then --重连协议由网关处理
        process_reconnect(fd, msg)
        return
    end

    local conn = conns[fd]
    --收到多条消息创建协程skynet.fork(process_msg, fd, msg, sz)是异步执行的
    --有可能在某个的消息process_msg前，那个连接close了，导致conn被我们注册的函数清掉，所以我们这里要判空
    if not conn then
        return
    end
    local playerid = conn.playerid

    if not playerid then --注册或登录
        local node = skynet.getenv("node")
        local nodecfg = runconfig[node]
        if not conn.loginid then
            conn.loginid = math.random(1, #nodecfg.login)
        end

        local login = "login" .. conn.loginid
        skynet.send(login, "lua", "client", fd, cmd, msg)
    else --转发给角色代理
        local gplayer = players[playerid]
        if not gplayer then --同前面判conn为空的原因
            return
        end
        local agent = gplayer.agent
        skynet.send(agent, "lua", "client", cmd, msg)
    end
end

local function process_more()
    for fd, msg, sz in netpack.pop, queue do
        skynet.fork(process_msg, fd, msg, sz)
    end
end

local function process_close(fd)
    skynet.error("close fd: " .. fd)
    disconnect(fd)
end

local function process_error(fd, error)
    skynet.error("error fd: " .. fd .. " error: " .. error)
    disconnect(fd)
end

local function process_warning(fd, error)
    skynet.error("warning fd:" .. fd .. "warning: " .. error)
end

local function process_connect(fd, addr)
    if closing then
        socketdriver.close(fd)
        return
    end
    print("receive connect from: " .. addr .. " " .. fd)
    local c = conn()
    conns[fd] = c
    c.fd = fd
    socketdriver.start(fd)
    socketdriver.nodelay(fd)
end

local function socket_unpack(msg, sz)
    return netpack.filter(queue, msg, sz)
end

local function socket_dispatch(_, _, q, type, ...)
    skynet.error("socket_dispatch type: " .. (type or "nil"))
    queue = q
    if type == "open" then
        process_connect(...)
    elseif type == "data" then
        process_msg(...)
    elseif type == "more" then
        process_more()
    elseif type == "close" then
        process_close(...)
    elseif type == "error" then
        process_error(...)
    elseif type == "warning" then
        process_warning(...)
    end
end

function s.init()
    skynet.error("[start] " .. s.name .. " " .. s.id)
    local node = skynet.getenv("node")
    local nodecfg = runconfig[node]
    local port = nodecfg.gateway[s.id].port
    skynet.register_protocol({
        name = "socket", --协议名称，凡是提到 'socket' 类型的消息，就是指这个 ID
        id = skynet.PTYPE_SOCKET,
        unpack = socket_unpack,
        dispatch = socket_dispatch,
    })
    local listenfd = socketdriver.listen("0.0.0.0", port)
    skynet.error("listen socket: " .. "0.0.0.0" .. ":" .. port)
    socketdriver.start(listenfd)
    pb.register_file("./proto/game.pb")
end

function s.resp.shutdown(sourse)
    closing = true
end

s.start(...)
