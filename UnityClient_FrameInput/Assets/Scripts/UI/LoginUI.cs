using System;
using System.Security.Cryptography;
using System.Text;
using SecureRemotePassword;
using Google.Protobuf;
using Game;
using UnityEngine;

/// <summary>
/// 登录界面 - 使用 Unity IMGUI 实现（无需预制体）
/// 提供登录、注册功能，成功后进入游戏
/// </summary>
public class LoginUI : MonoBehaviour
{
    public static LoginUI Instance { get; private set; }

    private string _playerid = "101";
    private string _password = "999";
    private string _serverIP = "192.168.164.129";
    private string _serverPort = "8001";
    private string _statusMsg = "";
    private bool _isLoggedIn = false;
    private bool _isConnected = false;
    private bool _isInScene = false;
    private bool _showLobby = false;

    // UI 样式
    private GUIStyle _titleStyle;
    private GUIStyle _statusStyle;
    private GUIStyle _buttonStyle;
    private GUIStyle _inputStyle;
    private GUIStyle _labelStyle;
    private GUIStyle _boxStyle;
    private GUIStyle _logStyle;
    private bool _stylesInitialized = false;

    // 日志
    private string _logText = "";
    private Vector2 _logScroll;
    private int _maxLogLines = 50;

    // SRP 握手状态（登录两阶段）
    private bool _isLoggingIn = false;
    private string _pendingLoginPlayerId = "";
    private string _pendingLoginPassword = "";
    private SrpClient _pendingSrpClient;
    private string _pendingASecretHex = "";
    private string _pendingAPublicHex = "";
    private SrpSession _pendingSrpSession;
    private byte[] _pendingABytes;
    private byte[] _pendingM1Bytes;
    private byte[] _pendingSessionKeyBytes;

    // 与服务端 csrp 默认组参数对齐
    private const string SrpN2048Hex =
        "AC6BDB41324A9A9BF166DE5E1389582FAF72B6651987EE07FC3192943DB56050A37329CBB4" +
        "A099ED8193E0757767A13DD52312AB4B03310DCD7F48A9DA04FD50E8083969EDB767B0CF60" +
        "95179A163AB3661A05FBD5FAAAE82918A9962F0B93B855F97993EC975EEAA80D740ADBF4FF" +
        "747359D041D5C33EA71D281E446B14773BCA97B43A23FB801676BD207A436C6481F1D2B907" +
        "8717461A5B9D32E688F87748544523B524B0D57D5EA77A2775D2ECFA032CFBDBF52FB37861" +
        "60279004E57AE6AF874E7303CE53299CCC041C7BC308D82A5698F3A8D0C38271AE35F8E9DB" +
        "FBB694B5C803D89F7AE435DE236D525F54759B65E372FCD68EF20FA7111F9E4AFF73";
    private const string SrpGHex = "02";

    private static bool _srpInitTried = false;
    private static bool _srpInitOk = false;
    private static string _srpInitErr = "";

    void Start()
    {
        Instance = this;

        // 监听连接状态
        NetworkManager.Instance.OnConnectionChanged += OnConnectionChanged;

        // 监听协议
        ProtocolHandler.Instance.On<LoginFirstRes>("login_first", OnLoginFirstRes);
        ProtocolHandler.Instance.On<LoginSecondRes>("login_second", OnLoginSecondRes);
        ProtocolHandler.Instance.On<RegisterRes>("register", OnRegisterRes);

        if (ClientSession.Instance != null)
        {
            ClientSession.Instance.OnReconnectNotice += OnReconnectNotice;
        }
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
            NetworkManager.Instance.OnConnectionChanged -= OnConnectionChanged;

        if (ClientSession.Instance != null)
        {
            ClientSession.Instance.OnReconnectNotice -= OnReconnectNotice;
        }

        if (Instance == this)
        {
            Instance = null;
        }
    }

    private void InitStyles()
    {
        UIArtTheme.EnsureInit();

        _titleStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 32,
            fontStyle = FontStyle.Bold,
            alignment = TextAnchor.MiddleCenter
        };
        _titleStyle.normal.textColor = new Color(0.72f, 0.93f, 1f);

