local skynet = require "skynet"
local socketdriver = require "skynet.socketdriver"
local netpack = require "skynet.netpack"
local queue --消息队列，这是一个c语言对象，用于存放积压的完整数据包
--在c语言层第一次收到非完美包时创建，引用保存在lua脚本，
--下一次收到数据你需要把引用传给c语言层，复用这个队列

-- 构建一个清理对象，在服务退出时局部变量引用失效，清理queue(里面指针指向的数据)，lua的GC只能清除queue里面的指针
local _ = setmetatable({}, { __gc = function() netpack.clear(queue) end })
local function process_connect(fd, addr)
    skynet.error("new connect fd: " .. fd .. " addr: " .. addr)
    socketdriver.start(fd) --开始接受数据
    socketdriver.nodelay(fd)
end

local function process_msg(fd, msg, sz)
    local str = netpack.tostring(msg, sz) --c语言字符串转lua字符串
    skynet.error("recv from fd: " .. "str: " .. str)
    --skynet.sleep(100)--模拟数据处理
    --skynet.error("finish fd: " .. fd .. " " .. str)
end

local function process_more()
    for fd, msg, sz in netpack.pop, queue do --netpack.pop作为迭代器函数，queue作为参数
        --收到多条消息，每条消息应该用协程方式处理
        --如果不用协程，因为数据处理的阻塞就会导致more消息管理的数据迟迟得不到处理
        --此时底层若再凑齐一个完整的数据包，就会先处理这个数据包，导致先处理了后来到的
        skynet.fork(process_msg, fd, msg, sz)

        --process_msg(fd, msg, sz)
    end
end

local function process_close(fd)
    skynet.error("close fd: " .. fd)
end

local function process_error(fd, error)
    skynet.error("error fd:" .. fd .. "error: " .. error)
end

local function process_warning(fd, error)
    skynet.error("warning fd:" .. fd .. "warning: " .. error)
end



--当 Skynet 的 C 线程（Socket 线程）收到网络数据时，会直接把原始数据的内存指针 (msg) 和长度 (sz) 传给这个函数
local function socket_unpack(msg, sz)
    --netpack.filter：拼包函数
    --收到数据拼包，若刚好一条数据，返回data类型
    --返回的mgs指向这条消息的字符开始,返回fd,msg,sz
    --多条数据则压入队列，返回more类型，我们调用netpack.pop手动pop
    --不完整的数据存入哈希表
    --当skynet底层驱动发现连接断开/错误时，它会发给 Lua 一个特殊的原始消息
    --netpack.filter识别代表断开/错误的消息，返回 "close"/"error"类型
    --旧的消息队列传进去，新的消息队列和网络事件类型，以及其他的一些东西会返回
    --返回的参数传给socket_dispatch
    --消息队列包含，fd(谁发来的)，msg(消息内容),sz(消息长度)
    return netpack.filter(queue, msg, sz)
    --积压的消息太多时，c语言层会给队列扩容，旧引用失效，所以这个函数会返回新queue
end
--session,sourse忽略
--socket_unpack调用后，无论有没有完整消息都调用socket_dispatch
local function socket_dispatch(_, _, q, type, ...)
    skynet.error("socket_dispatch type: " .. (type or "nil"))
    queue = q --这一步在三个时刻起作用：queue在c语言层面创建时，扩容时，手动调用 netpack.clear 清理队列时（queue变成nil)
    if type == "open" then
        process_connect(...)
    elseif type == "data" then --刚好凑够一个消息(后面没有残余半包)
        process_msg(...)
    elseif type == "more" then --多个消息/单个消息后面有半包
        process_more()
    elseif type == "close" then
        process_close(...)
    elseif type == "error" then
        process_error(...)
    elseif type == "warning" then
        process_warning(...)
    end --若收到的数据不够一个消息，触发type为nil的socket_dispatch
end

skynet.start(
    function()
        --注册SOCKET类型消息
        skynet.register_protocol( --作用是在本服务作用域内，注册协议，或覆盖现有的协议行为
            {
                name = "socket",  --协议别名，凡是提到 'socket' 类型的消息，就是指这个 ID
                id = skynet.PTYPE_SOCKET,
                --这里指定处理 PTYPE_SOCKET 类型的消息，这意味着当底层 C 语言的网络线程（Gate 或 Socket Server）收到数据并转发给这个 Lua 服务时，会触发这里的逻辑。
                unpack = socket_unpack,    --解包函数
                dispatch = socket_dispatch --收到PTYPE_SOCKET类型的消息的回调，通常是

            })

        --创建socket
        local listenfd = socketdriver.listen("127.0.0.1", 8888)
        socketdriver.start(listenfd) --将listenfd和当前服务绑定，skynet便会把新连接发到这个fd
    end
)
