local skynet = require("skynet")
local mysql = require("skynet.db.mysql")

local M = {}
local db_proxy = {}
local tx_proxy = {}
db_proxy.__index = db_proxy
tx_proxy.__index = tx_proxy

--我们在业务里面是调用s.db:query，所以我们写成db代理类

function db_proxy:query(sql)
    return skynet.call(self.proxy, "lua", "query", sql)
end
--开始事务，返回事务代理对象
function db_proxy:begin()
    local tx_id, err = skynet.call(self.proxy, "lua", "begin")
    if not tx_id then
        return nil, err
    end
    return setmetatable({
        proxy = self.proxy,
        tx_id = tx_id,
    }, tx_proxy)
end

function tx_proxy:query(sql)
    return skynet.call(self.proxy, "lua", "query_tx", self.tx_id, sql)
end

function tx_proxy:commit()
    return skynet.call(self.proxy, "lua", "commit", self.tx_id)
end

function tx_proxy:rollback()
    return skynet.call(self.proxy, "lua", "rollback", self.tx_id)
end

function db_proxy.quote_sql_str(str)
    return mysql.quote_sql_str(str)
end

--返回db代理对象
function M.connect()
    return setmetatable({
        proxy = "mysqlproxy",
    }, db_proxy)
end

return M
