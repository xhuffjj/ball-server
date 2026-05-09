local skynet = require("skynet")
local mysql = require("skynet.db.mysql")
local s = require("service")
local runconfig = require("runconfig")

local SLOT_STATE = {
    FREE = 0, -- 空闲连接
    NORMAL = 1, --正在执行单条sql
    TX = 2, --正在执行事务
}
local pool = {}
local rr = 0 --round-robin游标，轮询分配连接
local tx_seq = 0 --事务自增序号
local txs = {} -- [tx_id] = { slot = slot}
--规定事务句柄不要在多个协程中使用，不然可能语句交错
local mysql_opts
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

local function build_mysql_opts()
    local cfg = assert(runconfig.mysqlproxy, "runconfig.mysqlproxy missing")
    return {
        host = cfg.host or "127.0.0.1",
        port = cfg.port or 3306,
        database = cfg.database or "player_message",
        user = cfg.user or "root",
        password = cfg.password or "123456",
        max_packet_size = cfg.max_packet_size or (1024 * 1024),
        on_connect = nil,
    }
end
--pool的每个槽
local function connect_slot(id)
    local db = mysql.connect(mysql_opts)
    return {
        id = id,
        db = db,
        state = SLOT_STATE.FREE,
    }
end
--重连槽里面的连接
local function reconnect_slot(slot)
    pcall(mysql.disconnect, slot.db)
    local ok, db_or_err = pcall(mysql.connect, mysql_opts)
    if ok then
        slot.db = db_or_err
    end
end
--执行指定槽的单条query，失败会自动尝试重连，但不会重试sql
local function query_on_slot(slot, sql, in_tx)
    local ok, res = pcall(slot.db.query, slot.db, sql)
    --连接断开等错误会直接抛出lua error，我们这里捕获
    --语法错误等不会抛错，作为返回值留给业务层检查
    if ok then
        return res
    end

    skynet.error(
        string.format(
            "[mysqlproxy] query error slot=%d in_tx=%s err=%s sql=%s",
            slot.id,
            tostring(in_tx),
            tostring(res),
            tostring(sql)
        )
    )

    reconnect_slot(slot)
    return { badresult = true, err = tostring(res) }
end

--获取一个空闲连接
local function acquire_slot(state)
    while true do
        --最大轮询次数覆盖池子大小
        for _ = 1, #pool do
            rr = rr % #pool + 1
            local candidate = pool[rr]
            if candidate.state == SLOT_STATE.FREE then
                candidate.state = state
                return candidate
            end
        end
        --否则等10ms
        skynet.sleep(1)
    end
end

local function release_slot(slot)
    slot.state = SLOT_STATE.FREE
end

local function next_tx_id()
    tx_seq = tx_seq + 1
    return tx_seq
end
--检查事务记录是否存在,是的话返回事务对应的连接
local function check_tx(tx_id)
    if not txs[tx_id] then
        return nil, { badresult = true, err = "transaction not found: " .. tostring(tx_id) }
    end
    return txs[tx_id]
end
--结束事务，提交或者撤回
local function finish_tx(tx_id, sql)
    local slot, err = check_tx(tx_id)
    if not slot then
        return err
    end
    --删除事务记录
    txs[tx_id] = nil
    local res = query_on_slot(slot, sql, true)
    --恢复槽的状态
    release_slot(slot)
    return res
end
--从连接池选一个连接，执行单条sql
function s.resp.query(source, sql)
    --格式错误
    if type(sql) ~= "string" or sql == "" then
        return { badresult = true, err = "bad sql" }
    end

    local slot = acquire_slot(SLOT_STATE.NORMAL)
    local res = query_on_slot(slot, sql, false)
    release_slot(slot)

    return res
end
--开启事务
function s.resp.begin(source)
    local slot = acquire_slot(SLOT_STATE.TX)
    local res = query_on_slot(slot, "START TRANSACTION", true)
    if db_failed(res) then
        release_slot(slot)
        return nil, res
    end

    --分配一个事务号
    local tx_id = next_tx_id()
    txs[tx_id] = slot
    return tx_id
end

--事务专用执行单条sql
function s.resp.query_tx(source, tx_id, sql)
    if type(sql) ~= "string" or sql == "" then
        return { badresult = true, err = "bad sql" }
    end
    --找之前开事务的连接继续query
    local slot, err = check_tx(tx_id)
    if not slot then
        return err
    end
    return query_on_slot(slot, sql, true)
end

function s.resp.commit(source, tx_id)
    return finish_tx(tx_id, "COMMIT")
end

function s.resp.rollback(source, tx_id)
    return finish_tx(tx_id, "ROLLBACK")
end

--供外部查询连接池情况
function s.resp.stats()
    local stat = {
        pool_size = #pool,
        free = 0,
        normal = 0,
        tx = 0,
        tx_count = 0,
    }

    for _, slot in ipairs(pool) do
        if slot.state == SLOT_STATE.FREE then
            stat.free = stat.free + 1
        elseif slot.state == SLOT_STATE.NORMAL then
            stat.normal = stat.normal + 1
        elseif slot.state == SLOT_STATE.TX then
            stat.tx = stat.tx + 1
        end
    end

    for _ in pairs(txs) do
        stat.tx_count = stat.tx_count + 1
    end

    return stat
end

function s.init()
    mysql_opts = build_mysql_opts()
    local pool_size = runconfig.mysqlproxy.pool_size or 8
    assert(pool_size > 0, "mysqlproxy.pool_size must be > 0")

    for i = 1, pool_size do
        pool[i] = connect_slot(i)
    end
    skynet.error("[mysqlproxy] started, pool_size=" .. tostring(pool_size))
end

s.start(...)
