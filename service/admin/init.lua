local skynet = require("skynet")
local socket = require("skynet.socket")
local s = require("service")
local runconfig = require("runconfig")
require("skynet.manager")
local httpd = require("http.httpd")
local sockethelper = require("http.sockethelper")
local urllib = require("http.url")
local cjson = require("cjson")
local mysql = require("skynet.db.mysql")

local cmd_handler = {}
local repo = {}
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end
local function db_failed_err(res)
    return string.format(
        "insert mails failed | errno=%s | badresult=%s | err=%s",
        tostring(res and res.errno),
        tostring(res and res.badresult),
        tostring(res and res.err)
    )
end
local function response(id, write, ...)
    local ok, err = httpd.write_response(write, ...)
    if not ok then
        skynet.error(string.format("fd =%d,%s", id, err))
    end
    socket.close(id)
end

local function handle_http_request(id, addr)
    socket.start(id)
    print("receive connect from: " .. addr .. " " .. id)
    local readc = sockethelper.readfunc(id)
    local writec = sockethelper.writefunc(id)

    local code, url_or_err, method, header, body = httpd.read_request(readc, 8192)
    skynet.error(
        string.format(
            "receive code:%d,url_or_err:%s, method:%s, header:%s, body:%s",
            code,
            url_or_err,
            method,
            header,
            body
        )
    )
    if not code then --解析请求失败
        if url_or_err == sockethelper.socket_error then
            skynet.error("socket closed")
        else
            skynet.error("read_request failed: " .. tostring(url_or_err))
        end
        socket.close(id)
        return
    end
    if code ~= 200 then
        response(id, writec, code)
    else
        local path, query = urllib.parse(url_or_err) --解析url
        local cors_headers = {
            ["Access-Control-Allow-Origin"] = "*",
            ["Access-Control-Allow-Methods"] = "POST,GET,OPTIONS",
            ["Access-Control-Allow-Headers"] = "Content-Type",
            ["Content-Type"] = "application/json",
        }
        if method == "OPTIONS" then
            response(id, writec, 200, "", cors_headers)
        elseif path == "/admin" then
            local ok, req_data = pcall(cjson.decode, body or "")
            if not ok or not req_data or not req_data.cmd then
                local resp_body =
                    cjson.encode({ code = 1, message = "Invalid JSON or missing 'cmd'" })
                response(id, writec, 400, resp_body, cors_headers)
                return
            end
            local cmd = req_data.cmd
            local msg = req_data.msg
            if not cmd_handler[cmd] then
                local resp_body =
                    cjson.encode({ code = 1, message = "command not found:" .. tostring(cmd) })
                response(id, writec, 404, resp_body, cors_headers)
                return
            end
            local pcall_isok, isok = pcall(cmd_handler[cmd], msg)
            if not isok or not pcall_isok then
                local resp_body = cjson.encode({
                    code = 1,
                    message = "调用cmd_handler[cmd]失败:" .. tostring(cmd),
                })
                response(id, writec, 500, resp_body, cors_headers)
                return
            end
            local resp_body = cjson.encode({ code = 0, message = "success" })
            response(id, writec, 200, resp_body, cors_headers)
        else
            local resp_body =
                cjson.encode({ code = 1, message = "path not found:" .. tostring(path) })
            response(id, writec, 404, resp_body, cors_headers)
            return
        end
    end
end

function s.init()
    s.db = mysql.connect({
        host = "127.0.0.1",
        port = 3306,
        database = "player_message",
        user = "root",
        password = "123456",
        max_packet_size = 1024 * 1024, --最大接收包大小（1MB
        on_connect = nil, --连接建立时的回调函数
    })
    if not s.db then
        skynet.error("admin init db failed")
        skynet.exit()
        return
    end
    local listenfd = socket.listen("127.0.0.1", 8888)
    socket.start(listenfd, function(id, addr)
        skynet.fork(handle_http_request, id, addr)
    end)
end
---------------------------------------踢人-------------------------------------------------------------
--让网关拒绝新连接
local function shutdown_gate()
    for node, _ in pairs(runconfig.cluster) do
        local nodecfg = runconfig[node]
        for i, v in pairs(nodecfg.gateway or {}) do
            local name = "gateway" .. i
            pcall(s.call, node, name, "shutdown")
        end
    end
end
--让agentmgr踢一些人下线(慢慢踢)
local function shutdown_agent()
    local anode = runconfig.agentmgr.node
    local fail_count = 0
    local max_fail = 5
    while true do
        local isok, online_num = pcall(s.call, anode, "agentmgr", "shutdown", 3)
        if isok and online_num and online_num <= 0 then
            break
        end
        if isok then
            fail_count = 0
        end
        if not isok or not online_num then
            fail_count = fail_count + 1
            skynet.error("shutdown_agent call failed: " .. tostring(online_num))
            if fail_count >= max_fail then
                skynet.error("shutdown_agent abort by too many failures")
                break
            end
        end
        skynet.sleep(100)
    end
