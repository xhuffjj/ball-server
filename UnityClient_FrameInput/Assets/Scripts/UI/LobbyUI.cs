using System;
using System.Collections.Generic;
using UnityEngine;
using Game;

/// <summary>
/// 大厅界面 - 登录后显示，负责普通功能 Tab 和匹配/准备入口。
/// </summary>
public class LobbyUI : MonoBehaviour
{
    public static LobbyUI Instance { get; private set; }
    public bool IsVisible => _visible;

    private const int DefaultModeId = 1;

    private bool _visible = false;
    private int _currentTab = 0;
    private readonly string[] _tabNames = { "好友", "邮件", "成就", "背包" };

    // UI 样式
    private GUIStyle _titleStyle;
    private GUIStyle _tabStyle;
    private GUIStyle _tabActiveStyle;
    private GUIStyle _buttonStyle;
    private GUIStyle _quickEnterStyle;
    private GUIStyle _boxStyle;
    private GUIStyle _statusStyle;
    private GUIStyle _profileStyle;
    private GUIStyle _profileSubStyle;
    private GUIStyle _popupTitleStyle;
    private GUIStyle _popupBodyStyle;
    private bool _stylesInitialized = false;

    private string _statusMsg = "";
    private float _statusTimer = 0f;
    private BaseInfoRes _baseInfo;

