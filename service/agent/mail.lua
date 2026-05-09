local skynet = require("skynet")
local s = require("service")
local runconfig = require("runconfig")
local class = require("class")

local function db_failed(res)
    return (not res) or res.badresult or res.errno
end

--信箱，[mid]->mail
s.data.mails = s.data.mails or {}
s.deleted_mails_id = s.deleted_mails_id or {}
local repo = {}

--获得attach_item类表
local attach_item = class("attach_item")

--初始化函数
function attach_item:ctor(attach_id, item_id, count, is_claimed)
    self.id = attach_id
    self.item_id = item_id
    self.count = count
    self.is_claimed = is_claimed
end

--返回attach_item是否被领取
function attach_item:is_unclaimed()
    return self.is_claimed == 0
end

--领取这个attach_item对象
function attach_item:grant()
    local ok, err = s.add_item(self.item_id, self.count)
    if not ok then
        return false, err
    end
    self.is_claimed = 1
    return true
end

--回滚这个attach_ment对象的领取状态
function attach_item:rollback_grant()
    self.is_claimed = 0
    s.sub_item(self.item_id, self.count)
end
----------------------------------------------------------------------------------
--引入mail的类表
local mail = class("mail")

function mail:ctor(
    mail_id,
    sender_id,
    title,
    content,
    is_read,
    create_time,
    expire_time,
    attachments
)
    self.mail_id = mail_id
    self.sender_id = sender_id
    self.title = title
    self.content = content
    self.is_read = is_read
    self.create_time = create_time or ""
    self.expire_time = expire_time or ""
    self.attachments = attachments or {}
end
--返回mail是否过期
function mail:is_expired()
    if not self.expire_time or self.expire_time == "" then
        return false
    end
    return os.date("%Y-%m-%d %H:%M:%S") > self.expire_time
end

--标记邮件已读
function mail:mark_read()
    self.is_read = 1
end

--返回mail的brief简报
function mail:to_brief()
    return {
        mail_id = self.mail_id,
        sender_id = self.sender_id,
        title = self.title,
        is_read = self.is_read,
        expire_time = self.expire_time,
        attach_num = #self.attachments,
    }
end

--单封邮件的通知协议
function mail:to_notify_msg()
    return { "mail_notify", mail = self:to_brief() }
end

--领取邮件附件
function mail:claim_attachments()
    if self:is_expired() then
        return false, "邮件过期"
    end

    --用于记录失败时要回滚的条目
    local granted = {}
    for _, att in ipairs(self.attachments) do
        if att:is_unclaimed() then
            local ok, err = att:grant()
            if not ok then
                for _, granted_att in ipairs(granted) do
                    granted_att:rollback_grant()
                end
                return false, err
            end
            table.insert(granted, att)
        end
    end
    if #granted == 0 then
        return false, "没有可领取的附件"
    end

    return true
end

function mail:can_delete()
    for _, att in ipairs(self.attachments) do
        if att:is_unclaimed() then
            return false, "先领取奖励"
        end
    end
    return true
end
--热更新时把新元表重新挂到mail和附件对象
local function remount_mails()
    for _, m in pairs(s.data.mails or {}) do
        setmetatable(m, mail)
        for _, att in ipairs(m.attachments or {}) do
            setmetatable(att, attach_item)
        end
    end
end

remount_mails()

-------------------------------------------------------------------------------------------
function s.mail_init()
    local safe_playerid = s.db.quote_sql_str(s.id)
    local sql = string.format(
        [[select mail_id,sender_id,title,content,is_read,create_time,expire_time
        from mail
        where playerid=%s
        order by create_time desc
        limit 200]],
        safe_playerid
    )
    local res = s.db:query(sql)
    if db_failed(res) then
        error("加载玩家邮件数据失败: playerid=" .. tostring(s.id))
    end
    for _, row in ipairs(res) do
        local m = mail.new(
            row.mail_id,
            row.sender_id,
            row.title,
            row.content,
            row.is_read,
            row.create_time or "",
            row.expire_time or ""
        )
        s.data.mails[row.mail_id] = m
    end

    for mid, m in pairs(s.data.mails) do
        sql = string.format(
            [[select id,item_id,cnt,is_claimed
            from mail_attachment
            where mail_id=%s]],
            mid
        )
        res = s.db:query(sql)
        if db_failed(res) then
            error("加载玩家邮件附件数据失败: playerid=" .. tostring(s.id))
        end
        for _, row in ipairs(res) do
            table.insert(
                m.attachments,
                attach_item.new(row.id, row.item_id, row.cnt, row.is_claimed)
            )
        end
    end