        _statusStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 16,
            alignment = TextAnchor.MiddleCenter,
            wordWrap = true
        };
        _statusStyle.normal.textColor = new Color(0.9f, 0.95f, 1f);

        _buttonStyle = new GUIStyle(GUI.skin.button)
        {
            fontSize = 18,
            fixedHeight = 40
        };
        UIArtTheme.SkinButton(_buttonStyle);

        _inputStyle = new GUIStyle(GUI.skin.textField)
        {
            fontSize = 18,
            fixedHeight = 35
        };
        UIArtTheme.SkinInput(_inputStyle);

        _labelStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 16,
            alignment = TextAnchor.MiddleLeft
        };
        _labelStyle.normal.textColor = new Color(0.82f, 0.92f, 1f);

        _boxStyle = new GUIStyle(GUI.skin.box)
        {
            padding = new RectOffset(20, 20, 20, 20)
        };
        _boxStyle.normal.background = UIArtTheme.PanelTex;

        _logStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 12,
            wordWrap = true,
            richText = true
        };
        _logStyle.normal.textColor = new Color(0.72f, 1f, 0.84f);

        _stylesInitialized = true;
    }

    void OnGUI()
    {
        if (!_stylesInitialized) InitStyles();

        // 已在战斗场景中，不显示登录UI
        if (_isInScene) return;
        // 登录后如果大厅可见，登录UI隐藏
        if (_showLobby && LobbyUI.Instance != null && LobbyUI.Instance.IsVisible) return;
        // 登录后大厅不可见时，显示兜底面板（避免没有匹配入口）
        if (_showLobby)
        {
            UIArtTheme.DrawScreenBackdrop();
            DrawLobbyFallback();
            return;
        }

        UIArtTheme.DrawScreenBackdrop();

        float boxWidth = 420;
        float boxHeight = 500;
        float x = (Screen.width - boxWidth) / 2;
        float y = (Screen.height - boxHeight) / 2;

        UIArtTheme.DrawGlassPanel(new Rect(x, y, boxWidth, boxHeight));

        float innerX = x + 30;
        float innerW = boxWidth - 60;
        float curY = y + 20;

        // 标题
        GUI.Label(new Rect(x, curY, boxWidth, 50), "球球大作战", _titleStyle);
        curY += 55;

        // 服务器地址
        GUI.Label(new Rect(innerX, curY, 80, 30), "服务器IP:", _labelStyle);
        _serverIP = GUI.TextField(new Rect(innerX + 85, curY, innerW - 170, 35), _serverIP, _inputStyle);
        GUI.Label(new Rect(innerX + innerW - 80, curY, 15, 30), ":", _labelStyle);
        _serverPort = GUI.TextField(new Rect(innerX + innerW - 65, curY, 65, 35), _serverPort, _inputStyle);
        curY += 45;

        // 玩家ID
        GUI.Label(new Rect(innerX, curY, 80, 30), "玩家ID:", _labelStyle);
        _playerid = GUI.TextField(new Rect(innerX + 85, curY, innerW - 85, 35), _playerid, _inputStyle);
        curY += 45;

        // 密码
        GUI.Label(new Rect(innerX, curY, 80, 30), "密  码:", _labelStyle);
        _password = GUI.PasswordField(new Rect(innerX + 85, curY, innerW - 85, 35), _password, '*', _inputStyle);
        curY += 50;

        // 连接按钮
        if (!_isConnected)
        {
            if (GUI.Button(new Rect(innerX, curY, innerW, 40), "连接服务器", _buttonStyle))
            {
                int port;
                if (int.TryParse(_serverPort, out port))
                {
                    _statusMsg = "正在连接...";
                    NetworkManager.Instance.Connect(_serverIP, port);
                }
                else
                {
                    _statusMsg = "端口格式错误";
                }
            }
        }
        else if (!_isLoggedIn)
        {
            // 登录 / 注册按钮
            float halfW = (innerW - 10) / 2;
            if (GUI.Button(new Rect(innerX, curY, halfW, 40), "登 录", _buttonStyle))
            {
                DoLogin();
            }
            if (GUI.Button(new Rect(innerX + halfW + 10, curY, halfW, 40), "注 册", _buttonStyle))
            {
                DoRegister();
            }
        }
        curY += 50;

        // 状态消息
        _statusStyle.normal.textColor = _statusMsg.Contains("失败") || _statusMsg.Contains("错误")
            ? new Color(1f, 0.52f, 0.52f) : new Color(1f, 0.93f, 0.62f);
        GUI.Label(new Rect(x, curY, boxWidth, 30), _statusMsg, _statusStyle);
        curY += 35;

        // 断开按钮
        if (_isConnected)
        {
            if (GUI.Button(new Rect(innerX, curY, innerW, 30), "断开连接", _buttonStyle))
            {
                _statusMsg = "已断开";
                ClientSession.Instance?.EndSession();
                _isLoggedIn = false;
                _isConnected = false;
                _isInScene = false;
                _showLobby = false;
                if (LobbyUI.Instance != null)
                    LobbyUI.Instance.Hide();
                NetworkManager.Instance.Disconnect(true);
            }
        }
        curY += 40;

        // 日志区域
        GUI.Label(new Rect(innerX, curY, innerW, 20), "通信日志:", _labelStyle);
        curY += 22;
        float logHeight = boxHeight - (curY - y) - 10;
        Rect logRect = new Rect(innerX, curY, innerW, logHeight);
        UIArtTheme.DrawInset(logRect);
        _logScroll = GUI.BeginScrollView(logRect, _logScroll,
            new Rect(0, 0, innerW - 20, Mathf.Max(logHeight, _logText.Split('\n').Length * 16)));
        GUI.Label(new Rect(0, 0, innerW - 20, _logText.Split('\n').Length * 16), _logText, _logStyle);
        GUI.EndScrollView();
    }

    private void DoLogin()
    {
        if (!ValidatePlayerIdInput())
            return;
        if (_isLoggingIn)
        {
            _statusMsg = "登录流程进行中，请稍候";
            AddLog("!! 登录流程进行中，请勿重复点击");
            return;
        }
        if (!EnsureSrpInitialized())
            return;

        _pendingLoginPlayerId = _playerid;
        _pendingLoginPassword = _password;

        try
        {
            _pendingSrpClient = new SrpClient();
            var clientEphemeral = _pendingSrpClient.GenerateEphemeral();
            _pendingASecretHex = clientEphemeral.Secret;
            _pendingAPublicHex = clientEphemeral.Public;
            _pendingABytes = HexToBytes(_pendingAPublicHex);

            if (string.IsNullOrEmpty(_pendingASecretHex) || string.IsNullOrEmpty(_pendingAPublicHex) || _pendingABytes == null || _pendingABytes.Length == 0)
            {
                _statusMsg = "登录失败: 客户端生成 A 失败";
                AddLog("!! 生成 A 失败");
                ResetLoginFlow();
                return;
            }
        }
        catch (Exception e)
        {
            _statusMsg = "登录失败: 生成 SRP 参数异常";
            AddLog($"!! 生成 SRP 参数异常: {e.Message}");
            ResetLoginFlow();
            return;
        }

        _isLoggingIn = true;
        _statusMsg = "正在登录(1/2)...";
        AddLog($">> 发送 login_first: playerid={_pendingLoginPlayerId}");
        var req = new LoginFirstReq
        {
            Playerid = _pendingLoginPlayerId,
            A = ByteString.CopyFrom(_pendingABytes),
        };
        NetworkManager.Instance.Send("login_first", req);
    }

    private void DoRegister()
    {
        if (!ValidatePlayerIdInput())
            return;
        if (!EnsureSrpInitialized())
            return;

        try
        {
            var client = new SrpClient();
            string saltHex = client.GenerateSalt();
            string privateKey = client.DerivePrivateKey(saltHex, _playerid, _password);
            string verifierHex = client.DeriveVerifier(privateKey);

            byte[] salt = HexToBytes(saltHex);
            byte[] verifier = HexToBytes(verifierHex);

            var req = new RegisterReq
            {
                Playerid = _playerid,
                Salt = ByteString.CopyFrom(salt),
                Verifier = ByteString.CopyFrom(verifier),
            };

            _statusMsg = "正在注册...";
            AddLog($">> 发送注册: playerid={_playerid}");
            NetworkManager.Instance.Send("register", req);
        }
        catch (Exception e)
        {
            _statusMsg = "注册失败: SRP 参数生成异常";
            AddLog($"!! 注册生成 SRP 参数异常: {e.Message}");
        }
    }

    private bool ValidatePlayerIdInput()
    {
        if (!int.TryParse(_playerid, out int pid) || pid <= 0)
        {
            _statusMsg = "玩家ID必须是正整数";
            AddLog("!! 玩家ID格式错误，必须是正整数");
            return false;
        }
        return true;
    }

    private void DrawLobbyFallback()
    {
        float boxWidth = 420;
        float boxHeight = 220;
        float x = (Screen.width - boxWidth) / 2;
        float y = (Screen.height - boxHeight) / 2;

        UIArtTheme.DrawGlassPanel(new Rect(x, y, boxWidth, boxHeight));
        GUI.Label(new Rect(x, y + 15, boxWidth, 35), "已登录", _titleStyle);

        _statusStyle.normal.textColor = _statusMsg.Contains("失败") || _statusMsg.Contains("错误")
            ? new Color(1f, 0.52f, 0.52f) : new Color(1f, 0.93f, 0.62f);
        GUI.Label(new Rect(x, y + 55, boxWidth, 25), _statusMsg, _statusStyle);

        if (GUI.Button(new Rect(x + 30, y + 90, boxWidth - 60, 40), "开始匹配", _buttonStyle))
        {
            EnterBattle();
        }

        if (GUI.Button(new Rect(x + 30, y + 140, boxWidth - 60, 35), "打开大厅", _buttonStyle))
        {
            if (LobbyUI.Instance != null)
            {
                LobbyUI.Instance.Show();
            }
            else
            {
                _statusMsg = "大厅UI未初始化";
            }
        }
    }

    private void EnterBattle()
    {
        if (NetworkManager.Instance == null || !NetworkManager.Instance.IsConnected)
        {
            _statusMsg = "网络未连接";
            return;
        }

        _statusMsg = "正在开始匹配...";
        AddLog(">> 请求开始匹配");
        if (LobbyUI.Instance != null)
        {
            LobbyUI.Instance.RequestJoinMatch();
        }
        else
        {
            NetworkManager.Instance.Send("join_match", new JoinMatchReq { ModeId = 1 });
        }
    }



    // --- 回调 ---

    private void OnConnectionChanged(bool connected)
    {
        _isConnected = connected;
        if (connected)
        {
            if (ClientSession.Instance != null && ClientSession.Instance.IsReconnecting)
            {
                _statusMsg = "连接已恢复，正在恢复会话...";
                AddLog("<< 连接成功，正在恢复会话");
                return;
            }

            _statusMsg = "连接成功！请登录";
            AddLog("<< 连接成功");
        }
        else
        {
            if (ClientSession.Instance != null && ClientSession.Instance.ShouldPreserveStateOnDisconnect())
            {
                _statusMsg = "连接断开，正在尝试重连...";
                AddLog("<< 连接断开，正在尝试重连");
                return;
            }

            ResetLoginFlow();
            _isLoggedIn = false;
            _isInScene = false;
            _showLobby = false;
            if (LobbyUI.Instance != null)
                LobbyUI.Instance.Hide();
            if (_statusMsg != "已断开" && !_statusMsg.Contains("失败"))
                _statusMsg = "连接断开";
            AddLog("<< 连接断开");
        }
    }

    private void OnLoginFirstRes(LoginFirstRes res)
    {
        AddLog($"<< login_first 响应: code={res.Code}, msg={res.Msg}");

        if (!_isLoggingIn || _pendingSrpClient == null || _pendingABytes == null || string.IsNullOrEmpty(_pendingASecretHex) || string.IsNullOrEmpty(_pendingAPublicHex))
        {
            AddLog("!! 收到过期 login_first 响应，已忽略");
            return;
        }

        if (res.Code != 0)
        {
            _statusMsg = $"登录失败: {res.Msg}";
            ResetLoginFlow();
            return;
        }

        byte[] salt = res.Salt.ToByteArray();
        byte[] b = res.B.ToByteArray();
        if (salt == null || salt.Length == 0 || b == null || b.Length == 0)
        {
            _statusMsg = "登录失败: 服务端 salt/B 为空";
            AddLog("!! 服务端返回的 salt/B 为空");
            ResetLoginFlow();
            return;
        }

        try
        {
            string saltHex = BytesToHex(salt);
            string bHex = BytesToHex(b);
            string privateKey = _pendingSrpClient.DerivePrivateKey(saltHex, _pendingLoginPlayerId, _pendingLoginPassword);
            _pendingSrpSession = _pendingSrpClient.DeriveSession(
                _pendingASecretHex,
                bHex,
                saltHex,
                _pendingLoginPlayerId,
                privateKey
            );

            if (_pendingSrpSession == null || string.IsNullOrEmpty(_pendingSrpSession.Key))
            {
                _statusMsg = "登录失败: 客户端 M1 生成失败";
                AddLog("!! 生成 M1 失败");
                ResetLoginFlow();
                return;
            }

            _pendingSessionKeyBytes = HexToBytes(_pendingSrpSession.Key);
            _pendingM1Bytes = ComputeServerCompatibleM1(
                _pendingLoginPlayerId,
                salt,
                _pendingABytes,
                b,
                _pendingSessionKeyBytes
            );
            if (_pendingM1Bytes == null || _pendingM1Bytes.Length == 0)
            {
                _statusMsg = "登录失败: 客户端 M1 生成失败";
                AddLog("!! 生成 M1 失败");
                ResetLoginFlow();
                return;
            }
        }
        catch (Exception e)
        {
            _statusMsg = "登录失败: 计算 SRP 挑战响应异常";
            AddLog($"!! SRP 挑战响应异常: {e.Message}");
            ResetLoginFlow();
            return;
        }

        _statusMsg = "正在登录(2/2)...";
        AddLog($">> 发送 login_second: playerid={_pendingLoginPlayerId}");
        var req = new LoginSecondReq
        {
            Playerid = _pendingLoginPlayerId,
            M1 = ByteString.CopyFrom(_pendingM1Bytes),
        };
        NetworkManager.Instance.Send("login_second", req);
    }

    private void OnLoginSecondRes(LoginSecondRes res)
    {
        AddLog($"<< login_second 响应: code={res.Code}, msg={res.Msg}");

        if (!_isLoggingIn || _pendingABytes == null || _pendingM1Bytes == null || _pendingSessionKeyBytes == null)
        {
            AddLog("!! 收到过期 login_second 响应，已忽略");
            return;
        }

        if (res.Code != 0)
        {
            _statusMsg = $"登录失败: {res.Msg}";
            ResetLoginFlow();
            return;
        }

        byte[] m2 = res.M2.ToByteArray();
        if (m2 == null || m2.Length == 0)
        {
            _statusMsg = "登录失败: M2 校验失败";
            AddLog("!! M2 校验失败，服务端身份验证未通过");
            ResetLoginFlow();
            return;
        }

        try
        {
            byte[] expectedM2 = ComputeServerCompatibleM2(_pendingABytes, _pendingM1Bytes, _pendingSessionKeyBytes);
            if (!ByteArrayEqual(expectedM2, m2))
            {
                _statusMsg = "登录失败: M2 校验失败";
                AddLog("!! M2 校验失败，服务端身份验证未通过");
                ResetLoginFlow();
                return;
            }
        }
        catch (Exception e)
        {
            _statusMsg = "登录失败: 校验 M2 异常";
            AddLog($"!! 校验 M2 异常: {e.Message}");
            ResetLoginFlow();
            return;
        }

        OnLoginSuccess(_pendingLoginPlayerId, res.Token);
        ResetLoginFlow();
    }

    private void OnLoginSuccess(string loginPlayerId, string token)
    {
        _isLoggedIn = true;
        _isInScene = false;
        _showLobby = true;
        _statusMsg = "登录成功！正在进入大厅...";

        if (string.IsNullOrEmpty(token))
        {
            AddLog("!! 服务端没有返回重连 token，自动重连将不可用");
        }

        if (int.TryParse(loginPlayerId, out int myId))
        {
            if (GameManager.Instance != null)
                GameManager.Instance.SetMyPlayerId(myId);
            if (ClientSession.Instance != null)
                ClientSession.Instance.BeginAuthenticatedSession(myId, token);
        }
        else
        {
            AddLog($"!! playerid 不是数字: {loginPlayerId}");
        }

        if (LobbyUI.Instance != null)
        {
            LobbyUI.Instance.Show();
        }
        else
        {
            AddLog("!! LobbyUI 未初始化，启用兜底面板");
        }
    }

    private void OnReconnectNotice(string notice)
    {
        _statusMsg = notice;
        AddLog($"<< {notice}");
    }

    public void OnEnteredSceneFromLobby()
    {
        _isInScene = true;
        _showLobby = false;
        _statusMsg = "";
    }

    public void OnReturnedToLobbyFromBattle()
    {
        _isInScene = false;
        _showLobby = true;
    }

    private void OnRegisterRes(RegisterRes res)
    {
        AddLog($"<< 注册响应: code={res.Code}, msg={res.Msg}");
        if (res.Code == 0)
        {
            _statusMsg = "注册成功！请登录";
        }
        else
        {
            _statusMsg = $"注册失败: {res.Msg}";
        }
    }

    private void AddLog(string msg)
    {
        _logText += msg + "\n";
        // 限制日志行数
        string[] lines = _logText.Split('\n');
        if (lines.Length > _maxLogLines)
        {
            _logText = string.Join("\n", lines, lines.Length - _maxLogLines, _maxLogLines);
        }
        _logScroll.y = float.MaxValue; // 自动滚动到底部
    }

    private bool EnsureSrpInitialized()
    {
        if (_srpInitOk)
            return true;
        if (!_srpInitTried)
        {
            _srpInitTried = true;
            try
            {
                var client = new SrpClient();
                var ephemeral = client.GenerateEphemeral();
                if (ephemeral == null || string.IsNullOrEmpty(ephemeral.Secret) || string.IsNullOrEmpty(ephemeral.Public))
                    throw new Exception("srp.net 初始化后无法生成临时密钥");

                _srpInitOk = true;
                AddLog("<< SRP 参数组已初始化: srp.net 默认 SHA256 + 2048");
            }
            catch (Exception e)
            {
                _srpInitErr = e.Message;
                _srpInitOk = false;
            }
        }

        if (!_srpInitOk)
        {
            if (string.IsNullOrEmpty(_srpInitErr))
                _srpInitErr = "unknown error";
            _statusMsg = $"SRP 初始化失败: {_srpInitErr}";
            AddLog($"!! SRP 初始化失败: {_srpInitErr}");
            return false;
        }

        return true;
    }

    private void ResetLoginFlow()
    {
        _isLoggingIn = false;
        _pendingLoginPlayerId = "";
        _pendingLoginPassword = "";
        _pendingSrpClient = null;
        _pendingASecretHex = "";
        _pendingAPublicHex = "";
        _pendingSrpSession = null;
        _pendingABytes = null;
        _pendingM1Bytes = null;
        _pendingSessionKeyBytes = null;
    }

    private static byte[] HexToBytes(string hex)
    {
        if (string.IsNullOrEmpty(hex))
            return new byte[0];
        if ((hex.Length & 1) != 0)
            throw new ArgumentException("hex length must be even");

        byte[] bytes = new byte[hex.Length / 2];
        for (int i = 0; i < bytes.Length; i++)
        {
            int hi = HexToNibble(hex[i * 2]);
            int lo = HexToNibble(hex[i * 2 + 1]);
            if (hi < 0 || lo < 0)
                throw new ArgumentException("invalid hex string");
            bytes[i] = (byte)((hi << 4) | lo);
        }
        return bytes;
    }

    private static int HexToNibble(char c)
    {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    private static string BytesToHex(byte[] bytes)
    {
        if (bytes == null || bytes.Length == 0)
            return "";

        char[] chars = new char[bytes.Length * 2];
        const string hex = "0123456789abcdef";
        for (int i = 0; i < bytes.Length; i++)
        {
            chars[i * 2] = hex[bytes[i] >> 4];
            chars[i * 2 + 1] = hex[bytes[i] & 0x0F];
        }
        return new string(chars);
    }

    // 对齐服务端 csrp 的 M1:
    // M1 = H( H(N) xor H(PAD(g)), H(I), s_bn, A_bn, B_bn, K )
    private static byte[] ComputeServerCompatibleM1(string playerId, byte[] salt, byte[] a, byte[] b, byte[] sessionKey)
    {
        byte[] nBytes = TrimLeadingZeros(HexToBytes(SrpN2048Hex));
        byte[] gBytes = TrimLeadingZeros(HexToBytes(SrpGHex));
        byte[] gPadded = LeftPad(gBytes, nBytes.Length);

        byte[] hN = Sha256(nBytes);
        byte[] hG = Sha256(gPadded);
        byte[] hI = Sha256(Encoding.UTF8.GetBytes(playerId ?? ""));
        byte[] hXor = Xor(hN, hG);

        return Sha256(
            hXor,
            hI,
            TrimLeadingZeros(salt),
            TrimLeadingZeros(a),
            TrimLeadingZeros(b),
            sessionKey ?? new byte[0]
        );
    }

    // 对齐服务端 csrp 的 M2:
    // M2 = H(A_bn, M1, K)
    private static byte[] ComputeServerCompatibleM2(byte[] a, byte[] m1, byte[] sessionKey)
    {
        return Sha256(
            TrimLeadingZeros(a),
            m1 ?? new byte[0],
            sessionKey ?? new byte[0]
        );
    }

    private static byte[] Sha256(params byte[][] parts)
    {
        using (var sha = SHA256.Create())
        {
            int total = 0;
            for (int i = 0; i < parts.Length; i++)
            {
                if (parts[i] != null) total += parts[i].Length;
            }

            byte[] data = new byte[total];
            int offset = 0;
            for (int i = 0; i < parts.Length; i++)
            {
                byte[] p = parts[i];
                if (p == null || p.Length == 0) continue;
                Buffer.BlockCopy(p, 0, data, offset, p.Length);
                offset += p.Length;
            }
            return sha.ComputeHash(data);
        }
    }

    private static byte[] LeftPad(byte[] src, int length)
    {
        if (src == null || src.Length >= length)
            return src ?? new byte[0];

        byte[] dst = new byte[length];
        Buffer.BlockCopy(src, 0, dst, length - src.Length, src.Length);
        return dst;
    }

    private static byte[] TrimLeadingZeros(byte[] src)
    {
        if (src == null || src.Length == 0)
            return new byte[0];

        int i = 0;
        while (i < src.Length && src[i] == 0) i++;
        if (i == 0) return src;
        if (i >= src.Length) return new byte[0];

        byte[] dst = new byte[src.Length - i];
        Buffer.BlockCopy(src, i, dst, 0, dst.Length);
        return dst;
    }

    private static byte[] Xor(byte[] a, byte[] b)
    {
        if (a == null || b == null || a.Length != b.Length)
            throw new ArgumentException("xor input length mismatch");

        byte[] outBytes = new byte[a.Length];
        for (int i = 0; i < a.Length; i++)
        {
            outBytes[i] = (byte)(a[i] ^ b[i]);
        }
        return outBytes;
    }

    private static bool ByteArrayEqual(byte[] a, byte[] b)
    {
        if (ReferenceEquals(a, b)) return true;
        if (a == null || b == null) return false;
        if (a.Length != b.Length) return false;
        for (int i = 0; i < a.Length; i++)
        {
            if (a[i] != b[i]) return false;
        }
        return true;
    }
}
