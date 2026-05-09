local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")
local pb = require("protobuf")

local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

--公开信息协议类
local function public_baseinfo(playerid, level, vip_level, is_online, in_scene)
    local m = {
        playerid = playerid,
        level = level,
        vip_level = vip_level,
        is_online = is_online,
        in_scene = in_scene,
    }
    return m
end

--好友简报协议类
local function friend_brief(friendid, status, is_online)
    local m = {
        friendid = friendid,
        status = status, --0-未决定，1-好友
        is_online = is_online,
    }
    return m
end

--好友类
local function friend(friendid, create_time)
    local m = {
        friendid = friendid,
        create_time = create_time,
    }
    return m
end

--[friendid]->friend，好友表
s.data.friends = s.data.friends or {}
--[friendid]->friend,好友申请表
s.data.friends_pending = s.data.friends_pending or {}

--哈希表的计数函数
local function map_size(t)
    local n = 0
    for _ in pairs(t) do
        n = n + 1
    end
    return n
end

--和数据库交互的函数
local repo = {}

--------------------------------------------初始化-----------------------------------------------
--数据库层：返回玩家好友数据
function repo.load_relations(playerid)
    local safe_playerid = s.db.quote_sql_str(playerid)
    local sql = string.format(
        "select friendid,status,create_time from friend where playerid =%s",
        safe_playerid
    )
    local res = s.db:query(sql)
    if db_failed(res) then
        error("加载玩家好友数据失败: playerid=" .. tostring(playerid))
    end
    return res
end
--数据库层：返回库中玩家好友数和被申请数

--初始化好友信息
function s.friend_init()
    local res = repo.load_relations(s.id)
    for _, row in ipairs(res) do
        local f = friend(row.friendid, row.create_time)
        if row.status == 1 then
            s.data.friends[row.friendid] = f
        else
            s.data.friends_pending[row.friendid] = f
        end
    end
end

-------------------------------------------列表请求------------------------------------------------------
--客户端请求好友列表
function s.client.friend_list(msg)
    local id_list = {}
    for fid, f in pairs(s.data.friends) do
        table.insert(id_list, fid)
    end

    local player_list = s.call(runconfig.agentmgr.node, "agentmgr", "get_players", id_list)
    local list = {}
    for _, fid in ipairs(id_list) do
        table.insert(list, friend_brief(fid, 1, player_list[fid] and 1 or 0))
    end

    return { "friend_list", friends = list }
end

--客户端请求好友申请列表
function s.client.friend_pending_list()
    local id_list = {}
    for fid, f in pairs(s.data.friends_pending) do
        table.insert(id_list, fid)
    end

    local player_list = s.call(runconfig.agentmgr.node, "agentmgr", "get_players", id_list)
    local list = {}
    for _, fid in ipairs(id_list) do
        table.insert(list, friend_brief(fid, 0, player_list[fid] and 1 or 0))
    end
    return { "friend_pending_list", friends = list }
end

-------------------------------------服务在线时，供其他服务调用的接口------------------------------------------------
--返回玩家的公开信息
function s.resp.get_info()
    --这里的只要is_kicked为true就认定为下线
    --绝大多数情况，agentmgr做出下线裁决导致s.is_kick为ture之前，agentmgr就会设置状态为登出
    --从而向agentmgr时查询在线情况时就会返回离线，到不了这里
    --不过万一agentmgr为GAME时被查询在线状态，然后agentmgr急速完成下线裁决，agent这里急速设置is_kick，然后才收到基础信息的查询
    --那么为了应对这种情况，not is_kicked的判断便是必要的
    return public_baseinfo(
        s.id,
        s.data.base_info.level,
        s.data.base_info.vip_level,
        not s.is_kicked,
        s.sname and true or false
    )
end

--供其他服务用,本服务在线时，查询本服务的好友数和被申请数
function s.resp.friends_num()
    return map_size(s.data.friends), map_size(s.data.friends_pending)
end

--服务间接口，其他服务调用，通知本服务好友事件来临
function s.resp.friend_notify(source, cmd, playerid)
    if cmd == "friend_add" then --好友申请
        s.data.friends_pending[playerid] = friend(playerid)
    elseif cmd == "friend_added" then --对方和你是双向申请，自动添加好友
        s.data.friends[playerid] = friend(playerid)
        s.data.friends_pending[playerid] = nil
    elseif cmd == "friend_delete" then --对方删除好友
        s.data.friends[playerid] = nil
    elseif cmd == "friend_reject" then --对方拒绝
    elseif cmd == "friend_accept" then --对方接受好友申请
        s.data.friends[playerid] = friend(playerid)
        s.data.friends_pending[playerid] = nil --这句是防御性编程
    end
