local skynet = require "skynet"
local s = require "service"
local mysql = require "skynet.db.mysql"
local runconfig = require "runconfig"

local db = nil
local function db_failed(res)
    return (not res) or res.badresult or res.errno
end
local function db_failed_err(res)
	return string.format("failed | errno=%s | badresult=%s | err=%s",
		tostring(res and res.errno),
		tostring(res and res.badresult),
		tostring(res and res.err))
end
------------------------工具函数，计算自某个起始时间的天数/周数等--------------------------------------
--自1070.1.1.00：00的天数
local function get_day(timestamp)
    return (timestamp + 3600 * 8-3600*12-60*43) // 86400
end
--自1070.1.1.00：00的周数
local function get_week(timestamp)
    return (timestamp + 3600 * 8) // (86400 * 7)
end


------------------------------------------------------------------------------------------------------------
--定时任务类
local function job(jname, jid, get_period, callback, last_check_time)
    local m = {
        jname = jname,
        jid = jid,
        get_period = get_period, --周期函数
        callback = callback,     --定时到的回调函数
        last_check_time = last_check_time,
        running=false--防重入
    }
    return m
end
--[jid]->job
local jobs = {}
--注册定时任务到job表
local function register_job(jname, jid, get_period_fn, callback)
    jobs[jid] = job(jname, jid, get_period_fn, callback)
end



----------------------------------注册定时任务----------------------------------------------------

register_job("daily_reset", 0,get_day, function()
    skynet.error("[cron] 每日重置开始")
    local node = runconfig.agentmgr.node
    local isok,ret=pcall(s.call,node, "agentmgr", "daily_reset")
    return isok and ret==true
end)



---------------------------------------------------------------------------------------------------------
--落库上次检查时间
local function save_last_check_time(j)
    local safe_jid = db.quote_sql_str(j.jid)
    local safe_name = db.quote_sql_str(j.jname)
    local res = db:query(string.format("replace into cron (jid,jname,last_check_time) values (%s,%s,%d)", safe_jid,
        safe_name,
        j.last_check_time))
    if db_failed(res) then

        skynet.error("保存last_check_time失败： " .. j.jname)
        skynet.error(db_failed_err(res))
    end
end

--定时器
local function Timer()
    while true do
        for jid, j in pairs(jobs) do
            local last_period = j.get_period(j.last_check_time)
            local now = os.time()
            local now_period = j.get_period(now)
           
            if now_period > last_period and not j.running then
                j.running=true
                skynet.fork(function ()
                    local ok,run_ok=pcall(j.callback)
                    if ok and run_ok then
                         j.last_check_time = now
                         save_last_check_time(j)
                    else
                        skynet.error("[cron] job failed: " .. j.jname)
                    end
                    j.running=false
                end)
                
            end
        end
        skynet.sleep(100)
    end
end


-------------------------------------------------------------------------------------------------------------------
function s.init()
    db = mysql.connect({
        host = "127.0.0.1",
        port = 3306,
        database = "player_message",
        user = "root",
        password = "123456",
        max_packet_size = 1024 * 1024,
        on_connect = nil
    })
    local res = db:query("select jid,last_check_time from cron")
    if db_failed(res) then
        error("加载定时任务失败")
    end
    --id->last_check_time
    local last_check_times = {}
    --先从数据库加载上次检查时间
    for _, v in ipairs(res) do
        last_check_times[v.jid] = v.last_check_time
    end
    for jid, j in pairs(jobs) do
        j.last_check_time = last_check_times[jid] or os.time()
        skynet.error(string.format("[cron]加载 %s id:%d last_check_time:%d", j.jname, jid, j.last_check_time))
    end
    skynet.fork(Timer)
end

s.start(...)
