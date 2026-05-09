using System;
using System.Collections.Generic;
using System.Text;
using Google.Protobuf;
using UnityEngine;

/// <summary>
/// 常驻协议实时窗口：展示客户端与服务器的收发协议（JSON）
/// </summary>
public class ProtocolTracePanel : MonoBehaviour
{
    private const int WindowId = 9917;
    private const int MaxRecords = 180;

    [SerializeField] private bool Visible = true;

    private Rect _windowRect = new Rect(20, 12, 520, 360);
    private bool _windowPosInited = false;
    private bool _collapsed = false;
    private bool _followTail = true;
    private Vector2 _scrollPos;

    private readonly List<TraceRecord> _records = new List<TraceRecord>();
    private string _displayText = "";

    private GUIStyle _btnStyle;
    private GUIStyle _metaStyle;
    private GUIStyle _textAreaStyle;
    private bool _stylesInited = false;

    private struct TraceRecord
    {
        public string Time;
        public string Direction;
        public string Cmd;
        public string Json;
    }

    [Serializable]
    private class DecodeFallback
    {
        public string decode_error;
        public int body_length;
        public string body_base64;
    }

    [Serializable]
    private class ConnectionTrace
    {
        public bool connected;
    }

    void Start()
    {
        var net = NetworkManager.Instance;
        if (net == null)
        {
            Debug.LogError("[ProtocolTracePanel] NetworkManager 未初始化，协议窗口订阅失败");
            return;
        }

        net.OnMessageSent += OnMessageSent;
        net.OnMessageReceived += OnMessageReceived;
        net.OnConnectionChanged += OnConnectionChanged;

        var battleNet = BattleNetworkManager.Instance;
        if (battleNet != null)
        {
            battleNet.OnMessageSent += OnBattleMessageSent;
            battleNet.OnMessageReceived += OnBattleMessageReceived;
            battleNet.OnTraceLogged += OnBattleTraceLogged;
        }
    }

    void OnDestroy()
    {
        var net = NetworkManager.Instance;
        if (net == null) return;

        net.OnMessageSent -= OnMessageSent;
        net.OnMessageReceived -= OnMessageReceived;
        net.OnConnectionChanged -= OnConnectionChanged;

        var battleNet = BattleNetworkManager.Instance;
        if (battleNet == null) return;

        battleNet.OnMessageSent -= OnBattleMessageSent;
        battleNet.OnMessageReceived -= OnBattleMessageReceived;
        battleNet.OnTraceLogged -= OnBattleTraceLogged;
    }

    void OnGUI()
    {
        if (!Visible) return;
        if (!_stylesInited) InitStyles();

        if (!_windowPosInited)
        {
            _windowRect.x = Mathf.Max(10f, Screen.width - _windowRect.width - 10f);
            _windowRect.y = 10f;
            _windowPosInited = true;
        }

        _windowRect = GUI.Window(WindowId, _windowRect, DrawWindow, "协议实时交互 (JSON)");
    }

    private void InitStyles()
    {
        _btnStyle = new GUIStyle(GUI.skin.button) { fontSize = 12 };
        _metaStyle = new GUIStyle(GUI.skin.label) { fontSize = 12 };
        _metaStyle.normal.textColor = new Color(0.88f, 0.95f, 1f);
        _textAreaStyle = new GUIStyle(GUI.skin.textArea)
        {
            fontSize = 12,
            wordWrap = true,
            alignment = TextAnchor.UpperLeft
        };
        _stylesInited = true;
    }