end

-----------------------------客户端查询好友信息部分--------------------------------------------------

local function friend_info_ok(info)
    return { "friend_info", code = 0, msg = "查询成功", info = info }
end
local function friend_info_fail(msg)
    return { "friend_info", code = 1, msg = msg }
end
--在线就rpc拿公开信息
local function query_online_public_info(friendid)
    local player = s.call(runconfig.agentmgr.node, "agentmgr", "get_player", friendid)
    if not player then
        return nil
    end

    local isok, info = pcall(s.call, player.node, player.agent, "get_info")
    if isok and info then
        return info
    end
end
--数据库层，返回玩家公开信息
function repo.load_player_public_info(playerid)
    local safe_playerid = s.db.quote_sql_str(playerid)
    local sql = string.format("select data from role_message where playerid=%s", safe_playerid)
    local res = s.db:query(sql)
    if db_failed(res) then
        return nil, "查询数据库时失败"
    elseif res and #res == 0 then
        return nil, "玩家不存在"
    else
        return res[1].data
    end
end
--离线查库：玩家信息
local function query_offline_public_info(playerid)
    local res, err = repo.load_player_public_info(playerid)
    if not res then
        return nil, err
    end
    local isok, role_data = pcall(pb.decode, "GameData.role_message", res)
    if not isok or not role_data then
        return nil, "玩家数据损坏"
    end
    local info = public_baseinfo(playerid, role_data.level, role_data.vip_level, false, false)
    return info
end

--客户端查询好友信息
function s.client.friend_info(msg)
    local friendid = msg.friendid
    --在线问服务
    local info = query_online_public_info(friendid)
    if info then
        return friend_info_ok(info)
    end
    --离线查库
    local offline_info, err = query_offline_public_info(friendid)
    if not offline_info then
        return friend_info_fail(err)
    end
    return friend_info_ok(offline_info)
end

-----------------------------------客户端申请加好友部分------------------------------------------
local function friend_add_ok(msg)
    return { "friend_add", code = 0, msg = msg }
end
local function friend_add_fail(msg)
    return { "friend_add", code = 1, msg = msg }
end

---------------数据库部分：

--数据库层：持久化双向好友记录
function repo.replace_bidirectional(target_id, from_id)
    local safe_target = s.db.quote_sql_str(target_id)
    local safe_from = s.db.quote_sql_str(from_id)
    local sql = string.format(
        "replace into friend (friendid,playerid,status) values (%s,%s,1),(%s,%s,1)",
        safe_target,
        safe_from,
        safe_from,
        safe_target
    )
    local res = s.db:query(sql)
    if db_failed(res) then
        return false, "添加失败"
    end
    return true
end

--数据库层：查询玩家是否存在
function repo.target_exist(playerid)
    local safe_playerid = s.db.quote_sql_str(playerid)
    local sql = string.format("select playerid from role_message where playerid=%s", safe_playerid)
    local res = s.db:query(sql)
    if db_failed(res) then
        return false, "查询目标玩家失败"
    end
    if #res == 0 then
        return false, "目标玩家不存在"
    end
    return true
end

--判断好友数和被申请数是否满
local function check_target_capacity(f_num, p_num)
    if f_num >= 50 then
        return false, "对方好友已满"
    end
    if p_num >= 20 then
        return false, "对方申请列表已满"
    end
    return true
end

--数据库层：在数据库查询目标玩家的当前好友数和被申请数不满则插入
function repo.insert_pending_atomic(target_id, from_id)
    local safe_target = s.db.quote_sql_str(target_id)
    local safe_from = s.db.quote_sql_str(from_id)
    local tx, err = s.db:begin()
    if not tx then
        return false, err or "事务开启失败"
    end
    --锁住需要的行
    local target_rows = tx:query(
        string.format(
            "select friendid,status from friend where playerid=%s for update",
            safe_target
        )
    )
    if db_failed(target_rows) then
        tx:rollback()
        return false, "查询失败"
    end
    local target_fnum, target_pnum = 0, 0
    for _, r in ipairs(target_rows) do
        if r.status == 1 then
            target_fnum = target_fnum + 1
        end
        if r.status == 0 then
            target_pnum = target_pnum + 1
        end
    end

    local is_insertable, insertable_err = check_target_capacity(target_fnum, target_pnum)
    if not is_insertable then
        tx:rollback()
        return false, insertable_err
    end
    local sql = string.format(
        "insert ignore into friend (playerid,friendid,status) values (%s,%s,%d) ",
        safe_target,
        safe_from,
        0
    )
    local res = tx:query(sql)
    if db_failed(res) then
        tx:rollback()
        return false, "添加请求入库失败"
    elseif res and res.affected_rows == 0 then
        tx:rollback()
        return false, "已经是好友，或者重复申请"
    end
    local c = tx:commit()
    if db_failed(c) then
        tx:rollback()
        return false, "提交失败"
    end
    return true
