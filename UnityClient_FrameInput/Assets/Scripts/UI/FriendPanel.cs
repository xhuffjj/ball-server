using System.Collections.Generic;
using Google.Protobuf;
using UnityEngine;
using Game;

/// <summary>
/// 好友面板 - 好友列表、待审批列表、添加好友、查看信息
/// </summary>
public class FriendPanel : MonoBehaviour
{
    public static FriendPanel Instance { get; private set; }

    // 子页签: 好友列表 / 待审批
    private int _subTab = 0;
    private readonly string[] _subTabNames = { "好友列表", "好友申请", "添加好友" };

    // 数据
    private List<FriendBrief> _friends = new List<FriendBrief>();
    private List<FriendBrief> _pending = new List<FriendBrief>();
    private string _addTargetId = "";
    private string _statusMsg = "";
    private float _statusTimer = 0f;

    // 查看信息
    private bool _showInfo = false;
    private PublicBaseInfo _infoData;

    // 滚动
    private Vector2 _friendScrollPos;
    private Vector2 _pendingScrollPos;

    // 样式
    private GUIStyle _labelStyle;
    private GUIStyle _smallBtnStyle;
    private GUIStyle _inputStyle;
    private GUIStyle _subTabStyle;
    private GUIStyle _subTabActiveStyle;
    private GUIStyle _statusStyle;
    private GUIStyle _headerStyle;
    private bool _stylesInited = false;

    void Awake()
    {
        if (Instance != null && Instance != this) { Destroy(gameObject); return; }
        Instance = this;
    }