    private void DrawWindow(int id)
    {
        float topY = 24f;

        if (GUI.Button(new Rect(8, topY, 54, 22), _collapsed ? "展开" : "收起", _btnStyle))
        {
            _collapsed = !_collapsed;
        }

        if (GUI.Button(new Rect(66, topY, 54, 22), "清空", _btnStyle))
        {
            _records.Clear();
            _displayText = "";
            _scrollPos = Vector2.zero;
        }

        _followTail = GUI.Toggle(new Rect(126, topY + 2, 80, 20), _followTail, "跟随");
        GUI.Label(new Rect(210, topY + 2, 180, 20), $"记录: {_records.Count}", _metaStyle);
        topY += 28f;

        if (!_collapsed)
        {
            float viewW = _windowRect.width - 16f;
            float viewH = _windowRect.height - topY - 8f;
            Rect viewRect = new Rect(8, topY, viewW, viewH);

            float contentW = Mathf.Max(50f, viewW - 20f);
            float contentH = Mathf.Max(viewH, _textAreaStyle.CalcHeight(new GUIContent(_displayText), contentW) + 10f);

            _scrollPos = GUI.BeginScrollView(viewRect, _scrollPos, new Rect(0, 0, contentW, contentH));
            GUI.TextArea(new Rect(0, 0, contentW, contentH), _displayText, _textAreaStyle);
            GUI.EndScrollView();

            if (_followTail && Event.current.type == EventType.Repaint)
            {
                _scrollPos.y = float.MaxValue;
            }
        }

        GUI.DragWindow(new Rect(0, 0, _windowRect.width, 22f));
    }

    private void OnConnectionChanged(bool connected)
    {
        var stateJson = JsonUtility.ToJson(new ConnectionTrace { connected = connected }, true);
        AddRecord("SYS", "connection", stateJson);
    }

    private void OnMessageSent(string cmd, IMessage msg)
    {
        AddRecord("C->S", cmd, FormatMessageJson(msg));
    }

    private void OnMessageReceived(string cmd, byte[] body)
    {
        AddRecord("S->C", cmd, DecodeIncomingJson(cmd, body));
    }

    private void OnBattleMessageSent(string cmd, IMessage msg)
    {
        AddRecord("C->KCP", cmd, FormatMessageJson(msg));
    }

    private void OnBattleMessageReceived(string cmd, byte[] body)
    {
        AddRecord("KCP->C", cmd, DecodeIncomingJson(cmd, body));
    }

    private void OnBattleTraceLogged(string cmd, string json)
    {
        AddRecord("KCP", cmd, string.IsNullOrEmpty(json) ? "{}" : json);
    }

    private string FormatMessageJson(IMessage msg)
    {
        if (msg == null)
        {
            return JsonUtility.ToJson(new DecodeFallback
            {
                decode_error = "发送消息为空",
                body_length = 0,
                body_base64 = ""
            }, true);
        }

        try
        {
            return JsonFormatter.Default.Format(msg);
        }
        catch (Exception e)
        {
            return JsonUtility.ToJson(new DecodeFallback
            {
                decode_error = $"JSON编码失败: {e.Message}",
                body_length = 0,
                body_base64 = ""
            }, true);
        }
    }

    private string DecodeIncomingJson(string cmd, byte[] body)
    {
        var proto = ProtocolHandler.Instance;
        if (proto == null)
        {
            return BuildFallbackJson("ProtocolHandler 未初始化", body);
        }

        if (!proto.TryParse(cmd, body, out IMessage msg, out string err))
        {
            return BuildFallbackJson(err, body);
        }

        return FormatMessageJson(msg);
    }

    private string BuildFallbackJson(string error, byte[] body)
    {
        string base64 = "";
        if (body != null && body.Length > 0)
        {
            base64 = Convert.ToBase64String(body);
            if (base64.Length > 1024)
                base64 = base64.Substring(0, 1024) + "...";
        }

        return JsonUtility.ToJson(new DecodeFallback
        {
            decode_error = string.IsNullOrEmpty(error) ? "未知错误" : error,
            body_length = body == null ? 0 : body.Length,
            body_base64 = base64
        }, true);
    }

    private void AddRecord(string direction, string cmd, string json)
    {
        _records.Add(new TraceRecord
        {
            Time = DateTime.Now.ToString("HH:mm:ss.fff"),
            Direction = direction,
            Cmd = cmd,
            Json = string.IsNullOrEmpty(json) ? "{}" : json
        });

        if (_records.Count > MaxRecords)
        {
            _records.RemoveAt(0);
        }

        RebuildDisplayText();
    }

    private void RebuildDisplayText()
    {
        var sb = new StringBuilder(_records.Count * 128);
        foreach (var rec in _records)
        {
            sb.Append('[').Append(rec.Time).Append("] ")
              .Append(rec.Direction).Append("  ")
              .Append(rec.Cmd).Append('\n');
            sb.Append(rec.Json).Append('\n').Append('\n');
        }
        _displayText = sb.ToString();
    }
}