end
--在线查询目标玩家的当前好友数和被申请数,作为预检查
local function query_online_f_p_num(target_id)
    local player = s.call(runconfig.agentmgr.node, "agentmgr", "get_player", target_id)
    if player then
        local isok, f_num, p_num = pcall(s.call, player.node, player.agent, "friends_num")
        if isok and f_num and p_num then
            local is_insertable, insertable_err = check_target_capacity(f_num, p_num)
            if not is_insertable then --在线玩家说他满了，我们直接返回
                return false, insertable_err
            end
        end
    end
    return true
end

--向目标玩家尝试通知好友事件
local function notify_if_online(target_id, cmd, from_id)
    local player = s.call(runconfig.agentmgr.node, "agentmgr", "get_player", target_id)
    if player then
        s.send(player.node, player.agent, "friend_notify", cmd, from_id)
    end
end

--客户端申请加好友
function s.client.friend_add(msg)
    local tid = msg.target_id
    --自身参数校验
    if tid == s.id then
        return friend_add_fail("不能添加自己")
    end
    if map_size(s.data.friends) >= 50 then
        return friend_add_fail("数量已达上限,请删除部分好友")
    end

    --预检查，如果对方在线且回复满，则返回，省的查数据库，但是对方如果说不满，我们还要查数据库检查确保
    local ok, insertable_err = query_online_f_p_num(tid)
    if not ok then
        return friend_add_fail(insertable_err)
    end

    --验证是否已经在好友列表
    if s.data.friends[tid] then
        return friend_add_fail("玩家已经是好友")
    end
    --验证是否已经在申请列表
    if s.data.friends_pending[tid] then --对方已经发来好友申请
        s.data.friends[tid] = s.data.friends_pending[tid]
        s.data.friends_pending[tid] = nil
        --接受好友申请,持久化记录
        local saved, err = repo.accept_pending_atomic(tid, s.id)
        if not saved then
            s.data.friends_pending[tid] = s.data.friends[tid]
            s.data.friends[tid] = nil
            return friend_add_fail(err)
        end
        --若目标在线。则通知其更新内存
        notify_if_online(tid, "friend_added", s.id)
        return friend_add_ok("添加成功")
    end

    --查询目标玩家是否存在
    local exists, exist_err = repo.target_exist(tid)
    if not exists then
        return friend_add_fail(exist_err)
    end
    --请求入库
    local inserted, insert_err = repo.insert_pending_atomic(tid, s.id)
    if not inserted then
        return friend_add_fail(insert_err)
    end

    --若目标在线。则通知其更新内存
    notify_if_online(tid, "friend_add", s.id)
    return friend_add_ok("申请成功")
end

---------------------------------客户端申请删好友部分---------------------------------------------
local function friend_delete_ok()
    return { "friend_delete", code = 0, msg = "删除成功" }
end
local function friend_delete_fail(msg)
    return { "friend_delete", code = 1, msg = msg }
end
function repo.delete_bidirectional(target_id, from_id)
    local safe_target = s.db.quote_sql_str(target_id)
    local safe_from = s.db.quote_sql_str(from_id)
    local sql = string.format(
        [[delete from friend where (playerid=%s and friendid=%s) or
    (friendid=%s and playerid=%s)]],
        safe_target,
        safe_from,
        safe_target,
        safe_from
    )
    local res = s.db:query(sql)
    if db_failed(res) then
        return false, "从库中删除好友关系失败"
    end
    return true
end
--客户端请求删除好友
function s.client.friend_delete(msg)
    local tid = msg.target_id
    if not s.data.friends[tid] then
        return friend_delete_fail("不存在该好友")
    end
    --更新内存
    local deleted_friend = s.data.friends[tid]
    s.data.friends[tid] = nil
    --从库删除
    local deleted, delete_err = repo.delete_bidirectional(tid, s.id)
    if not deleted then
        s.data.friends[tid] = deleted_friend
        return friend_delete_fail(delete_err)
    end
    --通知对方更新内存
    notify_if_online(tid, "friend_delete", s.id)
    return friend_delete_ok()
end
-----------------------客户端请求拒绝好友部分------------------------------------------
local function friend_reject_ok()
    return { "friend_reject", code = 0, msg = "拒绝成功" }
