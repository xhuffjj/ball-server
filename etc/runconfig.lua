--配置文件供主程序读取

return {
    --集群信息
    cluster = {
        node1 = "127.0.0.1:7771",
        node2 = "127.0.0.1:7772",
    },
    --agentmgr的位置
    agentmgr = { node = "node1" },
    --admin位置
    admin = { node = "node1" },
    --cron位置
    cron = { node = "node1" },
    --dbsync位置
    dbsync = { node = "node1" },
    --match服务位置
    match = { node = "node1" },
    --room允许的节点
    room_nodes = { "node1", "node2" },

    --[[scene所在节点
	scene = {
		node1 = { 1001, 1002 },
		node2 = { 1003 }
	},]]
    --roommgr位置，因为启动后会在各节点启动room和scene服务，建议放在最后启动的节点，否则启动时会打印报错信息（不影响正常运行）
    roommgr = { node = "node2" },
    hotfixmgr = { node = "node1" },
    mysqlproxy = {
        node = "node1",
        pool_size = 8,
        host = "127.0.0.1",
        port = 3306,
        database = "player_message",
        user = "root",
        password = "123456",
        max_packet_size = 1024 * 1024,
    },

    redis = {
        host = "127.0.0.1",
        port = 6379,
        auth = "123456",
    },
    --节点的信息
    node1 = {
        --结点1网关服务的信息
        gateway = {
            [1] = { port = 8001 },
            [2] = { port = 8002 },
        },
        login = { --这里主要记录有多少登录服务
            [1] = {},
            [2] = {},
        },
        battle_gateway = { --战斗网关信息
            [1] = {
                bind_host = "0.0.0.0", --绑定的地址
                public_host = "192.168.164.129", --发给客户端
                port = 9001,
            },
        },
        debug_console = { port = 7000 },
    },
    node2 = {
        gateway = {
            [1] = { port = 8011 },
            [2] = { port = 8022 },
        },
        login = {
            [1] = {},
            [2] = {},
        },
        battle_gateway = { --战斗网关信息
            [1] = {
                bind_host = "0.0.0.0",
                public_host = "192.168.164.129",
                port = 9011,
            },
        },
        debug_console = { port = 7001 },
    },
}
