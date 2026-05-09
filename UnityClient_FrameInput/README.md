# 球球大作战 - Unity 测试客户端

## 使用方法

### 1. 在 Unity 中打开项目
1. 打开 Unity Hub
2. 点击 "Add" → 选择 `UnityClient` 文件夹
3. 建议使用 Unity **2022.3 LTS**（已写入 `ProjectSettings/ProjectVersion.txt`）
4. 选择 **2D** 模板（如果创建新项目）

### 2. 项目结构
```
Assets/
├── Plugins/
│   └── Google.Protobuf.dll       # Protobuf C# 运行时库 (netstandard2.0)
├── Proto/
│   └── Game.cs                   # 从 game.proto 生成的 C# 类
└── Scripts/
    ├── Bootstrap.cs              # 自动初始化（无需手动操作）
    ├── Network/
    │   ├── NetworkManager.cs     # TCP 连接和协议分包
    │   └── ProtocolHandler.cs    # 消息注册和分发
    ├── UI/
    │   └── LoginUI.cs            # 登录/注册界面 (IMGUI)
    └── Game/
        ├── GameManager.cs        # 游戏状态管理
        ├── PlayerController.cs   # 移动控制
        ├── BallEntity.cs         # 球球实体
        └── FoodEntity.cs         # 食物实体
```

### 3. 运行
1. 确保服务器已启动（在 Linux 虚拟机上执行 `sh start.sh 1` 和 `sh start.sh 2`）
2. 在 Unity 中打开任意场景（甚至空场景都可以，Bootstrap 会自动初始化）
3. 按 **Play** 按钮
4. 输入服务器 IP（虚拟机的 IP，如 `192.168.164.129`）和端口（`8001`）
5. 点击 **连接服务器**
6. 输入玩家ID（如 `101`）和密码（如 `999`），点击 **登录**
7. 登录成功后点击 **进入战斗**

### 4. 操控
- **鼠标**: 球球会朝鼠标方向移动
- **WASD / 方向键**: 直接控制方向
- **Space**: 分裂
- **Q**: 吐孢子
- **X**: 停止移动

### 5. 战斗协议
- 战斗输入统一走 `input_frame`
- 客户端每 **50ms** 发送一次输入帧
- 同一个 50ms 窗口内，`split` 和 `spit` 都最多只会合并发送一次
- 场景下发使用 `scene_snapshot` 和 `frame_update`

### 6. 协议格式
```
[2字节大端: 内容总长度][2字节大端: 命令名长度][命令名字符串][protobuf序列化体]
```
与服务器 gateway 使用 skynet netpack 的格式完全匹配。

### 7. 注意事项
- Player API Level 需要设置为 `.NET Standard 2.1` 或 `.NET 4.x`
  （Edit → Project Settings → Player → Api Compatibility Level）
- 如果 Google.Protobuf.dll 报错，可以在 Unity Package Manager 中搜索安装，或重新放入 Plugins 文件夹
- `Assets/Plugins` 里需要同时存在 `Google.Protobuf.dll`、`System.Buffers.dll`、`System.Memory.dll`、`System.Runtime.CompilerServices.Unsafe.dll`
- 建议使用数字玩家ID（如 `101`）。客户端会优先使用登录输入的玩家ID，只有在单人场景时才进行兜底推断
- 如果仍出现“before 5.0 / 需要重导入”提示：关闭项目后确认 `ProjectSettings/ProjectVersion.txt` 存在，再重新从 Unity Hub 打开