end
local function friend_reject_fail(msg)
    return { "friend_reject", code = 1, msg = msg }
end
function repo.delete_pending(target_id, from_id)
    local safe_target = s.db.quote_sql_str(target_id)
    local safe_from = s.db.quote_sql_str(from_id)
    local sql = string.format(
        [[delete from friend where playerid=%s and friendid=%s]],
        safe_from,
        safe_target
    )
    local res = s.db:query(sql)
    if db_failed(res) then
        return false, "从库中删除对方的申请记录失败"
    end
    return true
end
--客户端请求拒绝好友
function s.client.friend_reject(msg)
    local tid = msg.target_id
    if not s.data.friends_pending[tid] then
        return friend_reject_fail("不存在该好友的申请")
    end
    --从内存删去
    local pending = s.data.friends_pending[tid]
    s.data.friends_pending[tid] = nil
    --从库删去
    local deleted, delete_err = repo.delete_pending(tid, s.id)
    if not deleted then
        s.data.friends_pending[tid] = pending
        return friend_reject_fail(delete_err)
    end
    return friend_reject_ok()
end

-----------------------客户端请求接受好友部分------------------------------------------
local function friend_accept_ok()
    return { "friend_accept", code = 0, msg = "接受成功" }
end
--数据库层：检查数量并插入(原子操作)
function repo.accept_pending_atomic(target_id, from_id)
    local first_id, second_id = from_id, target_id
    if tonumber(first_id) and tonumber(second_id) and tonumber(first_id) > tonumber(second_id) then
        first_id, second_id = second_id, first_id
    end --按顺序加锁，防死锁（一方接受和另一方自动添加同时进行有可能死锁）
    local safe_first = s.db.quote_sql_str(first_id)
    local safe_second = s.db.quote_sql_str(second_id)
    local tx, err = s.db:begin()
    if not tx then
        return false, err or "事务开启失败"
    end
    --锁住需要的行
    local first_rows = tx:query(
        string.format("select friendid,status from friend where playerid=%s for update", safe_first)
    )
    if db_failed(first_rows) then
        tx:rollback()
        return false, "查询失败"
    end
    local second_rows = tx:query(
        string.format(
            "select friendid,status from friend where playerid=%s for update",
            safe_second
        )
    )
    if db_failed(second_rows) then
        tx:rollback()
        return false, "查询失败"
    end
    local self_rows, target_rows
    if first_id == from_id then
        self_rows, target_rows = first_rows, second_rows
    else
        self_rows, target_rows = second_rows, first_rows
    end
    local has_pending, self_fnum, target_fnum = false, 0, 0
    for _, r in ipairs(self_rows) do
        if r.status == 1 then
            self_fnum = self_fnum + 1
        end
        if r.friendid == target_id and r.status == 0 then
            has_pending = true
        end
    end
    for _, r in ipairs(target_rows) do
        if r.status == 1 then
            target_fnum = target_fnum + 1
        end
    end

    if not has_pending then
        tx:rollback()
        return false, "数据库不存在申请记录"
    end
    if self_fnum >= 50 then
        tx:rollback()
        return false, "好友已满"
    end
    if target_fnum >= 50 then
        tx:rollback()
        return false, "对方好友已满"
    end
    local sql = string.format(
        "replace into friend (friendid,playerid,status) values (%s,%s,1),(%s,%s,1)",
        safe_first,
        safe_second,
        safe_second,
        safe_first
    )
    local res = tx:query(sql)
    if db_failed(res) then
        tx:rollback()
        return false, "添加失败"
    end
    local c = tx:commit()
    if db_failed(c) then
        tx:rollback()
        return false, "提交失败"
    end
    return true
end

local function friend_accept_fail(msg)
    return { "friend_accept", code = 1, msg = msg }
end
--客户端请求接受好友
function s.client.friend_accept(msg)
    local tid = msg.target_id
    if not s.data.friends_pending[tid] then
        return friend_accept_fail("申请表中不存在该玩家")
    end
    --请求入库
    s.data.friends[tid] = friend(tid)
    local temp = s.data.friends_pending[tid]
    s.data.friends_pending[tid] = nil
    local inserted, insert_err = repo.accept_pending_atomic(tid, s.id)
    if not inserted then
        s.data.friends[tid] = nil
        s.data.friends_pending[tid] = temp
        return friend_accept_fail(insert_err)
    end
    --若目标在线。则通知其更新内存
    notify_if_online(tid, "friend_accept", s.id)
    return friend_accept_ok()
end