end

local function shutdown_node()
    local mynode = skynet.getenv("node")
    for node, _ in pairs(runconfig.cluster) do
        if mynode ~= node then
            local ok, ret = pcall(s.call, node, "nodemgr", "abort")
            if not ok or not ret then
                skynet.error("abort failed on " .. node)
            end
        end
    end
    pcall(s.call, mynode, "nodemgr", "abort")
end
local function shutdown_match()
    pcall(s.call, runconfig.match.node, "match", "shutdown")
end
function cmd_handler.stop()
    shutdown_gate()
    shutdown_match()
    shutdown_agent()

    --保存全局数据

    --终止

    shutdown_node()
    return true
end

-------------------------------邮件相关--------------------------------------------

--存储邮件
function repo.storage_mail(title, content, attachments, expire_seconds, batch_id)
    local safe_title = s.db.quote_sql_str(title)
    local safe_content = s.db.quote_sql_str(content)
    local safe_batch_id = s.db.quote_sql_str(batch_id)
    local expire_sql = "NULL"
    local expire_time
    local res = s.db:query("START TRANSACTION")
    if db_failed(res) then
        return false, "开启事务失败"
    end
    if expire_seconds and expire_seconds > 0 then
        expire_time = os.date("%Y-%m-%d %H:%M:%S", os.time() + expire_seconds)
        expire_sql = s.db.quote_sql_str(expire_time)
    end
    local sql = string.format(
        [[insert into mail
        (playerid,sender_id,title,content,expire_time,batch_id)
        select playerid,0,%s,%s,%s,%s from role_message
    ]],
        safe_title,
        safe_content,
        expire_sql,
        safe_batch_id
    )

    res = s.db:query(sql)

    if db_failed(res) then
        s.db:query("ROLLBACK")
        skynet.error(db_failed_err(res))
        return false, "insert mails failed"
    end
    --把附件列表在数据库中做成一个临时表
    --item_id|count
    --.......|.....
    local rows = {}
    for i, att in ipairs(attachments or {}) do
        local item_id = assert(tonumber(att.item_id), "bad item_id @" .. i)
        local count = assert(tonumber(att.count), "bad count @" .. i)
        assert(item_id > 0 and count > 0, "item_id/count must >0 @" .. i)
        rows[#rows + 1] = string.format("select %d as item_id ,%d as cnt", item_id, count)
    end

    local attach_union = table.concat(rows, " union all ")
    if attach_union == "" then
        local commit_res = s.db:query("COMMIT")
        if db_failed(commit_res) then
            s.db:query("ROLLBACK")
            return false, "无附件分支，提交事务失败"
        end
        return true
    end
    --查出我们这批邮件的id，然后和附件表做笛卡尔积，插入
    sql = string.format(
        [[
        insert into mail_attachment (mail_id,item_id,cnt)
        select m.mail_id,a.item_id,a.cnt
        from (select mail_id from mail where batch_id=%s) m
        join (%s) a
    ]],
        safe_batch_id,
        attach_union
    )
    res = s.db:query(sql)
    if db_failed(res) then
        s.db:query("ROLLBACK")
        skynet.error(db_failed_err(res))
        return false, "插入附件失败"
    end

    local commit_res = s.db:query("COMMIT")
    if db_failed(commit_res) then
        s.db:query("ROLLBACK")
        return false, "有附件分支，提交事务失败"
    end
    return true
end

function repo.resolve_batch_id(msg)
    --如果msg传进来batch_id，就用传进来的，and和or的结果为true时，返回右边的参数
    local bid = tostring((msg and msg.batch_id) or "")
    if bid ~= "" then
        return bid
    end
    --UUID()：调用生成一个全球唯一的标识符，长这个样子，包含 36 个字符：550e8400-e29b-41d4-a716-446655440000
    --REPLACE(..., '-', '')：字符串替换函数。它把刚才生成的 UUID 里面的连字符（-）全部替换成空（即删掉）。
    local r = s.db:query("select REPLACE(UUID(),'-','') AS id")
    return r[1].id
end

--发邮件
function cmd_handler.send_mail(msg)
    --往邮箱表插入所有玩家的一份邮件并且往附件表插入对应附件
    local batch_id = repo.resolve_batch_id(msg)
    local isok, err =
        repo.storage_mail(msg.title, msg.content, msg.attachments, msg.expire_time, batch_id)
    if not isok then
        skynet.error(err)
        return false
    end

    --通知在线玩家更新内存
    s.send(runconfig.agentmgr.node, "agentmgr", "notify_new_mails", batch_id)
    return true
end

s.start(...)
