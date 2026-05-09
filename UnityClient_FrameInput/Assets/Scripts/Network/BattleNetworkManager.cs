using System;
using System.Net;
using System.Net.Sockets;
using Game;
using Google.Protobuf;
using kcp2k;
using UnityEngine;

/// <summary>
/// 战斗专用网络管理器。
/// 大厅和登录继续走 TCP；战斗快照与输入改走 UDP + KCP。
/// 掉线恢复时不新增协议，直接复用现有 battle_auth/battle_ready_ack 三次握手。
/// </summary>
public class BattleNetworkManager : MonoBehaviour
{
    public static BattleNetworkManager Instance { get; private set; }

    public bool HasReceivedFirstSnapshot => _hasReceivedFirstSnapshot;
    public bool IsReadyForInput =>
        !IsDebugTransportSuppressed() &&
        _state == BattleState.Active &&
        _hasReceivedFirstSnapshot &&
        _kcp != null &&
        _socket != null;

    public event Action<string, IMessage> OnMessageSent;
    public event Action<string, byte[]> OnMessageReceived;
    public event Action<string, string> OnTraceLogged;

    private enum BattleState
    {
        None = 0,
        WaitingAuth = 1,
        WaitingSnapshot = 2,
        Active = 3
    }

    private const int SocketBufferSize = 1024 * 1024;
    private const int UdpReceiveBufferSize = 2048;
    private const int KcpMessageBufferSize = 256 * 1024;
    private const int KcpMtu = 1200;
    private const uint KcpWindowSize = 128;
    private const uint KcpInterval = 10;
    private const int KcpFastResend = 2;
    private const int KcpMinRto = 10;

    private const float ActiveNoPacketTimeoutSeconds = 1.0f;
    private const float HandshakeRetrySeconds = 1.0f;
    private const float DebugSilenceSeconds = 10.0f;

    private Socket _socket;
    private EndPoint _remoteEndPoint;
    private Kcp _kcp;
    private readonly byte[] _udpReceiveBuffer = new byte[UdpReceiveBufferSize];
    private readonly byte[] _kcpMessageBuffer = new byte[KcpMessageBufferSize];

    private BattleState _state = BattleState.None;
    private bool _hasReceivedFirstSnapshot = false;
    private bool _hasSessionContext = false;
    private bool _hasEverReceivedSnapshot = false;
    private uint _nextKcpUpdate = 0;
    private float _lastPacketReceivedAt = 0f;
    private float _lastHandshakeAttemptAt = -999f;
    private float _debugSilenceEndAt = -1f;

    private string _battleHost = "";
    private int _battlePort = 0;
    private uint _battleConv = 0;
    private string _battleToken = "";

    [Serializable]
    private class TracePayload
    {
        public string message;
        public string state;
        public string host;
        public int port;
        public uint conv;
    }

    void Awake()
    {
        if (Instance != null && Instance != this)
        {
            Destroy(gameObject);
            return;
        }

        Instance = this;
        DontDestroyOnLoad(gameObject);
    }