    void Start()
    {
        var proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            Debug.LogError("[FriendPanel] ProtocolHandler 未初始化，好友模块回调注册失败");
            return;
        }
        proto.On<FriendListRes>("friend_list", OnFriendList);
        proto.On<FriendPendingRes>("friend_pending_list", OnPendingList);
        proto.On<FriendAddRes>("friend_add", OnAddRes);
        proto.On<FriendAcceptRes>("friend_accept", OnAcceptRes);
        proto.On<FriendRejectRes>("friend_reject", OnRejectRes);
        proto.On<FriendDeleteRes>("friend_delete", OnDeleteRes);
        proto.On<FriendInfoRes>("friend_info", OnInfoRes);

        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged += OnConnectionChanged;
        }
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged -= OnConnectionChanged;
        }
    }

    void Update()
    {
        if (_statusTimer > 0)
        {
            _statusTimer -= Time.deltaTime;
            if (_statusTimer <= 0) _statusMsg = "";
        }
    }

    private void InitStyles()
    {
        UIArtTheme.EnsureInit();

        _labelStyle = new GUIStyle(GUI.skin.label) { fontSize = 14 };
        _labelStyle.normal.textColor = new Color(0.84f, 0.93f, 1f);

        _smallBtnStyle = new GUIStyle(GUI.skin.button) { fontSize = 13, fixedHeight = 28 };
        UIArtTheme.SkinButton(_smallBtnStyle);

        _inputStyle = new GUIStyle(GUI.skin.textField) { fontSize = 14, fixedHeight = 28 };
        UIArtTheme.SkinInput(_inputStyle);

        _subTabStyle = new GUIStyle(GUI.skin.button) { fontSize = 14, fixedHeight = 30 };
        UIArtTheme.SkinTab(_subTabStyle, false);
        _subTabActiveStyle = new GUIStyle(_subTabStyle);
        UIArtTheme.SkinTab(_subTabActiveStyle, true);
        _subTabActiveStyle.fontStyle = FontStyle.Bold;

        _statusStyle = new GUIStyle(GUI.skin.label) { fontSize = 13, alignment = TextAnchor.MiddleCenter };
        _statusStyle.normal.textColor = new Color(1f, 0.93f, 0.62f);
        _headerStyle = new GUIStyle(GUI.skin.label) { fontSize = 15, fontStyle = FontStyle.Bold };
        _headerStyle.normal.textColor = new Color(0.72f, 0.93f, 1f);
        _stylesInited = true;
    }

    public void RequestData()
    {
        TrySend("friend_list", new FriendListReq());
        TrySend("friend_pending_list", new FriendPendingReq());
    }

    public void DrawPanel(Rect area)
    {
        if (!_stylesInited) InitStyles();
        UIArtTheme.DrawInset(area);

        float px = area.x + 10;
        float py = area.y + 8;
        float pw = area.width - 20;

        // 子 Tab
        float subTabW = (pw - (_subTabNames.Length - 1) * 4) / _subTabNames.Length;
        for (int i = 0; i < _subTabNames.Length; i++)
        {
            GUIStyle st = (i == _subTab) ? _subTabActiveStyle : _subTabStyle;
            if (GUI.Button(new Rect(px + i * (subTabW + 4), py, subTabW, 30), _subTabNames[i], st))
            {
                _subTab = i;
                _showInfo = false;
            }
        }
        py += 36;

        // 状态
        if (!string.IsNullOrEmpty(_statusMsg))
        {
            GUI.Label(new Rect(px, py, pw, 20), _statusMsg, _statusStyle);
            py += 22;
        }

        float contentH = area.y + area.height - py - 5;

        // 如果在看详情
        if (_showInfo && _infoData != null)
        {
            DrawInfoPopup(px, py, pw, contentH);
            return;
        }

        switch (_subTab)
        {
            case 0: DrawFriendList(px, py, pw, contentH); break;
            case 1: DrawPendingList(px, py, pw, contentH); break;
            case 2: DrawAddFriend(px, py, pw, contentH); break;
        }
    }

    private void DrawFriendList(float x, float y, float w, float h)
    {
        GUI.Label(new Rect(x, y, w, 22), $"好友 ({_friends.Count})", _headerStyle);
        if (GUI.Button(new Rect(x + w - 60, y, 60, 24), "刷新", _smallBtnStyle))
        {
            RequestData();
        }
        y += 24;
        h -= 24;

        Rect viewRect = new Rect(0, 0, w - 20, _friends.Count * 35 + 10);
        _friendScrollPos = GUI.BeginScrollView(new Rect(x, y, w, h), _friendScrollPos, viewRect);
        float cy = 5;
        foreach (var f in _friends)
        {
            UIArtTheme.DrawRow(new Rect(2, cy, w - 24, 30), true);
            string online = f.IsOnline != 0 ? "<color=lime>[在线]</color>" : "<color=grey>[离线]</color>";
            GUIStyle richLabel = new GUIStyle(_labelStyle) { richText = true };
            GUI.Label(new Rect(5, cy, 200, 28), $"ID: {f.Friendid}  {online}", richLabel);

            if (GUI.Button(new Rect(w - 180, cy, 60, 28), "信息", _smallBtnStyle))
            {
                TrySend("friend_info", new FriendInfoReq { Friendid = f.Friendid });
            }
            if (GUI.Button(new Rect(w - 110, cy, 60, 28), "删除", _smallBtnStyle))
            {
                TrySend("friend_delete", new FriendDeleteReq { TargetId = f.Friendid });
            }
            cy += 35;
        }
        GUI.EndScrollView();
    }

    private void DrawPendingList(float x, float y, float w, float h)
    {
        GUI.Label(new Rect(x, y, w, 22), $"收到的申请 ({_pending.Count})", _headerStyle);
        if (GUI.Button(new Rect(x + w - 60, y, 60, 24), "刷新", _smallBtnStyle))
        {
            RequestData();
        }
        y += 24;
        h -= 24;

        Rect viewRect = new Rect(0, 0, w - 20, _pending.Count * 35 + 10);
        _pendingScrollPos = GUI.BeginScrollView(new Rect(x, y, w, h), _pendingScrollPos, viewRect);
        float cy = 5;
        foreach (var f in _pending)
        {
            UIArtTheme.DrawRow(new Rect(2, cy, w - 24, 30));
            GUI.Label(new Rect(5, cy, 200, 28), $"来自: {f.Friendid}", _labelStyle);

            if (GUI.Button(new Rect(w - 180, cy, 60, 28), "接受", _smallBtnStyle))
            {
                TrySend("friend_accept", new FriendAcceptReq { TargetId = f.Friendid });
            }
            if (GUI.Button(new Rect(w - 110, cy, 60, 28), "拒绝", _smallBtnStyle))
            {
                TrySend("friend_reject", new FriendRejectReq { TargetId = f.Friendid });
            }
            cy += 35;
        }
        GUI.EndScrollView();
    }

    private void DrawAddFriend(float x, float y, float w, float h)
    {
        UIArtTheme.DrawRow(new Rect(x - 2, y - 2, w * 0.62f, 34), true);
        GUI.Label(new Rect(x, y, w, 22), "添加好友", _headerStyle);
        y += 30;

        GUI.Label(new Rect(x, y, 80, 28), "玩家ID:", _labelStyle);
        _addTargetId = GUI.TextField(new Rect(x + 80, y, 150, 28), _addTargetId, _inputStyle);
        if (GUI.Button(new Rect(x + 240, y, 80, 28), "发送申请", _smallBtnStyle))
        {
            if (int.TryParse(_addTargetId, out int tid))
            {
                TrySend("friend_add", new FriendAddReq { TargetId = tid });
            }
            else
            {
                SetStatus("请输入有效的玩家ID");
            }
        }
    }

    private void DrawInfoPopup(float x, float y, float w, float h)
    {
        UIArtTheme.DrawInset(new Rect(x - 6, y - 6, w + 12, Mathf.Min(h, 190f)));
        GUI.Label(new Rect(x, y, w, 22), "玩家信息", _headerStyle);
        y += 28;
        GUI.Label(new Rect(x, y, w, 22), $"玩家ID: {_infoData.Playerid}", _labelStyle); y += 22;
        GUI.Label(new Rect(x, y, w, 22), $"等级: {_infoData.Level}", _labelStyle); y += 22;
        GUI.Label(new Rect(x, y, w, 22), $"VIP等级: {_infoData.VipLevel}", _labelStyle); y += 22;
        GUI.Label(new Rect(x, y, w, 22), $"在线: {(_infoData.IsOnline ? "是" : "否")}", _labelStyle); y += 22;
        GUI.Label(new Rect(x, y, w, 22), $"在场景中: {(_infoData.InScene ? "是" : "否")}", _labelStyle); y += 30;

        if (GUI.Button(new Rect(x, y, 80, 28), "返回", _smallBtnStyle))
        {
            _showInfo = false;
        }
    }

    // --- 回调 ---
    private void OnFriendList(FriendListRes res)
    {
        _friends.Clear();
        foreach (var f in res.Friends)
            _friends.Add(f);
        _friends.Sort((a, b) => a.Friendid.CompareTo(b.Friendid));
    }

    private void OnPendingList(FriendPendingRes res)
    {
        _pending.Clear();
        foreach (var f in res.Friends)
            _pending.Add(f);
        _pending.Sort((a, b) => a.Friendid.CompareTo(b.Friendid));
    }

    private void OnAddRes(FriendAddRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0) RequestData();
    }

    private void OnAcceptRes(FriendAcceptRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0) RequestData();
    }

    private void OnRejectRes(FriendRejectRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0) RequestData();
    }

    private void OnDeleteRes(FriendDeleteRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0) RequestData();
    }

    private void OnInfoRes(FriendInfoRes res)
    {
        if (res.Code == 0 && res.Info != null)
        {
            _infoData = res.Info;
            _showInfo = true;
        }
        else
        {
            SetStatus(res.Msg);
        }
    }

    private void SetStatus(string msg)
    {
        _statusMsg = msg;
        _statusTimer = 3f;
    }

    private bool TrySend(string cmd, IMessage msg)
    {
        var net = NetworkManager.Instance;
        if (net == null || !net.IsConnected)
        {
            SetStatus("网络未连接");
            return false;
        }
        net.Send(cmd, msg);
        return true;
    }

    private void OnConnectionChanged(bool connected)
    {
        if (connected) return;
        if (ClientSession.Instance != null && ClientSession.Instance.ShouldPreserveStateOnDisconnect())
            return;

        _friends.Clear();
        _pending.Clear();
        _showInfo = false;
        _infoData = null;
        _friendScrollPos = Vector2.zero;
        _pendingScrollPos = Vector2.zero;
    }
}
