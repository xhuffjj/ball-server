local skynet = require("skynet")
local s = require("service")
local pb = require("protobuf")
local mysql_client = require("mysql_client")
local redis_client = require("redis_client")
local runconfig = require("runconfig")

s.client = {}
s.data = {} --存放玩家数据
s.data.base_info = {}
s.gate = nil
s.db = nil
s.rds = nil

s.call_depth = 0 --agent服务调用阻塞函数的计数器
local PLAYER_STATE = {
    NORMAL = 1,
    KICKING = 2,
    KICKED = 3,
}
local HOTFIX_MODULES = {
    bag = true,
    achieve = true,
    mail = true,
    friend = true,
    match = true,
}

local HOTFIX_CONFIGS = {
    item_config = true,
    achieve_config = true,
}
--模块引用的配置文件
local MODULE_CONFIGS = {
    bag = { "item_config" },
    achieve = { "achieve_config" },
}
local function check_hotfix_name(name, allow)
    if type(name) ~= "string" or name == "" then
        return false, "bad name"
    end
    if name:find("[^%w_%.]") then
        return false, "invalid name: " .. name
    end
    if allow and not allow[name] then
        return false, "not allowed: " .. name
    end
    return true
end
local function replace_table(dst, src)
    --替换dst表里面的所有元素
    for k, v in pairs(dst) do
        dst[k] = nil
    end
    for k, v in pairs(src) do
        dst[k] = v
    end
end

local function hotfix_config(config_name)
    local ok, err = check_hotfix_name(config_name, HOTFIX_CONFIGS)
    if not ok then
        return false, err
    end
    local old = package.loaded[config_name]
    skynet.cache.clear()
    package.loaded[config_name] = nil

    local require_ok, new_config = pcall(require, config_name)
    if not require_ok then
        --失败时new_config是报错信息
        package.loaded[config_name] = old
        return false, new_config
    end
    --原地替换旧配置表，这是因为bag和init模块里面的local变量引用了旧表
    if old and type(old) == "table" and type(new_config) == "table" then
        replace_table(old, new_config)
        package.loaded[config_name] = old
    end
    return true
end

local function hotfix_module(modname, reload_config)
    local ok, err = check_hotfix_name(modname, HOTFIX_MODULES)
    if not ok then
        return false, err
    end
    local old = package.loaded[modname]
    local old_configs = {}

    if reload_config then
        --如果要更新配置文件，我们可以清空package.loaded表的对应配置文件
        --后面重新加载模块时配置文件也会重新加载
        for _, config_name in pairs(MODULE_CONFIGS[modname] or {}) do
            old_configs[config_name] = package.loaded[config_name]
            package.loaded[config_name] = nil
        end
    end
    skynet.cache.clear()
    package.loaded[modname] = nil
    local require_ok, new_config = pcall(require, modname)
    if not require_ok then
        --失败时new_config是报错信息
        package.loaded[modname] = old
        for config_name, old_config in pairs(old_configs) do
            package.loaded[config_name] = old_config
        end
        return false, new_config
    end

    return true
end

function s.resp.hotfix_config(source, config_name)
    if s.hotfixing then
        return false, "hotfixing"
    end

    s.hotfixing = true
    while s.call_depth > 0 do --等到没有call被调用再清理
        skynet.sleep(100)
    end
    local ok, err = hotfix_config(config_name)
    s.hotfixing = false
    if not ok then
        skynet.error("[agent] hotfix_config failed: " .. tostring(err))
        return false, err
    end

    skynet.error("[agent] hotfix_config ok: " .. tostring(config_name))
    return true
end

function s.resp.hotfix_module(source, modname, reload_config)
    if s.hotfixing then
        return false, "hotfixing"
    end

    s.hotfixing = true
    while s.call_depth > 0 do --等到没有call被调用再清理
        skynet.sleep(100)
    end
    local ok, err = hotfix_module(modname, reload_config)
    s.hotfixing = false

    if not ok then
        skynet.error("[agent] hotfix_module failed: " .. tostring(err))
        return false, err
    end

    skynet.error("[agent] hotfix_module ok: " .. tostring(modname))
    return true
end

--保护阻塞函数调用期间agent不被踢下线
local function protect_blocking_call(fn, ...)
    s.call_depth = s.call_depth + 1
    local ret = table.pack(pcall(fn, ...))
    s.call_depth = s.call_depth - 1
    if not ret[1] then
        --主动抛出错误，不再加报错行数
        error(ret[2], 0)
    end
    return table.unpack(ret, 2, ret.n)
end
--包装redis的阻塞方法
local function wrap_redis_method(name)
    local raw = s.rds[name]
    if not raw then
        return
    end
    s.rds[name] = function(self, ...)
        return protect_blocking_call(raw, self, ...)
    end
end
--包装事务对象的阻塞方法
local function wrap_tx(tx)
    local raw_tx_query = tx.query
    function tx:query(sql)
        return protect_blocking_call(raw_tx_query, self, sql)
    end

    local raw_tx_commit = tx.commit
    function tx:commit()
        return protect_blocking_call(raw_tx_commit, self)
    end

    local raw_tx_rollback = tx.rollback
    function tx:rollback()
        return protect_blocking_call(raw_tx_rollback, self)
    end