end

--客户端请求邮件列表
function s.client.mail_list(msg)
    local list = {}
    for mid, m in pairs(s.data.mails) do
        if not m:is_expired() then
            table.insert(list, m:to_brief())
        end
    end
    return { "mail_list", mails = list }
end

--客户端请求读邮件
function s.client.mail_read(msg)
    local mid = msg.mail_id
    local m = s.data.mails[mid]
    if not m or m:is_expired() then
        return { "mail_read", code = 1, msg = "邮件不存在或者过期" }
    end
    m:mark_read()
    s.mark_dirty("mails")
    return { "mail_read", code = 0, msg = "成功", detail = m }
end

--客户端请求领取附件
function s.client.mail_claim(msg)
    local mid = msg.mail_id
    local m = s.data.mails[mid]
    if not m then
        return { "mail_claim", code = 1, msg = "邮件不存在" }
    end

    --领取
    local ok, err = m:claim_attachments()
    if not ok then
        return { "mail_claim", code = 1, msg = err }
    end
    s.mark_dirty("mails")
    return { "mail_claim", code = 0, msg = "领取成功" }
end

--客户端请求删邮件
function s.client.mail_delete(msg)
    local mid = msg.mail_id
    local m = s.data.mails[mid]
    if not m then
        return { "mail_delete", code = 1, msg = "邮件不存在" }
    end
    --看附件领没领
    local ok, err = m:can_delete()
    if not ok then
        return { "mail_delete", code = 1, msg = err }
    end
    s.data.mails[mid] = nil
    table.insert(s.deleted_mails_id, mid)
    s.mark_dirty("mails")
    return { "mail_delete", code = 0, msg = "删除成功" }
end

--存储邮件
function s.storage_mail(target_id, title, content, attachments, expire_seconds)
    local safe_target_id = s.db.quote_sql_str(target_id)
    local safe_title = s.db.quote_sql_str(title)
    local safe_content = s.db.quote_sql_str(content)
    local expire_sql = "NULL"
    local expire_time
    local tx, err = s.db:begin()
    if not tx then
        return false, err or "事务开启失败"
    end
    if expire_seconds and expire_seconds > 0 then
        expire_time = os.date("%Y-%m-%d %H:%M:%S", os.time() + expire_seconds)
        expire_sql = s.db.quote_sql_str(expire_time)
    end
    local sender_id = s.id
    if s.id == target_id then
        sender_id = 0
    end
    local sql = string.format(
        [[insert into mail
        (playerid,sender_id,title,content,expire_time)
        values (%s,%d,%s,%s,%s)
    ]],
        safe_target_id,
        sender_id,
        safe_title,
        safe_content,
        expire_sql
    )

    local res = tx:query(sql)

    if db_failed(res) then
        tx:rollback()
        return false
    end

    local mail_id = res.insert_id
    local att_data = {}
    for _, att in ipairs(attachments or {}) do
        sql = string.format(
            "insert into mail_attachment (mail_id,item_id,cnt) values (%d,%d,%d)",
            mail_id,
            att.item_id,
            att.count
        )
        res = tx:query(sql)
        if db_failed(res) then
            tx:rollback()
            return false
        end
        table.insert(att_data, attach_item.new(res.insert_id, att.item_id, att.count, 0))
    end
    local commit_res = tx:commit()
    if db_failed(commit_res) then
        tx:rollback()
        return false
    end

    return true,
        mail.new(
            mail_id,
            sender_id,
            title,
            content,
            0,
            os.date("%Y-%m-%d %H:%M:%S"),
            expire_time,
            att_data
        )
end

