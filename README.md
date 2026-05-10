# 球球大作战服务端

基于 Skynet 的球球大作战服务端项目，包含登录、网关、玩家 agent、匹配、房间、战斗网关、场景、背包、好友、邮件、成就、数据库同步等服务。

仓库中同时包含一个 Unity 测试客户端。客户端主要用于测试服务端功能，不是完整商业客户端。

## 运行环境

- Linux x86_64
- MySQL 8.x
- Redis
- Unity 2022.3 LTS（仅客户端需要）

## 项目结构

```text
.
├── service/                  # Skynet 业务服务
│   ├── main.lua              # 服务端入口
│   ├── gateway/              # 登录/大厅网关
│   ├── battle_gateway/       # 战斗网关
│   ├── agent/                # 玩家 agent 逻辑
│   ├── agentmgr/             # 玩家 agent 管理
│   ├── match/                # 匹配服务
│   ├── room/                 # 房间服务
│   ├── roommgr/              # 房间管理
│   ├── scene/                # 场景和战斗逻辑
│   ├── mysqlproxy/           # MySQL 连接池代理
│   ├── redisproxy/           # Redis 代理
│   └── dbsync/               # Redis 到 MySQL 的同步服务
├── etc/                      # Skynet 配置和运行配置
│   ├── config.node1
│   ├── config.node2
│   └── runconfig.lua
├── lualib/                   # 项目 Lua 库
├── luaclib/                  # 项目 C 扩展库
├── luaclib_src/              # C 扩展源码
├── proto/                    # 通信协议
├── storage/                  # 存储协议
├── skynet/                   # Skynet 源码
├── UnityClient_FrameInput/   # Unity 测试客户端
├── db.sql                    # MySQL 表结构
└── start.sh                  # 节点启动脚本
```

## 服务端运行方法

### 1. 编译 Skynet

下载项目后需要先编译 Skynet：

```bash
cd skynet
make linux
```

编译完成后回到项目根目录：

```bash
cd ..
```

### 2. 初始化 MySQL

项目默认数据库名为 `player_message`。先创建数据库：

```bash
mysql -uroot -p -e "CREATE DATABASE IF NOT EXISTS player_message DEFAULT CHARSET utf8mb4;"
```

导入表结构：

```bash
mysql -uroot -p player_message < db.sql
```

默认 MySQL 配置在 `etc/runconfig.lua`：

```lua
mysqlproxy = {
    host = "127.0.0.1",
    port = 3306,
    database = "player_message",
    user = "root",
    password = "123456",
}
```

如果你的本地 MySQL 用户名或密码不同，需要修改 `etc/runconfig.lua`。

### 3. 启动 Redis

项目默认连接本机 Redis：

```lua
redis = {
    host = "127.0.0.1",
    port = 6379,
    auth = "123456",
}
```

如果 Redis 没有密码，或密码不是 `123456`，需要同步修改 `etc/runconfig.lua`。

### 4. 启动服务端

必须在项目根目录执行，并且启动顺序不能更改：

```bash
sh start.sh 1
sh start.sh 2
```

`start.sh` 会根据参数启动不同节点：

```bash
./skynet/skynet ./etc/config.node$1
```

也就是：

```text
sh start.sh 1 -> etc/config.node1
sh start.sh 2 -> etc/config.node2
```

### 5. 默认端口

当前默认配置：

```text
node1 gateway:        8001, 8002
node2 gateway:        8011, 8022
node1 battle_gateway: 9001
node2 battle_gateway: 9011
node1 debug_console:  7000
node2 debug_console:  7001
cluster node1:        7771
cluster node2:        7772
```

战斗网关发给客户端的公网地址配置在 `etc/runconfig.lua`：

```lua
public_host = "192.168.164.129"
```

如果客户端和服务器不在同一台机器，需要改成服务器实际 IP。

## 客户端运行方法

客户端目录：

```text
UnityClient_FrameInput/
```

使用方法：

1. 使用 Unity Hub 打开 `UnityClient_FrameInput`
2. 建议使用 Unity `2022.3 LTS`
3. 确保服务端已经按顺序启动 `node1` 和 `node2`
4. 在 Unity 中 Build 后运行，或直接在编辑器中 Play
5. 连接服务器 IP 和网关端口，例如 `192.168.164.129:8001`

客户端说明详见：

```text
UnityClient_FrameInput/README.md
```

客户端主要用于测试服务端功能，包含登录、大厅、好友、邮件、背包、成就、匹配和战斗输入等测试界面。

## 协议说明

项目协议主要位于：

```text
proto/
storage/
```

客户端使用的 C# 协议文件位于：

```text
UnityClient_FrameInput/Assets/Proto/
```

通信包格式：

```text
[2字节大端: 内容总长度][2字节大端: 命令名长度][命令名字符串][protobuf序列化体]
```

战斗输入统一走 `input_frame`，场景同步主要使用 `scene_snapshot` 和 `frame_update`。

## 注意事项

- 第一次下载项目后需要编译 Skynet。
- 启动服务端时必须先启动 `sh start.sh 1`，再启动 `sh start.sh 2`。
- MySQL 和 Redis 的密码需要和 `etc/runconfig.lua` 保持一致。
- `public_host` 需要改成客户端能访问到的服务器 IP。
- `UnityClient_FrameInput/Library`、`Temp`、`Obj` 等 Unity 自动生成目录不会提交到仓库。
- 当前客户端是测试客户端，主要用于验证服务端功能。