end

local raw_call = s.call
--重新封装阻塞函数--------------------------------
function s.call(node, srv, ...)
    return protect_blocking_call(raw_call, node, srv, ...)
end

local KICKED_ALLOW = { kick = true, exit = true } --下线时允许的消息
local HOTFIX_ALLOW = {
    hotfix_module = true,
    hotfix_config = true,
    kick = true,
    exit = true,
}
---设置消息过滤器
function s.filter_cmd(cmd)
    --热更时只允许这些
    if s.hotfixing and not HOTFIX_ALLOW[cmd] then
        skynet.error(
            string.format(
                "[agent] ignore resp while hotfixing playerid=%s cmd=%s",
                tostring(s.id),
                tostring(cmd)
            )
        )
        return false
    end
    --不下线时全部允许
    if s.state ~= PLAYER_STATE.KICKED and s.state ~= PLAYER_STATE.KICKING then
        return true
    end
    --下线时,只允许这些
    if KICKED_ALLOW[cmd] then
        return true
    end
    skynet.error(
        string.format(
            "[agent] ignore resp while kicked playerid=%s cmd=%s",
            tostring(s.id),
            tostring(cmd)
        )
    )
    return false
end
---------------------------------------------------------------
local repo = {}
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end
--基础信息修改接口----------------
--加减金币
function s.add_coin(count)
    s.data.base_info.coin = s.data.base_info.coin + count
    s.achieve_trigger("earn_coin", count)
    s.mark_dirty("base_info")
    local isok = s.save_base_data()
    s.dirty.base_info = not isok
end
--加减段位分
function s.add_rank_score(count)
    if s.data.base_info.rank_score + count < 0 then
        s.data.base_info.rank_score = 0
    else
        s.data.base_info.rank_score = s.data.base_info.rank_score + count
    end
    s.mark_dirty("base_info")
end
--设置等级
local function set_level()
    s.data.base_info.level = s.data.base_info.exp / 10 + 1
    s.mark_dirty("base_info")
end
--加减经验值
function s.add_exp(count)
    if s.data.base_info.exp + count < 0 then
        s.data.base_info.exp = 0
    else
        s.data.base_info.exp = s.data.base_info.exp + count
    end
    set_level()
    s.mark_dirty("base_info")
end
--设置vip等级,暂未实现
local function set_vip_level()
    --s.data.base_info.vip_level=s.data.base_info.vip_exp/10
    s.mark_dirty("base_info")
end
s.dirty = {
    base_info = false,
    items = false,
    achieves = false,
    mails = false,
}
function s.mark_dirty(module)
    s.dirty[module] = true
end

require("bag")
require("achieve")
require("mail")
require("friend")
require("match")

function s.client.work(msg)
    s.add_coin(2)
    return { "work", coin = s.data.base_info.coin }
end

function s.resp.client(source, cmd, msg)
    s.gate = source
    if s.state ~= PLAYER_STATE.NORMAL then
        return --不处理，不给客户端回协议
    end
    if s.client[cmd] then
        local ret_msg = s.client[cmd](msg, source)
        if ret_msg then -- 只有在有返回消息时才发送
            skynet.send(source, "lua", "send", s.id, ret_msg)
        end
    else
        skynet.error("s.resp.client failed: " .. cmd)
    end
end

function s.resp.send(source, msg)
    skynet.send(s.gate, "lua", "send", s.id, msg)
end

---------------------------------------定时系统，跨日登录-----------------------------------------
local function get_day(timestamp)
    --（1970.1.1.00.00距今秒数）/每天秒数
    --os.time()是1970.1.1.08.00距今秒数
    --
    return (timestamp + 3600 * 8 - 3600 * 12 - 60 * 43) // (3600 * 24)
end

local function first_login_day()
    skynet.error("[agent]跨日登录发奖逻辑触发")
    s.add_coin(1)
end

function s.resp.first_login_day()
    first_login_day()
    s.data.base_info.last_login_time = os.time()
end

-----------------------------------初始化----------------------------------------
function repo.load_base_info()
    local safe_playerid = s.db.quote_sql_str(s.id)
    local sql = string.format("select data from role_message where playerid=%s", safe_playerid)
    local res = s.db:query(sql)
    if db_failed(res) or #res == 0 then
        error("加载玩家数据失败: playerid=" .. tostring(s.id))
    end
    return res
end

local REDIS_TTL = 7 * 24 * 3600