    void Start()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged += OnTcpConnectionChanged;
        }
    }

    void Update()
    {
        if (_socket != null && _kcp != null && !IsDebugTransportSuppressed())
        {
            PumpUdpReceive();

            uint now = NowMs();
            if (now >= _nextKcpUpdate)
            {
                _kcp.Update(now);
                _nextKcpUpdate = _kcp.Check(now);
            }
        }

        if (UpdateDebugDisconnectSimulation())
        {
            return;
        }

        TryReconnectByHandshake();
    }

    void OnDestroy()
    {
        if (NetworkManager.Instance != null)
        {
            NetworkManager.Instance.OnConnectionChanged -= OnTcpConnectionChanged;
        }

        Disconnect();

        if (Instance == this)
        {
            Instance = null;
        }
    }

    public bool BeginSession(BattleConnectNotify battleConnect)
    {
        if (battleConnect == null)
        {
            Debug.LogError("[BattleNet] battle_connect 为空，无法建立 KCP 战斗链路");
            return false;
        }

        if (string.IsNullOrEmpty(battleConnect.BattleHost) ||
            battleConnect.BattlePort <= 0 ||
            battleConnect.BattleConv == 0 ||
            string.IsNullOrEmpty(battleConnect.BattleToken))
        {
            Debug.LogError("[BattleNet] battle_connect 的 battle 信息不完整");
            return false;
        }

        return BeginSession(
            battleConnect.BattleHost,
            battleConnect.BattlePort,
            battleConnect.BattleConv,
            battleConnect.BattleToken,
            "battle_connect");
    }

    private bool BeginSession(string host, int port, uint conv, string token, string reason)
    {
        CacheSession(host, port, conv, token);
        _hasEverReceivedSnapshot = false;
        return StartHandshake(reason);
    }

    public bool TriggerDebugDisconnectBySilence()
    {
        if (!_hasSessionContext || _state != BattleState.Active || _socket == null || _kcp == null)
        {
            return false;
        }

        if (IsDebugTransportSuppressed())
        {
            return false;
        }

        _debugSilenceEndAt = Time.realtimeSinceStartup + DebugSilenceSeconds;
        Debug.Log(string.Format(
            "[BattleNet] F10 调试断线：故意静默 {0:0} 秒，不收不发任何 KCP/UDP 包，随后重新三次握手",
            DebugSilenceSeconds));
        LogTrace("kcp_debug_disconnect", new TracePayload
        {
            message = string.Format("silence {0:0}s then handshake", DebugSilenceSeconds),
            state = _state.ToString(),
            host = _battleHost,
            port = _battlePort,
            conv = _battleConv
        });
        return true;
    }

    public bool SendMessage(string cmd, IMessage protoMsg)
    {
        if (_state == BattleState.None || _kcp == null || IsDebugTransportSuppressed())
        {
            return false;
        }

        if (cmd == "input_frame" && !IsReadyForInput)
        {
            return false;
        }

        byte[] payload = BattlePacketCodec.Encode(cmd, protoMsg);
        int result = _kcp.Send(payload, 0, payload.Length);
        if (result < 0)
        {
            Debug.LogWarning(string.Format("[BattleNet] KCP 发送失败: cmd={0}, code={1}", cmd, result));
            LogTrace("kcp_send_error", new TracePayload
            {
                message = "send failed",
                state = _state.ToString(),
                conv = _battleConv
            });
            return false;
        }

        OnMessageSent?.Invoke(cmd, protoMsg);
        DriveKcp();
        return true;
    }

    public void Disconnect()
    {
        CloseTransport();
        _state = BattleState.None;
        _hasReceivedFirstSnapshot = false;
        _hasSessionContext = false;
        _hasEverReceivedSnapshot = false;
        _battleHost = "";
        _battlePort = 0;
        _battleConv = 0;
        _battleToken = "";
        _lastPacketReceivedAt = 0f;
        _lastHandshakeAttemptAt = -999f;
        _debugSilenceEndAt = -1f;

        if (PlayerController.Instance != null)
        {
            PlayerController.Instance.Deactivate();
        }
    }

    private void CacheSession(string host, int port, uint conv, string token)
    {
        _battleHost = host ?? "";
        _battlePort = port;
        _battleConv = conv;
        _battleToken = token ?? "";
        _hasSessionContext =
            !string.IsNullOrEmpty(_battleHost) &&
            _battlePort > 0 &&
            _battleConv != 0 &&
            !string.IsNullOrEmpty(_battleToken);
    }

    private bool StartHandshake(string reason)
    {
        if (!_hasSessionContext)
        {
            return false;
        }

        CloseTransport();

        if (!TryCreateSocket(_battleHost, _battlePort))
        {
            return false;
        }

        _kcp = new Kcp(_battleConv, RawKcpOutput);
        _kcp.SetNoDelay(1, KcpInterval, KcpFastResend, true);
        _kcp.SetWindowSize(KcpWindowSize, KcpWindowSize);
        _kcp.SetMtu(KcpMtu);
        _kcp.rx_minrto = KcpMinRto;

        _state = BattleState.WaitingAuth;
        _hasReceivedFirstSnapshot = false;
        _nextKcpUpdate = NowMs();
        _lastPacketReceivedAt = Time.realtimeSinceStartup;
        _lastHandshakeAttemptAt = _lastPacketReceivedAt;

        if (PlayerController.Instance != null)
        {
            PlayerController.Instance.Deactivate();
        }

        Debug.Log(string.Format(
            "[BattleNet] 发起三次握手({0}): {1}:{2}, conv={3}",
            reason,
            _battleHost,
            _battlePort,
            _battleConv));
        LogTrace("kcp_handshake", new TracePayload
        {
            message = reason,
            state = _state.ToString(),
            host = _battleHost,
            port = _battlePort,
            conv = _battleConv
        });

        return SendMessage("battle_auth", new BattleAuthReq
        {
            Token = _battleToken
        });
    }

    private void TryReconnectByHandshake()
    {
        if (IsDebugTransportSuppressed())
        {
            return;
        }

        if (!_hasSessionContext)
        {
            return;
        }

        float now = Time.realtimeSinceStartup;

        if (_state == BattleState.Active)
        {
            if (now - _lastPacketReceivedAt < ActiveNoPacketTimeoutSeconds)
            {
                return;
            }

            StartHandshake("active timeout");
            return;
        }

        if (_state == BattleState.WaitingAuth || _state == BattleState.WaitingSnapshot)
        {
            if (now - _lastHandshakeAttemptAt < HandshakeRetrySeconds)
            {
                return;
            }

            StartHandshake(_hasEverReceivedSnapshot ? "reconnect retry" : "initial retry");
        }
    }

    private void CloseTransport()
    {
        try
        {
            _socket?.Close();
        }
        catch
        {
        }

        _socket = null;
        _remoteEndPoint = null;
        _kcp = null;
        _nextKcpUpdate = 0;
    }

    private bool TryCreateSocket(string host, int port)
    {
        try
        {
            IPAddress address;
            if (!IPAddress.TryParse(host, out address))
            {
                IPAddress[] addresses = Dns.GetHostAddresses(host);
                if (addresses == null || addresses.Length == 0)
                {
                    Debug.LogError("[BattleNet] 无法解析 battle_host");
                    return false;
                }

                address = addresses[0];
            }

            _remoteEndPoint = new IPEndPoint(address, port);
            _socket = new Socket(address.AddressFamily, SocketType.Dgram, ProtocolType.Udp);
            _socket.ReceiveBufferSize = SocketBufferSize;
            _socket.SendBufferSize = SocketBufferSize;
            _socket.Blocking = false;
            _socket.Connect(_remoteEndPoint);
            return true;
        }
        catch (Exception e)
        {
            Debug.LogError("[BattleNet] 创建 UDP socket 失败: " + e.Message);
            CloseTransport();
            return false;
        }
    }

    private void RawKcpOutput(byte[] buffer, int length)
    {
        if (_socket == null || length <= 0 || IsDebugTransportSuppressed())
        {
            return;
        }

        try
        {
            _socket.Send(buffer, 0, length, SocketFlags.None);
        }
        catch (SocketException e)
        {
            if (e.SocketErrorCode == SocketError.WouldBlock || e.SocketErrorCode == SocketError.IOPending)
            {
                return;
            }

            Debug.LogError("[BattleNet] UDP 发送失败: " + e.Message);
            LogTrace("kcp_transport_error", new TracePayload
            {
                message = e.Message,
                state = _state.ToString(),
                conv = _battleConv
            });
            CloseTransport();
        }
        catch (Exception e)
        {
            Debug.LogError("[BattleNet] UDP 发送异常: " + e.Message);
            LogTrace("kcp_transport_error", new TracePayload
            {
                message = e.Message,
                state = _state.ToString(),
                conv = _battleConv
            });
            CloseTransport();
        }
    }

    private void PumpUdpReceive()
    {
        while (_socket != null)
        {
            bool hasData;
            try
            {
                hasData = _socket.Poll(0, SelectMode.SelectRead);
            }
            catch (SocketException e)
            {
                Debug.LogError("[BattleNet] UDP 轮询失败: " + e.Message);
                LogTrace("kcp_transport_error", new TracePayload
                {
                    message = e.Message,
                    state = _state.ToString(),
                    conv = _battleConv
                });
                CloseTransport();
                return;
            }

            if (!hasData)
            {
                break;
            }

            try
            {
                int received = _socket.Receive(_udpReceiveBuffer);
                if (received <= 0)
                {
                    break;
                }

                int result = _kcp.Input(_udpReceiveBuffer, 0, received);
                if (result < 0)
                {
                    Debug.LogWarning("[BattleNet] KCP 输入失败，收到的 UDP 数据不是合法 KCP 分片");
                    continue;
                }

                DrainKcpMessages();
                DriveKcp();
            }
            catch (SocketException e)
            {
                if (e.SocketErrorCode == SocketError.WouldBlock || e.SocketErrorCode == SocketError.IOPending)
                {
                    break;
                }

                Debug.LogError("[BattleNet] UDP 接收失败: " + e.Message);
                LogTrace("kcp_transport_error", new TracePayload
                {
                    message = e.Message,
                    state = _state.ToString(),
                    conv = _battleConv
                });
                CloseTransport();
                return;
            }
            catch (Exception e)
            {
                Debug.LogError("[BattleNet] UDP 接收异常: " + e.Message);
                LogTrace("kcp_transport_error", new TracePayload
                {
                    message = e.Message,
                    state = _state.ToString(),
                    conv = _battleConv
                });
                CloseTransport();
                return;
            }
        }
    }

    private void DrainKcpMessages()
    {
        while (_kcp != null)
        {
            int length = _kcp.Receive(_kcpMessageBuffer, _kcpMessageBuffer.Length);
            if (length < 0)
            {
                break;
            }

            string cmd;
            byte[] body;
            string error;
            if (!BattlePacketCodec.TryDecode(_kcpMessageBuffer, length, out cmd, out body, out error))
            {
                Debug.LogWarning("[BattleNet] KCP 业务包解码失败: " + error);
                continue;
            }

            HandleBattleMessage(cmd, body);
        }
    }

    private void HandleBattleMessage(string cmd, byte[] body)
    {
        _lastPacketReceivedAt = Time.realtimeSinceStartup;
        OnMessageReceived?.Invoke(cmd, body);

        if (cmd == "battle_auth")
        {
            HandleBattleAuth(body);
            return;
        }

        if (cmd == "scene_snapshot")
        {
            _hasReceivedFirstSnapshot = true;
            _hasEverReceivedSnapshot = true;
            _state = BattleState.Active;
            DispatchToProtocol(cmd, body);
            return;
        }

        if (cmd == "frame_update" && !_hasReceivedFirstSnapshot)
        {
            return;
        }

        DispatchToProtocol(cmd, body);
    }

    private void HandleBattleAuth(byte[] body)
    {
        BattleAuthRes res;
        try
        {
            res = BattleAuthRes.Parser.ParseFrom(body);
        }
        catch (Exception e)
        {
            Debug.LogError("[BattleNet] battle_auth 解析失败: " + e.Message);
            LogTrace("kcp_auth_error", new TracePayload
            {
                message = e.Message,
                state = _state.ToString(),
                conv = _battleConv
            });
            return;
        }

        if (res.Code != 0)
        {
            Debug.LogError("[BattleNet] battle_auth 失败: " + res.Msg);
            LogTrace("kcp_auth_error", new TracePayload
            {
                message = res.Msg,
                state = _state.ToString(),
                conv = _battleConv
            });
            return;
        }

        _state = BattleState.WaitingSnapshot;
        SendMessage("battle_ready_ack", new BattleReadyAckReq
        {
            ReadySeq = res.ReadySeq
        });
    }

    private void DispatchToProtocol(string cmd, byte[] body)
    {
        if (ProtocolHandler.Instance == null)
        {
            Debug.LogWarning("[BattleNet] ProtocolHandler 未就绪，丢弃战斗消息: " + cmd);
            return;
        }

        ProtocolHandler.Instance.DispatchRawMessage(cmd, body);
    }

    private void DriveKcp()
    {
        if (_kcp == null)
        {
            return;
        }

        uint now = NowMs();
        _kcp.Update(now);
        _nextKcpUpdate = _kcp.Check(now);
    }

    private void OnTcpConnectionChanged(bool connected)
    {
        if (connected)
        {
            return;
        }

        if (ClientSession.Instance != null && ClientSession.Instance.ShouldPreserveStateOnDisconnect())
        {
            return;
        }

        Disconnect();
    }

    private static uint NowMs()
    {
        return (uint)(Time.realtimeSinceStartup * 1000f);
    }

    private bool UpdateDebugDisconnectSimulation()
    {
        if (!IsDebugTransportSuppressed())
        {
            return false;
        }

        if (Time.realtimeSinceStartup < _debugSilenceEndAt)
        {
            return true;
        }

        _debugSilenceEndAt = -1f;
        Debug.Log("[BattleNet] F10 调试断线静默结束，重新发起 KCP 三次握手");
        LogTrace("kcp_debug_disconnect", new TracePayload
        {
            message = "silence finished, restart handshake",
            state = _state.ToString(),
            host = _battleHost,
            port = _battlePort,
            conv = _battleConv
        });

        StartHandshake("debug F10");
        return true;
    }

    private bool IsDebugTransportSuppressed()
    {
        return _debugSilenceEndAt >= 0f;
    }

    private void LogTrace(string cmd, TracePayload payload)
    {
        string json = JsonUtility.ToJson(payload ?? new TracePayload(), true);
        OnTraceLogged?.Invoke(cmd, json);
    }
}
