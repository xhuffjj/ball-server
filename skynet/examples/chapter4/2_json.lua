local skynet = require "skynet"
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

    if not isok or not msg or not msg._cmd or not cmd == msg._cmd then
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

local function test1()
    local msg = {
        _cmd = "balllist",
        balls = {
            [1] = { id = 102, x = 10, y = 20, size = 2 },
            [2] = { id = 103, x = 20, y = 30, size = 3 }
        }
    }
    local buff = cjson.encode(msg)
    print(buff)
end

local function test2()
    local buff = [[{"balls":[{"size":2,"y":20,"id":102,"x":10},{"size":3,"y":30,"id":103,"x":20}],"_cmd":"balllist"}]]
    local isok, msg = pcall(cjson.decode, buff)
    if isok then
        print(msg._cmd)
        print(msg.balls[1].size)
    else
        print(error)
    end
end

local function test3()
    local msg = {
        _cmd = "playerinfo",
        coin = 100,
        bag = {
            [1] = { 1001, 1 }, --一把倚天剑
            [2] = { 1002, 2 }  --两个草药
        }
    }
    local buff_with_len = json_pack("playerinfo", msg)
    local len = string.len(buff_with_len)
    print("len: " .. len)
    print(buff_with_len)

    local format = string.format("> i2 c%d", len - 2)
    local _, buff = string.unpack(format, buff_with_len)
    local cmd, umsg = json_unpack(buff)
    print("cmd " .. cmd)
    print("coin " .. msg.coin)
    print("sword " .. msg.bag[1][2])
end

skynet.start(
    function()
        test3()
    end
)
