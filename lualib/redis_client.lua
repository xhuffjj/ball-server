local skynet = require("skynet")

local M = {}
local methods = {}
--methods只放这一个方法，其他的redis命令我们动态生成
function methods:state()
    return skynet.call(self.proxy, "lua", "state")
end

--动态生成函数，外面s.rds:get这种调用，所以我们函数的参数是self,...这种形式
local function build_methods(cmd)
    return function(self, ...)
        local ret = table.pack(skynet.call(self.proxy, "lua", "cmd", cmd, ...))
        if not ret[1] then
            error(ret[2], 0)
        end
        return table.unpack(ret, 2, ret.n)
    end
end

--元表的index为函数时，.的结果即为index函数返回值
--我们利用这个机制生成函数,为不同的redis命令名生成不同的函数
local mt = {
    __index = function(self, key)
        --首先看有没有现成的
        local fn = methods[key]
        if fn then
            return fn
        end
        if type(key) ~= "string" or key == "" then
            return nil
        end
        fn = build_methods(key)
        --生成的函数保存下来，下次直接调用
        rawset(self, key, fn)
        return fn
    end,
}

function M.connect()
    return setmetatable({
        proxy = "redisproxy",
    }, mt)
end

return M
