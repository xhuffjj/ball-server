package.cpath = "skynet/luaclib/?.so;luaclib/?.so"
package.path = "skynet/lualib/?.lua;examples/?.lua;lualib/?.lua"
io.stdout:setvbuf("no") --关闭标准输出（stdout）的缓冲，让输出内容立即显示

local socket = require "client.socket"
local cjson = require "cjson"

local function json_unpack(buff)
    local len = string.len(buff)
    --这是string.unpack的格式化字符串，意为大端，2字节整数+len-2字节的字符串
    local namelen_format = string.format("> i2 c%d", len - 2)
    local namelen, other = string.unpack(namelen_format, buff)

    local bodylen = len - 2 - namelen
    local format = string.format("> c%d c%d", namelen, bodylen)
    local cmd, bodybuff = string.unpack(format, other)

    local isok, msg = pcall(cjson.decode, bodybuff)

    if not isok or not msg or not msg._cmd or not (cmd == msg._cmd) then
        print("error")
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
    local format = string.format("> i2 i2 c%d c%d", namelen, bodylen)
    local buff = string.pack(format, len, namelen, cmd, body)
    return buff
end



local fd = socket.connect("192.168.164.129", 8001)
print("Connected")
socket.usleep(1 * 1000000)

-- 接收缓冲区
local recv_buffer = ""

-- 简单的收包函数，用于非阻塞读取一个完整包
-- 注意：client.socket 的 recv 不支持指定读取长度，会一次性读取所有可用数据
local function recv_package(fd)
    -- 尝试读取新数据到缓冲区
    local data = socket.recv(fd)
    if data and #data > 0 then
        recv_buffer = recv_buffer .. data
        print("recv data len:", #data, "buffer len:", #recv_buffer)
    end

    -- 检查缓冲区是否有完整的包
    if #recv_buffer < 2 then
        return nil -- 不够长度头
    end

    -- 读取2字节长度头（这是内容长度，不包含这2字节本身）
    local content_len = string.unpack(">I2", recv_buffer)

    -- 检查是否有完整的包体
    if #recv_buffer < 2 + content_len then
        return nil -- 包体不完整
    end

    -- 提取完整的包体
    local content = string.sub(recv_buffer, 3, 2 + content_len)
    -- 从缓冲区移除已处理的数据
    recv_buffer = string.sub(recv_buffer, 3 + content_len)

    return content
end

-- 1. 发送登录
local msg = {
    playerid = "101",
    password = "999"
}


local buff_with_len = json_pack("login", msg)
socket.send(fd, buff_with_len)
socket.usleep(10000)
-- 2. 阻塞等待登录成功
while true do
    local buff = recv_package(fd)
    if buff then
        local cmd, ret_msg = json_unpack(buff)
        print("Received:", cmd, cjson.encode(ret_msg))
        --lua的数组只有从1开始且连续才是数组，解码后下标才是数字
        --服务器发来的表有._cmd,所以不是数组，解码后下标是字符串
        if cmd == "login" and ret_msg["2"] == 0 then -- msg["2"]对应return code, 0为成功
            print("Login success!")
            break
        elseif cmd == "login" and ret_msg["2"] ~= 0 then
            print("Login failed:", ret_msg["3"])
            socket.close(fd)
            return
        end
    else
        socket.usleep(10000)
    end
end

-- 3. 发送 Enter
msg = {}

local buff_enter = json_pack("enter", msg)
socket.send(fd, buff_enter)
print("Sent enter")
socket.usleep(1 * 1000000)
-- 4. 发送 Shift
msg = {
    x = 1,
    y = 0
}
local buff_shift = json_pack("shift", msg)
socket.send(fd, buff_shift)
print("Sent shift")


print("Listening for updates...")
-- 尝试接收后续的包（如move广播）
while true do
    local buff = recv_package(fd)

    if buff then
        local cmd, ret_msg = json_unpack(buff)
        if cmd then
            print("Received:", cmd, cjson.encode(ret_msg))
        end
    else
        socket.usleep(200000)
    end
end

socket.close(fd)
