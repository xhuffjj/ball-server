using System.Collections.Generic;
using Google.Protobuf;
using UnityEngine;
using Game;

/// <summary>
/// 成就面板 - 成就列表、进度显示、领取奖励
/// </summary>
public class AchievePanel : MonoBehaviour
{
    public static AchievePanel Instance { get; private set; }

    private List<AchieveInfo> _achieves = new List<AchieveInfo>();
    private string _statusMsg = "";
    private float _statusTimer = 0f;
    private Vector2 _scrollPos;

    // 样式
    private GUIStyle _labelStyle;
    private GUIStyle _smallBtnStyle;
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
            Debug.LogError("[AchievePanel] ProtocolHandler 未初始化，成就模块回调注册失败");
            return;
        }
        proto.On<AchieveListRes>("achieve_list", OnAchieveList);
        proto.On<AchieveClaimRes>("achieve_claim", OnAchieveClaim);
        proto.On<AchieveNotify>("achieve_notify", OnAchieveNotify);

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

        _statusStyle = new GUIStyle(GUI.skin.label) { fontSize = 13, alignment = TextAnchor.MiddleCenter };
        _statusStyle.normal.textColor = new Color(1f, 0.93f, 0.62f);
        _headerStyle = new GUIStyle(GUI.skin.label) { fontSize = 15, fontStyle = FontStyle.Bold };
        _headerStyle.normal.textColor = new Color(0.72f, 0.93f, 1f);
        _stylesInited = true;
    }

    public void RequestData()
    {
        TrySend("achieve_list", new AchieveListReq());
    }

    public void DrawPanel(Rect area)
    {
        if (!_stylesInited) InitStyles();
        UIArtTheme.DrawInset(area);

        float px = area.x + 10;
        float py = area.y + 8;
        float pw = area.width - 20;

        // 标题 + 刷新
        GUI.Label(new Rect(px, py, 200, 22), $"成就 ({_achieves.Count})", _headerStyle);
        if (GUI.Button(new Rect(px + pw - 60, py, 60, 24), "刷新", _smallBtnStyle))
        {
            RequestData();
        }
        py += 28;

        // 状态
        if (!string.IsNullOrEmpty(_statusMsg))
        {
            GUI.Label(new Rect(px, py, pw, 20), _statusMsg, _statusStyle);
            py += 22;
        }

        float contentH = area.y + area.height - py - 5;

        Rect viewRect = new Rect(0, 0, pw - 20, _achieves.Count * 55 + 10);
        _scrollPos = GUI.BeginScrollView(new Rect(px, py, pw, contentH), _scrollPos, viewRect);

        float cy = 5;
        foreach (var a in _achieves)
        {
            DrawAchieveItem(a, pw - 20, ref cy);
        }

        GUI.EndScrollView();
    }

    private void DrawAchieveItem(AchieveInfo a, float w, ref float cy)
    {
        UIArtTheme.DrawRow(new Rect(2, cy, w - 24, 44), a.IsDone != 0 && string.IsNullOrEmpty(a.ClaimTime));
        GUIStyle richLabel = new GUIStyle(_labelStyle) { richText = true };

        // 状态颜色
        string statusText;
        if (!string.IsNullOrEmpty(a.ClaimTime))
        {
            statusText = "<color=#888888>已领取</color>";
        }
        else if (a.IsDone != 0)
        {
            statusText = "<color=lime>已完成 - 可领取!</color>";
        }
        else
        {
            statusText = $"<color=white>进度: {a.Progress}</color>";
        }

        string achieveName = ClientStaticData.GetAchieveName(a.AchieveId);
        string achieveDesc = ClientStaticData.GetAchieveDescription(a.AchieveId);

        GUI.Label(new Rect(5, cy, w - 120, 22), achieveName, _labelStyle);
        GUI.Label(new Rect(5, cy + 20, w - 120, 22), statusText, richLabel);
        GUI.Label(new Rect(180, cy, w - 300, 22), achieveDesc, richLabel);

        // 领取按钮
        if (a.IsDone != 0 && string.IsNullOrEmpty(a.ClaimTime))
        {
            if (GUI.Button(new Rect(w - 100, cy + 8, 80, 28), "领取奖励", _smallBtnStyle))
            {
                TrySend("achieve_claim", new AchieveClaimReq { AchieveId = a.AchieveId });
            }
        }

        // 分隔线
        cy += 50;
        UIArtTheme.DrawSeparator(new Rect(5, cy, w - 10, 1));
        cy += 5;
    }

    // --- 回调 ---
    private void OnAchieveList(AchieveListRes res)
    {
        _achieves.Clear();
        foreach (var a in res.Achieves)
            _achieves.Add(a);
        SortAchieves();
    }

    private void OnAchieveClaim(AchieveClaimRes res)
    {
        SetStatus(res.Msg);
        if (res.Code == 0)
        {
            RequestData();
            ClientSession.Instance?.RequestBaseInfo();
        }
    }

    private void OnAchieveNotify(AchieveNotify notify)
    {
        if (notify.Achieveinfo != null)
        {
            // 更新本地数据
            var info = notify.Achieveinfo;
            bool found = false;
            for (int i = 0; i < _achieves.Count; i++)
            {
                if (_achieves[i].AchieveId == info.AchieveId)
                {
                    _achieves[i] = info;
                    found = true;
                    break;
                }
            }
            if (!found) _achieves.Add(info);
            SortAchieves();
            SetStatus($"成就 #{info.AchieveId} 已完成!");
        }
    }

    private void SetStatus(string msg)
    {
        _statusMsg = msg;
        _statusTimer = 3f;
    }

    private void SortAchieves()
    {
        // 可领取在前，未完成次之，已领取最后
        _achieves.Sort((a, b) =>
        {
            int aOrder = string.IsNullOrEmpty(a.ClaimTime) ? (a.IsDone != 0 ? 0 : 1) : 2;
            int bOrder = string.IsNullOrEmpty(b.ClaimTime) ? (b.IsDone != 0 ? 0 : 1) : 2;
            if (aOrder != bOrder) return aOrder.CompareTo(bOrder);
            return a.AchieveId.CompareTo(b.AchieveId);
        });
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
        _achieves.Clear();
        _scrollPos = Vector2.zero;
    }
}
