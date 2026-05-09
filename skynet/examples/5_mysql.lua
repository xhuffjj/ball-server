local skynet=require "skynet"
local mysql=require "skynet.db.mysql"

skynet.start(function()
	local db=mysql.connect({
		host="192.168.164.129",
		port=3306,
		database="message_board",
		user="root",
		password="123456",
		max_packet_size=1024*1024,--最大接收包大小（1MB
		on_connect=nil--连接建立时的回调函数
	})
	
	--插入
	local res=db:query("insert into msgs (text) values (\'hehe\')")
	--查询
	res=db:query("select * from msgs")
	--返回的是key为行号，value是表{字段1=值，字段2=值...}
	--打印
	for i,v in pairs(res) do
		print(i," ",v.id," ",v.text)
	end
end

)