    private bool _matching = false;
    private bool _matchFound = false;
    private bool _prepareSent = false;
    private bool _waitingBattleConnect = false;
    private readonly List<int> _matchedPlayerIds = new List<int>();
    private readonly Dictionary<int, bool> _prepareStates = new Dictionary<int, bool>();
    private bool _showMatchPopup = false;
    private bool _showBattleResultPopup = false;
    private BattleResultNotify _lastBattleResult;

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }
        Instance = this;
    }

    void Start()
    {
        var proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            Debug.LogError("[LobbyUI] ProtocolHandler 未初始化，回调注册失败");
            return;
        }

        proto.On<WorkRes>("work", OnWorkRes);
        proto.On<JoinMatchRes>("join_match", OnJoinMatchRes);
        proto.On<CancelMatchRes>("cancel_match", OnCancelMatchRes);
        proto.On<MatchFoundNotify>("match_found", OnMatchFound);
        proto.On<PrepareRes>("prepare", OnPrepareRes);
        proto.On<RoomPrepareNotify>("room_prepare", OnRoomPrepare);
        proto.On<BattleConnectNotify>("battle_connect", OnBattleConnect);
        proto.On<RoomDismissNotify>("room_dismiss", OnRoomDismiss);
        proto.On<BattleResultNotify>("battle_result", OnBattleResult);

        if (ClientSession.Instance != null)
        {
            ClientSession.Instance.OnBaseInfoUpdated += OnBaseInfoUpdated;
            ClientSession.Instance.OnReconnectNotice += OnReconnectNotice;
            _baseInfo = ClientSession.Instance.CurrentBaseInfo;
        }
    }

    void OnDestroy()
    {
        if (ClientSession.Instance != null)
        {
            ClientSession.Instance.OnBaseInfoUpdated -= OnBaseInfoUpdated;
            ClientSession.Instance.OnReconnectNotice -= OnReconnectNotice;
        }
    }

    void Update()
    {
        if (_statusTimer > 0)
        {
            _statusTimer -= Time.deltaTime;
            if (_statusTimer <= 0) _statusMsg = "";
        }

        if (_visible && Input.GetKeyDown(KeyCode.Return))
        {
            DoPrimaryMatchAction();
        }
    }

    private void InitStyles()
    {
        UIArtTheme.EnsureInit();

        _titleStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 28,
            fontStyle = FontStyle.Bold,
            alignment = TextAnchor.MiddleCenter
        };
        _titleStyle.normal.textColor = new Color(0.76f, 0.94f, 1f);

        _tabStyle = new GUIStyle(GUI.skin.button)
        {
            fontSize = 18,
            fixedHeight = 40
        };
        UIArtTheme.SkinTab(_tabStyle, false);

        _tabActiveStyle = new GUIStyle(_tabStyle);
        UIArtTheme.SkinTab(_tabActiveStyle, true);
        _tabActiveStyle.fontStyle = FontStyle.Bold;

        _buttonStyle = new GUIStyle(GUI.skin.button)
        {
            fontSize = 20,
            fixedHeight = 45
        };
        UIArtTheme.SkinButton(_buttonStyle);

        _quickEnterStyle = new GUIStyle(GUI.skin.button)
        {
            fontSize = 14,
            fixedHeight = 34
        };
        UIArtTheme.SkinButton(_quickEnterStyle);

        _boxStyle = new GUIStyle(GUI.skin.box)
        {
            padding = new RectOffset(15, 15, 15, 15)
        };
        _boxStyle.normal.background = UIArtTheme.PanelTex;

        _statusStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 14,
            alignment = TextAnchor.MiddleCenter
        };
        _statusStyle.normal.textColor = new Color(1f, 0.93f, 0.62f);

        _profileStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 15,
            fontStyle = FontStyle.Bold
        };
        _profileStyle.normal.textColor = new Color(0.84f, 0.95f, 1f);

        _profileSubStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 12
        };
        _profileSubStyle.normal.textColor = new Color(0.70f, 0.84f, 0.96f);

        _popupTitleStyle = new GUIStyle(_titleStyle)
        {
            fontSize = 24
        };

        _popupBodyStyle = new GUIStyle(GUI.skin.label)
        {
            fontSize = 16,
            wordWrap = true,
            alignment = TextAnchor.MiddleLeft
        };
        _popupBodyStyle.normal.textColor = new Color(0.86f, 0.95f, 1f);

        _stylesInitialized = true;
    }

    void OnGUI()
    {
        if (!_visible && !_showBattleResultPopup) return;
        if (!_stylesInitialized) InitStyles();

        if (_visible)
        {
            UIArtTheme.DrawScreenBackdrop();

            float boxWidth = Mathf.Min(700f, Screen.width - 20f);
            float boxHeight = Mathf.Min(640f, Screen.height - 20f);
            float x = (Screen.width - boxWidth) / 2;
            float y = (Screen.height - boxHeight) / 2;

            UIArtTheme.DrawGlassPanel(new Rect(x, y, boxWidth, boxHeight));

            float innerX = x + 15;
            float innerW = boxWidth - 30;
            float curY = y + 10;

            GUI.Label(new Rect(x, curY, boxWidth, 40), "球球大作战 - 大厅", _titleStyle);
            float quickBtnW = 100f;
            float quickGap = 8f;
            float actionX = innerX + innerW - quickBtnW;
            float workX = actionX - quickGap - quickBtnW;
            if (GUI.Button(new Rect(workX, curY + 3, quickBtnW, 34), "Work", _quickEnterStyle))
            {
                DoWork();
            }

            bool oldEnabled = GUI.enabled;
            GUI.enabled = CanUsePrimaryMatchAction();
            if (GUI.Button(new Rect(actionX, curY + 3, quickBtnW, 34), GetPrimaryActionText(), _quickEnterStyle))
            {
                DoPrimaryMatchAction();
            }
            GUI.enabled = oldEnabled;
            curY += 45;

            DrawProfileStrip(innerX, curY, innerW);
            curY += 56;

            DrawMatchStrip(innerX, curY, innerW);
            curY += 86;

            float tabW = (innerW - (_tabNames.Length - 1) * 5) / _tabNames.Length;
            for (int i = 0; i < _tabNames.Length; i++)
            {
                GUIStyle style = (i == _currentTab) ? _tabActiveStyle : _tabStyle;
                if (GUI.Button(new Rect(innerX + i * (tabW + 5), curY, tabW, 40), _tabNames[i], style))
                {
                    _currentTab = i;
                    OnTabChanged(i);
                }
            }
            curY += 50;

            Rect panelRect = new Rect(innerX, curY, innerW, Mathf.Max(60f, boxHeight - (curY - y) - 78));
            UIArtTheme.DrawInset(panelRect);

            switch (_currentTab)
            {
                case 0:
                    if (FriendPanel.Instance != null) FriendPanel.Instance.DrawPanel(panelRect);
                    break;
                case 1:
                    if (MailPanel.Instance != null) MailPanel.Instance.DrawPanel(panelRect);
                    break;
                case 2:
                    if (AchievePanel.Instance != null) AchievePanel.Instance.DrawPanel(panelRect);
                    break;
                case 3:
                    if (BagPanel.Instance != null) BagPanel.Instance.DrawPanel(panelRect);
                    break;
            }

            float bottomY = y + boxHeight - 55;
            if (!string.IsNullOrEmpty(_statusMsg))
            {
                GUI.Label(new Rect(innerX, bottomY - 22, innerW, 20), _statusMsg, _statusStyle);
            }

            DrawBottomMatchButtons(innerX, bottomY, innerW);
        }

        if (_showMatchPopup)
        {
            DrawMatchFoundPopup();
        }

        if (_showBattleResultPopup)
        {
            DrawBattleResultPopup();
        }
    }

    private void DrawMatchStrip(float x, float y, float width)
    {
        UIArtTheme.DrawRow(new Rect(x, y, width, 76), true);

        GUI.Label(new Rect(x + 10, y + 7, width - 20, 20), $"匹配模式: {DefaultModeId}    状态: {GetMatchStateText()}", _profileStyle);
        GUI.Label(new Rect(x + 10, y + 30, width - 20, 18), BuildPlayerLine(), _profileSubStyle);
        GUI.Label(new Rect(x + 10, y + 50, width - 20, 18), BuildPrepareLine(), _profileSubStyle);
    }

    private void DrawBottomMatchButtons(float x, float y, float width)
    {
        bool canCancel = CanCancelMatch();
        bool oldEnabled = GUI.enabled;

        if (canCancel)
        {
            float half = (width - 8f) * 0.5f;
            if (GUI.Button(new Rect(x, y, half, 45), "取消匹配", _buttonStyle))
            {
                DoCancelMatch();
            }

            GUI.enabled = CanUsePrimaryMatchAction();
            if (GUI.Button(new Rect(x + half + 8f, y, half, 45), GetPrimaryActionText(), _buttonStyle))
            {
                DoPrimaryMatchAction();
            }
            GUI.enabled = oldEnabled;
            return;
        }

        GUI.enabled = CanUsePrimaryMatchAction();
        if (GUI.Button(new Rect(x, y, width, 45), GetPrimaryActionText(), _buttonStyle))
        {
            DoPrimaryMatchAction();
        }
        GUI.enabled = oldEnabled;
    }

    private void DrawModalBackdrop()
    {
        Color oldColor = GUI.color;
        GUI.color = new Color(0f, 0f, 0f, 0.56f);
        GUI.DrawTexture(new Rect(0, 0, Screen.width, Screen.height), Texture2D.whiteTexture);
        GUI.color = oldColor;
    }

    private void DrawMatchFoundPopup()
    {
        DrawModalBackdrop();

        float width = Mathf.Min(500f, Screen.width - 40f);
        float height = Mathf.Min(370f, 170f + _matchedPlayerIds.Count * 30f);
        float x = (Screen.width - width) * 0.5f;
        float y = (Screen.height - height) * 0.5f;
        Rect rect = new Rect(x, y, width, height);

        UIArtTheme.DrawGlassPanel(rect);

        float innerX = x + 24f;
        float innerW = width - 48f;
        float curY = y + 18f;

        GUI.Label(new Rect(innerX, curY, innerW, 34f), "匹配成功", _popupTitleStyle);
        curY += 42f;

        GUI.Label(new Rect(innerX, curY, innerW, 24f), $"模式 {DefaultModeId}，请确认房间玩家并准备", _popupBodyStyle);
        curY += 34f;

        Rect listRect = new Rect(innerX, curY, innerW, Mathf.Max(70f, height - 178f));
        UIArtTheme.DrawInset(listRect);

        float rowY = listRect.y + 8f;
        int myId = ClientSession.Instance != null ? ClientSession.Instance.PlayerId : 0;
        foreach (int playerId in _matchedPlayerIds)
        {
            bool prepared = _prepareStates.TryGetValue(playerId, out bool value) && value;
            string selfMark = playerId == myId ? "  我" : "";
            string line = $"玩家 {playerId}{selfMark}    {(prepared ? "已准备" : "未准备")}";
            GUI.Label(new Rect(listRect.x + 12f, rowY, listRect.width - 24f, 24f), line, _popupBodyStyle);
            rowY += 28f;
        }

        curY = listRect.yMax + 14f;
        bool oldEnabled = GUI.enabled;
        float halfW = (innerW - 10f) * 0.5f;

        GUI.enabled = !_prepareSent && !_waitingBattleConnect;
        if (GUI.Button(new Rect(innerX, curY, halfW, 42f), _prepareSent ? "已准备" : "准备", _buttonStyle))
        {
            DoPrepare();
        }

        GUI.enabled = true;
        if (GUI.Button(new Rect(innerX + halfW + 10f, curY, halfW, 42f), "关闭", _buttonStyle))
        {
            _showMatchPopup = false;
        }
        GUI.enabled = oldEnabled;
    }

    private void DrawBattleResultPopup()
    {
        if (_lastBattleResult == null)
        {
            _showBattleResultPopup = false;
            return;
        }

        DrawModalBackdrop();

        float width = Mathf.Min(520f, Screen.width - 40f);
        float height = 330f;
        float x = (Screen.width - width) * 0.5f;
        float y = (Screen.height - height) * 0.5f;
        Rect rect = new Rect(x, y, width, height);

        UIArtTheme.DrawGlassPanel(rect);

        float innerX = x + 28f;
        float innerW = width - 56f;
        float curY = y + 20f;

        GUI.Label(new Rect(innerX, curY, innerW, 36f), "对局结算", _popupTitleStyle);
        curY += 50f;

        DrawResultRow(innerX, curY, innerW, "排名", $"第 {_lastBattleResult.Rank} 名");
        curY += 34f;
        DrawResultRow(innerX, curY, innerW, "体重", _lastBattleResult.WeightScore.ToString());
        curY += 34f;
        DrawResultRow(innerX, curY, innerW, "段位分", FormatSigned(_lastBattleResult.ScoreDelta));
        curY += 34f;
        DrawResultRow(innerX, curY, innerW, "金币", "+" + _lastBattleResult.Coin);
        curY += 34f;
        DrawResultRow(innerX, curY, innerW, "经验", "+" + _lastBattleResult.Exp);
        curY += 54f;

        if (GUI.Button(new Rect(innerX, curY, innerW, 46f), "返回大厅", _buttonStyle))
        {
            ReturnToLobbyAfterBattleResult();
        }
    }

    private void DrawResultRow(float x, float y, float width, string name, string value)
    {
        UIArtTheme.DrawRow(new Rect(x, y, width, 28f), false);
        GUI.Label(new Rect(x + 12f, y + 3f, width * 0.45f, 22f), name, _popupBodyStyle);
        GUI.Label(new Rect(x + width * 0.45f, y + 3f, width * 0.50f, 22f), value, _popupBodyStyle);
    }

    private void OnTabChanged(int tab)
    {
        switch (tab)
        {
            case 0:
                if (FriendPanel.Instance != null) FriendPanel.Instance.RequestData();
                break;
            case 1:
                if (MailPanel.Instance != null) MailPanel.Instance.RequestData();
                break;
            case 2:
                if (AchievePanel.Instance != null) AchievePanel.Instance.RequestData();
                break;
            case 3:
                if (BagPanel.Instance != null) BagPanel.Instance.RequestData();
                break;
        }
    }

    public void RequestJoinMatch()
    {
        Show();
        DoJoinMatch();
    }

    private void DoPrimaryMatchAction()
    {
        if (_matchFound)
        {
            if (!_prepareSent && !_waitingBattleConnect)
            {
                DoPrepare();
                return;
            }

            ShowStatus("已准备，等待其他玩家或战斗连接", 2f);
            return;
        }

        if (_matching)
        {
            ShowStatus("正在匹配中", 2f);
            return;
        }

        if (_waitingBattleConnect)
        {
            ShowStatus("正在等待战斗连接", 2f);
            return;
        }

        DoJoinMatch();
    }

    private void DoJoinMatch()
    {
        if (!EnsureConnected())
        {
            return;
        }

        ResetMatchState(false);
        _matching = true;
        ShowStatus("正在匹配...", 5f);
        NetworkManager.Instance.Send("join_match", new JoinMatchReq
        {
            ModeId = DefaultModeId
        });
    }

    private void DoCancelMatch()
    {
        if (!EnsureConnected())
        {
            return;
        }

        ShowStatus("正在取消匹配...", 3f);
        NetworkManager.Instance.Send("cancel_match", new CancelMatchReq());
    }

    private void DoPrepare()
    {
        if (!EnsureConnected())
        {
            return;
        }

        ShowStatus("正在准备...", 3f);
        NetworkManager.Instance.Send("prepare", new PrepareReq());
    }

    private void DoWork()
    {
        if (!EnsureConnected())
        {
            return;
        }

        ShowStatus("发送 work...", 2f);
        NetworkManager.Instance.Send("work", new WorkReq());
    }

    public void Show()
    {
        _visible = true;
        _currentTab = 0;
        _baseInfo = ClientSession.Instance != null ? ClientSession.Instance.CurrentBaseInfo : null;
        ClientSession.Instance?.RequestBaseInfo();
        OnTabChanged(0);
    }

    public void Hide()
    {
        _visible = false;
    }

    public void ShowStatus(string msg, float duration = 3f)
    {
        _statusMsg = msg;
        _statusTimer = duration;
    }

    private void OnWorkRes(WorkRes res)
    {
        ShowStatus($"work 成功，当前金币: {res.Coin}", 3f);
        ClientSession.Instance?.RequestBaseInfo();
    }

    private void OnJoinMatchRes(JoinMatchRes res)
    {
        if (res.Code == 0)
        {
            _matching = true;
            ShowStatus(string.IsNullOrEmpty(res.Msg) ? "匹配中..." : res.Msg, 4f);
            return;
        }

        _matching = false;
        ShowStatus($"匹配失败: {res.Msg}", 4f);
    }

    private void OnCancelMatchRes(CancelMatchRes res)
    {
        if (res.Code == 0)
        {
            ResetMatchState(false);
            ShowStatus(string.IsNullOrEmpty(res.Msg) ? "已取消匹配" : res.Msg, 3f);
            return;
        }

        ShowStatus($"取消失败: {res.Msg}", 4f);
    }

    private void OnMatchFound(MatchFoundNotify notify)
    {
        _matching = false;
        _matchFound = true;
        _prepareSent = false;
        _waitingBattleConnect = false;
        _matchedPlayerIds.Clear();
        _prepareStates.Clear();

        foreach (int playerId in notify.Playerids)
        {
            _matchedPlayerIds.Add(playerId);
            _prepareStates[playerId] = false;
        }

        _showMatchPopup = true;
        _showBattleResultPopup = false;
        _lastBattleResult = null;
        Show();
        ShowStatus("匹配成功，请点击准备", 8f);
    }

    private void OnPrepareRes(PrepareRes res)
    {
        if (res.Code == 0)
        {
            _prepareSent = true;
            int myId = ClientSession.Instance != null ? ClientSession.Instance.PlayerId : 0;
            if (myId > 0)
            {
                _prepareStates[myId] = true;
            }
            ShowStatus(string.IsNullOrEmpty(res.Msg) ? "已准备，等待其他玩家" : res.Msg, 4f);
            return;
        }

        ShowStatus($"准备失败: {res.Msg}", 4f);
    }

    private void OnRoomPrepare(RoomPrepareNotify notify)
    {
        _matching = false;
        _matchFound = true;

        foreach (RoomPlayerState state in notify.Players)
        {
            if (!_matchedPlayerIds.Contains(state.Playerid))
            {
                _matchedPlayerIds.Add(state.Playerid);
            }
            _prepareStates[state.Playerid] = state.IsPrepared;
        }

        int myId = ClientSession.Instance != null ? ClientSession.Instance.PlayerId : 0;
        if (myId > 0 && _prepareStates.TryGetValue(myId, out bool minePrepared))
        {
            _prepareSent = minePrepared;
        }

        if (_prepareStates.Count > 0 && AllRoomPlayersPrepared())
        {
            _waitingBattleConnect = true;
            ShowStatus("所有玩家已准备，正在建立战斗连接", 5f);
        }
    }

    private void OnBattleConnect(BattleConnectNotify notify)
    {
        _waitingBattleConnect = true;
        _showMatchPopup = false;
        ShowStatus("收到战斗连接信息，正在握手...", 5f);

        if (BattleNetworkManager.Instance == null)
        {
            ShowStatus("BattleNetworkManager 未初始化", 4f);
            return;
        }

        if (!BattleNetworkManager.Instance.BeginSession(notify))
        {
            ShowStatus("KCP 战斗链路初始化失败", 4f);
            return;
        }

        ResetMatchState(false);
        OnEnteredScene();
    }

    private void OnRoomDismiss(RoomDismissNotify notify)
    {
        ResetMatchState(false);
        _showBattleResultPopup = false;
        _lastBattleResult = null;
        Show();
        ShowStatus(string.IsNullOrEmpty(notify.Reason) ? "房间已解散" : notify.Reason, 5f);
    }

    private void OnBattleResult(BattleResultNotify notify)
    {
        _lastBattleResult = notify == null ? null : notify.Clone();
        _showBattleResultPopup = _lastBattleResult != null;
        _showMatchPopup = false;

        if (BattleNetworkManager.Instance != null)
        {
            BattleNetworkManager.Instance.Disconnect();
        }

        ClientSession.Instance?.RequestBaseInfo();
    }

    private void ReturnToLobbyAfterBattleResult()
    {
        string resultText = BuildBattleResultText(_lastBattleResult);

        if (BattleNetworkManager.Instance != null)
        {
            BattleNetworkManager.Instance.Disconnect();
        }

        if (GameManager.Instance != null)
        {
            GameManager.Instance.ExitBattleScene();
        }

        if (LoginUI.Instance != null)
        {
            LoginUI.Instance.OnReturnedToLobbyFromBattle();
        }

        _showBattleResultPopup = false;
        _lastBattleResult = null;
        ResetMatchState(false);
        Show();
        ClientSession.Instance?.RequestBaseInfo();
        ShowStatus(resultText, 8f);
    }

    private string BuildBattleResultText(BattleResultNotify notify)
    {
        if (notify == null)
        {
            return "对局已结束";
        }

        return $"结算: 第{notify.Rank}名 体重{notify.WeightScore} 段位{FormatSigned(notify.ScoreDelta)} 金币+{notify.Coin} 经验+{notify.Exp}";
    }

    private string FormatSigned(int value)
    {
        if (value > 0)
            return "+" + value;
        return value.ToString();
    }

    public void OnEnteredScene()
    {
        Hide();
        if (LoginUI.Instance != null)
            LoginUI.Instance.OnEnteredSceneFromLobby();
        if (GameManager.Instance != null)
            GameManager.Instance.OnEnteredScene();
    }

    private void OnBaseInfoUpdated(BaseInfoRes res)
    {
        _baseInfo = res;
    }

    private void OnReconnectNotice(string notice)
    {
        ShowStatus(notice, 4f);
    }

    private void DrawProfileStrip(float x, float y, float width)
    {
        UIArtTheme.DrawRow(new Rect(x, y, width, 48), true);

        string mainLine = "基础资料加载中...";
        string subLine = "登录完成后会自动同步角色信息";

        if (_baseInfo != null)
        {
            mainLine = $"ID {_baseInfo.Playerid}    Lv {_baseInfo.Level}    VIP {_baseInfo.VipLevel}    金币 {_baseInfo.Coin}    经验 {_baseInfo.Exp}";
            subLine = $"段位分 {_baseInfo.RankScore}    上次登录: {FormatLastLogin(_baseInfo.LastLoginTime)}";
        }

        GUI.Label(new Rect(x + 10, y + 6, width - 20, 20), mainLine, _profileStyle);
        GUI.Label(new Rect(x + 10, y + 25, width - 20, 16), subLine, _profileSubStyle);
    }

    private string FormatLastLogin(int unixSeconds)
    {
        if (unixSeconds <= 0)
            return "无";

        try
        {
            var dt = DateTimeOffset.FromUnixTimeSeconds(unixSeconds).ToLocalTime();
            return dt.ToString("yyyy-MM-dd HH:mm:ss");
        }
        catch
        {
            return unixSeconds.ToString();
        }
    }

    private bool EnsureConnected()
    {
        if (NetworkManager.Instance == null || !NetworkManager.Instance.IsConnected)
        {
            ShowStatus("网络未连接");
            return false;
        }

        return true;
    }

    private bool CanCancelMatch()
    {
        return _matching && !_matchFound && !_waitingBattleConnect;
    }

    private bool CanUsePrimaryMatchAction()
    {
        if (NetworkManager.Instance == null || !NetworkManager.Instance.IsConnected)
        {
            return false;
        }

        if (_matchFound)
        {
            return !_prepareSent && !_waitingBattleConnect;
        }

        return !_matching && !_waitingBattleConnect;
    }

    private string GetPrimaryActionText()
    {
        if (_waitingBattleConnect)
            return "等待连接";
        if (_matchFound)
            return _prepareSent ? "已准备" : "准备";
        if (_matching)
            return "匹配中";
        return "开始匹配";
    }

    private string GetMatchStateText()
    {
        if (_waitingBattleConnect)
            return "等待战斗连接";
        if (_matchFound)
            return _prepareSent ? "已准备" : "等待准备";
        if (_matching)
            return "匹配中";
        return "空闲";
    }

    private string BuildPlayerLine()
    {
        if (_matchedPlayerIds.Count == 0)
        {
            return "当前没有匹配到的玩家";
        }

        return "房间玩家: " + string.Join(", ", _matchedPlayerIds);
    }

    private string BuildPrepareLine()
    {
        if (_prepareStates.Count == 0)
        {
            return "准备状态: -";
        }

        List<string> parts = new List<string>();
        foreach (int playerId in _matchedPlayerIds)
        {
            bool prepared = _prepareStates.TryGetValue(playerId, out bool value) && value;
            parts.Add($"{playerId}:{(prepared ? "已准备" : "未准备")}");
        }

        return "准备状态: " + string.Join("  ", parts);
    }

    private bool AllRoomPlayersPrepared()
    {
        if (_matchedPlayerIds.Count == 0)
        {
            return false;
        }

        foreach (int playerId in _matchedPlayerIds)
        {
            if (!_prepareStates.TryGetValue(playerId, out bool prepared) || !prepared)
            {
                return false;
            }
        }

        return true;
    }

    private void ResetMatchState(bool clearStatus = true)
    {
        _matching = false;
        _matchFound = false;
        _prepareSent = false;
        _waitingBattleConnect = false;
        _showMatchPopup = false;
        _matchedPlayerIds.Clear();
        _prepareStates.Clear();

        if (clearStatus)
        {
            _statusMsg = "";
            _statusTimer = 0f;
        }
    }
}