--发送邮件
function s.send_mail(target_id, title, content, attachments, expire_seconds)
    local res, m = s.storage_mail(target_id, title, content, attachments, expire_seconds)
    if not res then
        return false
    end
    --向agentmgr查询目标是否在线
    local player = s.call(runconfig.agentmgr.node, "agentmgr", "get_player", target_id)

    --在线,需要通知对方的玩家代理
    if player and player.agent then
        s.send(player.node, player.agent, "new_mail", m)
    end

    return true
end

--通过批处理id加载邮件到内存
function repo.load_mail_by_batch_id(batch_id)
    local safe_batch_id = s.db.quote_sql_str(batch_id)
    local safe_playerid = s.db.quote_sql_str(s.id)
    local res_m = s.db:query(
        string.format(
            [[select mail_id,sender_id,title,content,is_read,create_time,expire_time
        from mail
        where playerid=%s and batch_id=%s
        ]],
            safe_playerid,
            safe_batch_id
        )
    )
    if db_failed(res_m) then
        return nil, nil, "加载新邮件失败"
    end
    if res_m[1] == nil then
        return nil, nil, "玩家没有该邮件"
    end
    local res_a = s.db:query(string.format(
        [[select id,item_id,cnt,is_claimed
            from mail_attachment
            where mail_id=%s]],
        res_m[1].mail_id
    ))
    if db_failed(res_a) then
        return nil, nil, "加载新邮件附件失败"
    end
    return res_m, res_a
end

--接受其他服务的发的邮件，更新内存并且通知客户端
function s.resp.new_mail(sourse, n_mail, batch_id)
    if batch_id then --策划批量发的邮件
        local m, a, err = repo.load_mail_by_batch_id(batch_id)
        if not m or not a then
            skynet.error(err)
            return
        end
        for _, v in ipairs(a) do
            v.count = v.cnt
            v.cnt = nil
        end
        --让表成为对象
        setmetatable(m[1], mail)
        s.data.mails[m[1].mail_id] = m[1]
        for _, a_row in ipairs(a) do
            setmetatable(a_row, attach_item)
        end
        m[1].attachments = a

        --构造提醒消息,提醒客户端
        if s.gate then
            skynet.send(s.gate, "lua", "send", s.id, { "mail_notify", mail = m[1]:to_brief() })
        end
        return
    end

    --其他邮件
    --让表成为对象
    s.data.mails[n_mail.mail_id] = setmetatable(n_mail, mail)
    for _, v in ipairs(n_mail.attachments or {}) do
        setmetatable(v, attach_item)
    end
    --构造提醒消息,提醒客户端
    if s.gate then
        skynet.send(
            s.gate,
            "lua",
            "send",
            s.id,
            { "mail_notify", mail = s.data.mails[n_mail.mail_id]:to_brief() }
        )
    end
end

function s.leave_mail()
    for mid, m in pairs(s.data.mails) do
        local sql = string.format("update mail set is_read=%d where mail_id=%d", m.is_read, mid)
        local res = s.db:query(sql)
        if db_failed(res) then
            skynet.error(
                "保存邮件已读状态失败: playerid="
                    .. tostring(s.id)
                    .. " mail_id="
                    .. tostring(mid)
            )
            return false
        end
        for _, att in ipairs(m.attachments or {}) do
            sql = string.format(
                "update mail_attachment set is_claimed=%d where id=%d",
                att.is_claimed,
                att.id
            )
            res = s.db:query(sql)
            if db_failed(res) then
                skynet.error(
                    "保存附件领取状态失败: playerid="
                        .. tostring(s.id)
                        .. " attach_id="
                        .. tostring(att.id)
                )
                return false
            end
        end
    end
    for _, mid in ipairs(s.deleted_mails_id) do
        local sql = string.format("delete from mail where mail_id=%d", mid)
        local res = s.db:query(sql)
        if db_failed(res) then
            skynet.error(
                "删除邮件失败: playerid=" .. tostring(s.id) .. " mail_id=" .. tostring(mid)
            )
            return false
        end
        --设置了级联删除
        --sql = string.format("delete from mail_attachment where mail_id=%d", mid)
        --s.db:query(sql)
    end
    s.deleted_mails_id = {}
    return true
end
