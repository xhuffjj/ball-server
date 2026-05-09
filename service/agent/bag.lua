local skynet = require("skynet")
local s = require("service")
local ITEM_CONFIG = require("item_config")
local cjson = require("cjson")
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

local REDIS_TTL = 7 * 24 * 3600

local function item(item_id, count)
    local m = {
        item_id = item_id,
        count = count,
    }
    return m
end
--条目信息表
s.data.items = s.data.items or {}

--处理物品使用的函数表
local effect_handlers = {}
--加载背包物品信息
function s.bag_init()
    local redis_key = "player:" .. tostring(s.id) .. ":bag"
    local cached = s.rds:hgetall(redis_key)
    --命中
    if cached and #cached > 0 then
        for i = 1, #cached, 2 do
            local iid = tonumber(cached[i])
            local item = cjson.decode(cached[i + 1])
            s.data.items[iid] = item
        end
    else
        local safe_playerid = s.db.quote_sql_str(s.id)
        local sql = string.format("select item_id,count from bag where playerid=%s", safe_playerid)
        local res = s.db:query(sql)
        if db_failed(res) then
            error("加载玩家背包数据失败: playerid=" .. tostring(s.id))
        end
        for _, row in ipairs(res) do
            local i = item(row.item_id, row.count)
            s.data.items[row.item_id] = i
        end
        --回填redis
        for iid, item in pairs(s.data.items) do
            local value = cjson.encode(item)
            s.rds:hset(redis_key, tostring(iid), value)
        end
    end

    --设置过期时间
    if next(s.data.items) then
        s.rds:expire(redis_key, REDIS_TTL)
    end
end

function s.client.baglist(msg)
    local list = {}
    for iid, cfg in pairs(ITEM_CONFIG) do
        local data = s.data.items[iid] or item(iid, 0)
        table.insert(list, data)
    end
    return { "baglist", items = list }
end

--客户端使用物品(消耗品)
function s.client.use_item(msg)
    local item_id = msg.item_id
    local count = msg.count
    if count <= 0 then
        return { "use_item", code = 1, msg = "使用数量必须大于0" }
    end
    local cfg = ITEM_CONFIG[item_id]
    if not cfg then
        return { "use_item", code = 1, msg = "物品不存在" }
    end
    local i = s.data.items[item_id]
    if not i or count > i.count then
        return { "use_item", code = 1, msg = "物品数量不足" }
    end
    if cfg.type ~= "consumable" then
        return { "use_item", code = 1, msg = "物品不可使用" }
    end
    i.count = i.count - count
    if effect_handlers[cfg.effect] then
        local res = effect_handlers[cfg.effect](count, cfg.value)
        if not res then
            i.count = i.count + count
            return { "use_item", code = 1, msg = "使用失败：调用效果处理方法中" }
        end
    else
        skynet.error("效果： " .. cfg.effect .. "未定义处理方法")
        i.count = i.count + count
        return { "use_item", code = 1, msg = "物品效果未知，使用失败" }
    end
    s.dirty.items = true
    return { "use_item", code = 0, msg = "使用成功" }
end

--服务内部接口，削减物品
function s.sub_item(item_id, count)
    local cfg = ITEM_CONFIG[item_id]
    if not cfg then --物品不存在
        return false
    end
    local i = s.data.items[item_id]
    if not i or i.count < count then --数量不足
        return false
    end
    i.count = i.count - count
    s.dirty.items = true
    return true
end

--服务内部接口，添加物品
function s.add_item(item_id, count)
    local cfg = ITEM_CONFIG[item_id]
    if not cfg then --物品不存在
        return false, "物品不存在"
    end
    local i = s.data.items[item_id]
    if not i then
        i = item(item_id, 0)
        s.data.items[item_id] = i
    end
    if i.count + count > cfg.max_stack then --数量超出
        return false, ITEM_CONFIG[item_id].name .. "超出收纳容量"
    end
    i.count = i.count + count
    s.dirty.items = true
    return true
end

--加经验效果处理
function effect_handlers.add_exp(count, value)
    s.data.base_info.exp = s.data.base_info.exp + value * count
    s.dirty.base_info = true
    return true
end

--使用金币袋
function effect_handlers.add_coin(count, value)
    s.add_coin(value * count)
    return true
end

function s.save_bag()
    local redis_key = "player:" .. tostring(s.id) .. ":bag"
    local fv = {}
    for iid, ite in pairs(s.data.items) do
        fv[#fv + 1] = tostring(iid)
        fv[#fv + 1] = cjson.encode(ite)
    end
    if #fv == 0 then --空背包，无需保存
        return true
    end
    local ok, err = pcall(s.rds.hmset, s.rds, redis_key, table.unpack(fv))
    if not ok then
        skynet.error("向redis写bag失败：playerid=" .. tostring(s.id) .. ",error= " .. err)
        s.rds:del(redis_key)

        for iid, ite in pairs(s.data.items) do
            local safe_playerid = s.db.quote_sql_str(s.id)
            local safe_item_id = s.db.quote_sql_str(iid)
            local safe_count = s.db.quote_sql_str(ite.count)
            local sql = string.format(
                "replace into bag (playerid,item_id,count) value (%s,%s,%s)",
                safe_playerid,
                safe_item_id,
                safe_count
            )
            local res = s.db:query(sql)
            if db_failed(res) then
                skynet.error(
                    "保存背包数据失败: playerid="
                        .. tostring(s.id)
                        .. " item_id="
                        .. tostring(iid)
                )
                return false
            end
        end
        return true
    end
    s.rds:expire(redis_key, REDIS_TTL)
    s.rds:sadd("dirty:bag", s.id)
    return true
end
