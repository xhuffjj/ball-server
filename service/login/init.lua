local skynet = require "skynet"
local s = require "service"
local mysql = require "skynet.db.mysql"
local crypt = require "skynet.crypt" -- skynet 自带加密库
local db
local pb = require "protobuf"
local srp = require "srp"

--定义消息名client,即从客户端来的消息,这是暴露给客户端的api
--存放客户端消息的各种协议处理函数
s.client = {}

local function db_failed(res)
	return (not res) or res.badresult or res.errno
end
--和数据库交互的函数
local repo = {}

--账号->[{session=server_session,timer=time}]
local login_session = {}

-----------------------------------------------注册相关-------------------------
local function register_ok()
	return { "register", code = 0, msg = "注册成功" }
end
local function register_fail(msg)
	return { "register", code = 1, msg = msg }
end
---------------------------数据库交互
function repo.save_register_message(playerid, salt, verifier, role_data)
	local safe_id = db.quote_sql_str(playerid) --自动加引号，处理特殊字符（防止sql注入）
	local safe_salt = db.quote_sql_str(salt)
	local safe_verifier = db.quote_sql_str(verifier)
	local sql = string.format("select salt from login_message where username=%s", safe_id)
	local res = db:query(sql)
	if db_failed(res) then
		return false, "查询玩家账号信息时失败"
	end

	if res and #res > 0 then
		return false, "账号已存在"
	end

	--准备记录账号信息，金币信息
	res = db:query("START TRANSACTION")
	if db_failed(res) then
		skynet.error("开启事务失败: " .. res.err)
		return false, "事务开启失败"
	end

	--插入账号信息
	sql = string.format("insert into login_message (username, salt, verifier) values (%s, %s, %s)", safe_id,
		safe_salt, safe_verifier)
	res = db:query(sql)
	if db_failed(res) then
		db:query("ROLLBACK")
		return false, "向数据库注册账号失败"
	end

	local role_msg = pb.encode("GameData.role_message", role_data)
	local role_sql = db.quote_sql_str(role_msg)
	sql = string.format("insert into role_message (playerid, data) values (%s, %s)", safe_id, role_sql)
	res = db:query(sql)
	if db_failed(res) then
		db:query("ROLLBACK")
		return false, "向数据库注册角色数据失败"
	end

	res = db:query("COMMIT")
	if db_failed(res) then
		db:query("ROLLBACK")
		return false, "注册失败: 提交事务错误"
	end
	return true, "注册成功"
end

--注册处理
function s.client.register(fd, msg, source)
	local playerid = msg.playerid --用户名
	local salt = msg.salt
	local verifier = msg.verifier
	--初始化角色数据
	local role_data = {
		coin = 0,
		level = 1,
		exp = 0,
		vip_level = 0,
		rank_score = 1000
	}
	local ok, err = repo.save_register_message(playerid, salt, verifier, role_data)
	if not ok then
		return register_fail(err)
	end
	return register_ok()
end

-------------------------------------------登录相关----------------------------、
local function login_first_ok(salt, B)
	return { "login_first", code = 0, salt = salt, B = B }
end
local function login_first_fail(msg, playerid) --传playerid代表终止服务器会话
	if playerid then
		login_session[playerid] = nil
	end

	return { "login_first", code = 1, msg = msg }
end
--数据库加载盐和校验子
function repo.load_salt_verifier(playerid)
	local safe_playerid = db.quote_sql_str(playerid)
	local sql = string.format("select verifier,salt from login_message where username=%s", safe_playerid)
	local res = db:query(sql)
	if db_failed(res) then --res为空是数据库出错，查询不到时res是空表
		return false, "查询账号数据时出错"
	end
	if res and #res == 0 then
		return false, "账号不存在"
	end
	return true, nil, res[1].salt, res[1].verifier
end

--登录处理：计算B,返回salt和B
function s.client.login_first(fd, msg, source)
	local playerid = msg.playerid --用户名
	local A = msg.A

	if not playerid or not A then
		return login_first_fail("登录参数缺失")
	end

	if login_session[playerid] then
		return login_first_fail("正在登录中，请勿重复点击")
	end
	login_session[playerid] = { session = false, timer = os.time() }
	local session_ok, err, salt, verifier = repo.load_salt_verifier(playerid)
	if not session_ok then
		return login_first_fail(err, playerid)
	end

	--创建服务器校验会话
	local server_session, B_or_err = srp.create_session(playerid, salt, verifier, A)
	if not server_session then
		return login_first_fail("服务器创建登录会话失败: " .. B_or_err, playerid)
	end
	login_session[playerid] = { session = server_session, timer = os.time() }

	return login_first_ok(salt, B_or_err)
end

-------------------------------------------登录2阶段-----------------------------
local function login_second_ok(M2, playerid, token)
	if playerid then
		login_session[playerid] = nil
	end
	return { "login_second", code = 0, M2 = M2, msg = "登陆成功", token = token }
end
local function login_second_fail(msg, playerid)
	if playerid then
		login_session[playerid] = nil
	end
	return { "login_second", code = 1, msg = msg }
end

--登录处理：计算M2,并验证
function s.client.login_second(fd, msg, source)
	local playerid = msg.playerid
	local M1 = msg.M1
	local gate = source
	local node = skynet.getenv("node")

	if not playerid or not M1 then
		return login_second_fail("用户名或M1为空")
	end
	if not login_session[playerid] or not login_session[playerid].session then
		return login_second_fail("服务端的验证会话不存在/正在创建")
	end
	local server_session = login_session[playerid].session
	--校验
	local M2 = server_session:verify(M1)
	if not M2 then
		login_session[playerid] = nil
		return login_second_fail("密码错误", playerid)
	end

	--向agentmgr请求登录
	local isok, agent,login_version = skynet.call("agentmgr", "lua", "reqlogin", tonumber(playerid), node, gate)
	if not isok then
		login_session[playerid] = nil
		return login_second_fail("请求mgr失败", playerid)
	end
	if not agent then
		login_session[playerid] = nil
		return login_second_fail("初始化角色代理失败", playerid)
	end
	local isok, token = skynet.call(gate, "lua", "sure_agent", fd, tonumber(playerid), agent,login_version)
	if not isok or not token then
		login_session[playerid] = nil
		return login_second_fail("login向gate注册失败", playerid)
	end
	login_session[playerid] = nil
	return login_second_ok(M2, playerid, token)
end

s.resp.client = function(source, fd, cmd, msg) --
	if s.client[cmd] then
		local ret_msg = s.client[cmd](fd, msg, source)

		skynet.send(source, "lua", "send_by_fd", fd, ret_msg)
	else
		skynet.error("s.resp.client failed: " .. cmd)
	end
end

--清理10秒内没有回复登录第二阶段的绘画
local function Timer()
	while (true) do
		for i, v in pairs(login_session) do
			if os.time() - v.timer > 10 then
				login_session[i] = nil
			end
		end
		skynet.sleep(100)
	end
end

function s.init()
	db = mysql.connect({
		host = "127.0.0.1",
		port = 3306,
		database = "player_message",
		user = "root",
		password = "123456",
		max_packet_size = 1024 * 1024, --最大接收包大小（1MB
		on_connect = nil         --连接建立时的回调函数
	})
	pb.register_file("./storage/GameData.pb")
	skynet.fork(Timer)
end

s.start(...)