function s.init(login_version)
    s.login_version = login_version
    s.db = mysql_client.connect()
    s.rds = redis_client.connect()
    ----------------------------------------------------
    ---阻塞函数重新包装
    local raw_db_query = s.db.query
    function s.db:query(sql)
        return protect_blocking_call(raw_db_query, self, sql)
    end
    local raw_db_begin = s.db.begin
    function s.db:begin()
        local tx, err = protect_blocking_call(raw_db_begin, self)
        --开启事务失败即创建事务对象失败
        if not tx then
            return nil, err
        end
        wrap_tx(tx)
        return tx
    end
    wrap_redis_method("get")
    wrap_redis_method("set")
    wrap_redis_method("expire")
    wrap_redis_method("sadd")
    wrap_redis_method("del")
    wrap_redis_method("hgetall")
    wrap_redis_method("hset")
    wrap_redis_method("hmset")
    ---------------------------------------------------

    pb.register_file("./storage/GameData.pb")
    --尝试从redis加载玩家数据
    local redis_key = "player:" .. tostring(s.id) .. ":base_info"
    local cached = s.rds:get(redis_key)
    --命中
    if cached then
        local role_data = pb.decode("GameData.role_message", cached)
        s.data.base_info = {
            coin = role_data.coin,
            level = role_data.level,
            vip_level = role_data.vip_level,
            exp = role_data.exp,
            last_login_time = role_data.last_login_time,
            rank_score = role_data.rank_score,
        }
    else --未命中
        --从mysql加载
        local res = repo.load_base_info()
        local role_data = pb.decode("GameData.role_message", res[1].data)
        s.data.base_info = {
            coin = role_data.coin,
            level = role_data.level,
            vip_level = role_data.vip_level,
            exp = role_data.exp,
            last_login_time = role_data.last_login_time,
            rank_score = role_data.rank_score,
        }
        --回填redis
        s.rds:set(redis_key, res[1].data)
    end
    --设置过期时间
    s.rds:expire(redis_key, REDIS_TTL)
    s.state = PLAYER_STATE.NORMAL

    s.mail_init()
    s.bag_init()
    s.achieve_init()
    s.friend_init()

    local last_day = get_day(s.data.base_info.last_login_time)
    local now = os.time()
    local day = get_day(now)
    s.data.base_info.last_login_time = now
    if day > last_day then
        first_login_day()
    end

    local SAVE_INTERVAL = 30
    skynet.fork(function()
        while not s.is_kicked do
            skynet.sleep(SAVE_INTERVAL * 100)
            if s.is_kicked then
                break
            end
            skynet.error("[agent] 定时存盘 playerid=" .. tostring(s.id))
            s.save_all()
        end
    end)
end

function s.save_base_data()
    local redis_key = "player:" .. tostring(s.id) .. ":base_info"
    local data = pb.encode("GameData.role_message", s.data.base_info)
    local ok, err = pcall(s.rds.set, s.rds, redis_key, data)
    if not ok then
        skynet.error("向redis写base_data失败：" .. tostring(s.id) .. " err= " .. tostring(err))
        --存mysql兜底
        local safe_playerid = s.db.quote_sql_str(s.id)
        --local data = pb.encode("GameData.role_message", s.data.base_info)
        local safe_data = s.db.quote_sql_str(data)
        local sql = string.format(
            "update role_message set data=%s where playerid=%s",
            safe_data,
            safe_playerid
        )
        local res = s.db:query(sql)
        if db_failed(res) then
            skynet.error("向mysql保存base_data失败: playerid=" .. tostring(s.id))
            return false
        end
        return true
    end
    --重置超时时间
    s.rds:expire(redis_key, REDIS_TTL)
    --将玩家加入脏集合
    s.rds:sadd("dirty:base_info", tostring(s.id))
    return true
end

--保存所有脏数据到数据库
function s.save_all()
    if s.dirty.base_info then --保存玩家数据
        local isok = s.save_base_data()
        s.dirty.base_info = not isok
    end
    if s.dirty.achieves then --保存成就记录
        local isok = s.save_achieve()
        s.dirty.achieves = not isok
    end
    if s.dirty.items then --保存背包物品
        local isok = s.save_bag()
        s.dirty.items = not isok
    end
    if s.dirty.mails then --保存邮件
        local isok = s.leave_mail()
        s.dirty.mails = not isok
    end
end

function s.resp.kick()
    if s.state == PLAYER_STATE.KICKED or s.state == PLAYER_STATE.KICKING then
        return
    end
    s.state = PLAYER_STATE.KICKING

    while s.call_depth > 0 do --等到没有call被调用再清理
        skynet.sleep(100)
    end

    s.leave_match_or_room()
    s.dirty.base_info = true
    s.dirty.items = true
    s.dirty.achieves = true
    s.dirty.mails = true
    s.save_all()
    --通知dbsync同步
    raw_call(runconfig.dbsync.node, "dbsync", "sync_player", s.id)

    s.state = PLAYER_STATE.KICKED
end

function s.resp.exit()
    while s.state == PLAYER_STATE.KICKING do
        skynet.sleep(10)
    end
    if s.state ~= PLAYER_STATE.KICKED then
        skynet.error("[agent] ignore exit, invalid state=" .. tostring(s.state))
        return false
    end
    skynet.exit()
end

function s.client.base_info(msg, source)
    local b_i = s.data.base_info
    return {
        "base_info",
        coin = b_i.coin,
        exp = b_i.exp,
        level = b_i.level,
        vip_level = b_i.vip_level,
        playerid = s.id,
        last_login_time = b_i.last_login_time,
        rank_score = b_i.rank_score,
    }
end

s.start(...)
