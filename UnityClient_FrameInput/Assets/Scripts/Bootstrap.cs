using UnityEngine;

/// <summary>
/// 引导程序 - 自动初始化所有管理器
/// 使用 [RuntimeInitializeOnLoadMethod] 自动启动，无需手动挂载
/// 会创建一个持久化的 GameObject 并挂载所有核心组件
/// </summary>
public class Bootstrap
{
    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSplashScreen)]
    static void ConfigureStartupWindow()
    {
#if UNITY_STANDALONE
        Resolution desktop = Screen.currentResolution;
        int targetWidth = Mathf.Min(1280, Mathf.Max(640, desktop.width - 80));
        int targetHeight = Mathf.Min(720, Mathf.Max(480, desktop.height - 120));

        Screen.fullScreenMode = FullScreenMode.Windowed;
        Screen.fullScreen = false;
        Screen.SetResolution(targetWidth, targetHeight, FullScreenMode.Windowed);

        Debug.Log($"[Bootstrap] 已切换为窗口模式: {targetWidth}x{targetHeight}");
#endif
    }

    [RuntimeInitializeOnLoadMethod(RuntimeInitializeLoadType.BeforeSceneLoad)]
    static void Init()
    {
        Debug.Log("[Bootstrap] 球球大作战客户端正在初始化...");

        // 允许窗口失去焦点后继续运行，方便同时开多个客户端联调
        Application.runInBackground = true;

        // 关闭垂直同步并取消目标帧率上限，让客户端按设备可达到的最高帧率渲染
        QualitySettings.vSyncCount = 0;
        Application.targetFrameRate = -1;

        // 创建根 GameObject
        GameObject root = new GameObject("=== 球球大作战客户端 ===");
        Object.DontDestroyOnLoad(root);

        // 挂载核心管理器
        root.AddComponent<NetworkManager>();
        root.AddComponent<ProtocolHandler>();
        root.AddComponent<BattleNetworkManager>();
        root.AddComponent<ClientSession>();
        root.AddComponent<GameManager>();
        root.AddComponent<PlayerController>();
        root.AddComponent<LoginUI>();

        // 挂载大厅和功能面板
        root.AddComponent<LobbyUI>();
        root.AddComponent<FriendPanel>();
        root.AddComponent<MailPanel>();
        root.AddComponent<AchievePanel>();
        root.AddComponent<BagPanel>();
        root.AddComponent<ProtocolTracePanel>();

        Debug.Log("[Bootstrap] 初始化完成!");
        Debug.Log("[Bootstrap] 使用说明:");
        Debug.Log("[Bootstrap]   1. 输入服务器 IP 和端口，点击 \"连接服务器\"");
        Debug.Log("[Bootstrap]   2. 输入玩家ID和密码，点击 \"登录\"");
        Debug.Log("[Bootstrap]   3. 登录成功后点击 \"开始匹配\"，匹配成功后点击 \"准备\"");
        Debug.Log("[Bootstrap]   4. 使用鼠标方向或 WASD 控制移动");
        Debug.Log("[Bootstrap]   5. Space 分裂，Q 吐孢子，X 停止移动");
    }
}
