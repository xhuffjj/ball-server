local pb = require "protobuf"

local function test4()
    pb.register_file("/home/a/桌面/球球大作战服务器/proto/login_test.pb")
    local msg = {
        id = 101,
        pw = "123456",
    }
    local buff = pb.encode("login.Login", msg)
    print("len: " .. string.len(buff))

    local umsg = pb.decode("login.Login", buff)
    if umsg then
        print("id: " .. umsg.id)
        print("pw: " .. umsg.pw)
    else
        print("error")
    end
end

test4()
