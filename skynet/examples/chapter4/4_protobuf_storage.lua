local skynet = require "skynet"
local pb = require "protobuf"
local mysql = require "skynet.db.mysql"
local db

local function test6()
    pb.register_file("./examples/chapter4/storage/playerdata.pb")
    local playerdata = {
        playerid = 109,
        coins = 97,
        name = "Tiny",
        level = 3,
        last_login_time = os.time(),

    }

    local data = pb.encode("playerdata.BaseInfo", playerdata)
    print("data len: " .. string.len(data))
    local sql = string.format("insert into test(playerid,data) values (%d,%s)", 109, mysql.quote_sql_str(data))
    local res = db:query(sql)
    if res.err then
        print("error: " .. res.err)
    else
        print("ok")
    end
end

local function test7()
    pb.register_file("./examples/chapter4/storage/playerdata.pb")
    local sql = string.format("select * from test where playerid = 109")
    local res = db:query(sql)
    local data = res[1].data
    print("data len: " .. string.len(data))
    local udata = pb.decode("playerdata.BaseInfo", data)
    if not udata then
        print("error")
        return false
    end
    local playerdata = udata
    print("coins: " .. playerdata.coins)
    print("name: " .. playerdata.name)
    print("time: " .. playerdata.last_login_time)
    print("skin: " .. playerdata.skin)
end

skynet.start(
    function()
        db = mysql.connect({
            host = "192.168.164.129",
            port = 3306,
            database = "storage_protobuf_test",
            user = "root",
            password = "123456",
            max_packet_size = 1024 * 1024, --最大接收包大小（1MB
            on_connect = nil               --连接建立时的回调函数
        })
        test7()
    end
)
