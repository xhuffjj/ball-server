using System;
using System.Collections.Concurrent;
using System.Collections.Generic;
using System.IO;
using System.Net.Sockets;
using System.Text;
using System.Threading;
using Google.Protobuf;
using UnityEngine;

/// <summary>
/// TCP 网络管理器 - 单例
/// 负责 TCP 连接、收发数据、协议分包
/// 协议格式: [2字节大端总长度][2字节大端命令名长度][命令名字符串][protobuf序列化体]
/// </summary>
public class NetworkManager : MonoBehaviour
{
    public static NetworkManager Instance { get; private set; }

    public string ServerIP = "192.168.164.129";
    public int ServerPort = 8001;
    [SerializeField] private bool VerboseNetworkLog = false;

    public bool IsConnected => _socket != null && _socket.Connected;
    public bool LastDisconnectWasUserInitiated { get; private set; } = true;

    // 事件：收到服务器消息时触发 (cmd, bodyBytes)
    public event Action<string, byte[]> OnMessageReceived;
    // 事件：发送到服务器消息时触发 (cmd, protoMsg)
    public event Action<string, IMessage> OnMessageSent;
    // 事件：连接状态变化
    public event Action<bool> OnConnectionChanged;

    private TcpClient _socket;
    private NetworkStream _stream;
    private Thread _recvThread;
    private volatile bool _running;
    private int _connectionEpoch = 0;

    // 接收缓冲区
    private byte[] _recvBuf = new byte[65536];
    private byte[] _accumBuf = new byte[131072]; // 累积缓冲区
    private int _accumLen = 0;

    // 主线程消息队列
    private readonly ConcurrentQueue<(string cmd, byte[] body)> _msgQueue
        = new ConcurrentQueue<(string, byte[])>();

    // 连接状态变化队列
    private readonly ConcurrentQueue<bool> _connQueue = new ConcurrentQueue<bool>();

    // 日志队列
    private readonly ConcurrentQueue<string> _logQueue = new ConcurrentQueue<string>();

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

    void Update()
    {
        // 处理连接状态变化
        while (_connQueue.TryDequeue(out bool connected))
        {
            OnConnectionChanged?.Invoke(connected);
        }

        // 处理日志
        while (_logQueue.TryDequeue(out string log))
        {
            Debug.Log(log);
        }

        // 处理收到的消息（分发到主线程）
        while (_msgQueue.TryDequeue(out var msg))
        {
            OnMessageReceived?.Invoke(msg.cmd, msg.body);
        }
    }

    void OnDestroy()
    {
        Disconnect();
    }

    void OnApplicationQuit()
    {
        Disconnect();
    }

    /// <summary>
    /// 连接服务器
    /// </summary>
    public void Connect(string ip, int port)
    {
        if (IsConnected)
        {
            Debug.LogWarning("已经连接，先断开");
            Disconnect(true);
        }

        ServerIP = ip;
        ServerPort = port;

        try
        {
            _socket = new TcpClient();
            _socket.NoDelay = true;
            _socket.Connect(ip, port);
            _stream = _socket.GetStream();

            _accumLen = 0;
            _running = true;
            _connectionEpoch++;
            int currentEpoch = _connectionEpoch;
            _recvThread = new Thread(() => RecvLoop(currentEpoch));
            _recvThread.IsBackground = true;
            _recvThread.Start();

            _connQueue.Enqueue(true);
            Debug.Log($"[Net] 连接成功: {ip}:{port}");
        }
        catch (Exception e)
        {
            Debug.LogError($"[Net] 连接失败: {e.Message}");
            LastDisconnectWasUserInitiated = false;
            _connQueue.Enqueue(false);
        }
    }

    /// <summary>
    /// 断开连接
    /// </summary>
    public void Disconnect(bool requestedByUser = true)
    {
        _running = false;
        LastDisconnectWasUserInitiated = requestedByUser;

        try { _stream?.Close(); } catch { }
        try { _socket?.Close(); } catch { }

        _stream = null;
        _socket = null;
        _accumLen = 0;

        _connQueue.Enqueue(false);
    }

    /// <summary>
    /// 发送协议消息
    /// 打包格式: [2字节总长度][2字节命令名长度][命令名][protobuf body]
    /// </summary>
    public void Send(string cmd, IMessage protoMsg)
    {
        if (!IsConnected)
        {
            Debug.LogWarning("[Net] 未连接，无法发送");
            return;
        }

        try
        {
            byte[] body = protoMsg.ToByteArray();
            byte[] nameBytes = Encoding.UTF8.GetBytes(cmd);
            int nameLen = nameBytes.Length;
            int bodyLen = body.Length;
            int contentLen = 2 + nameLen + bodyLen; // 2字节命令名长度 + 命令名 + body

            byte[] packet = new byte[2 + contentLen]; // 2字节总长度头 + 内容
            // 写入总长度（大端）
            packet[0] = (byte)(contentLen >> 8);
            packet[1] = (byte)(contentLen & 0xFF);
            // 写入命令名长度（大端）
            packet[2] = (byte)(nameLen >> 8);
            packet[3] = (byte)(nameLen & 0xFF);
            // 写入命令名
            Array.Copy(nameBytes, 0, packet, 4, nameLen);
            // 写入 protobuf body
            Array.Copy(body, 0, packet, 4 + nameLen, bodyLen);

            _stream.Write(packet, 0, packet.Length);
            _stream.Flush();
            OnMessageSent?.Invoke(cmd, protoMsg);

            if (VerboseNetworkLog)
                _logQueue.Enqueue($"[Net] 发送: {cmd} ({bodyLen} bytes)");
        }
        catch (Exception e)
        {
            Debug.LogError($"[Net] 发送失败: {e.Message}");
            Disconnect(false);
        }
    }

    /// <summary>
    /// 接收线程
    /// </summary>
    private void RecvLoop(int connectionEpoch)
    {
        try
        {
            while (_running && _socket != null && _socket.Connected)
            {
                int readLen = _stream.Read(_recvBuf, 0, _recvBuf.Length);
                if (readLen <= 0)
                {
                    _logQueue.Enqueue("[Net] 服务器关闭连接");
                    break;
                }

                // 追加到累积缓冲区
                if (_accumLen + readLen > _accumBuf.Length)
                {
                    // 扩容
                    byte[] newBuf = new byte[(_accumLen + readLen) * 2];
                    Array.Copy(_accumBuf, 0, newBuf, 0, _accumLen);
                    _accumBuf = newBuf;
                }
                Array.Copy(_recvBuf, 0, _accumBuf, _accumLen, readLen);
                _accumLen += readLen;

                // 尝试解析完整的包
                ProcessAccumBuffer();
            }
        }
        catch (Exception e)
        {
            if (_running && !IsExpectedDisconnectException(e))
            {
                _logQueue.Enqueue($"[Net] 接收异常: {e.Message}");
            }
        }
        finally
        {
            if (connectionEpoch == _connectionEpoch)
            {
                if (_running)
                {
                    LastDisconnectWasUserInitiated = false;
                }
                _connQueue.Enqueue(false);
            }
        }
    }

    private static bool IsExpectedDisconnectException(Exception e)
    {
        if (e is ObjectDisposedException)
        {
            return true;
        }

        if (e is SocketException socketEx)
        {
            return socketEx.SocketErrorCode == SocketError.Interrupted
                || socketEx.SocketErrorCode == SocketError.OperationAborted
                || socketEx.SocketErrorCode == SocketError.ConnectionAborted
                || socketEx.SocketErrorCode == SocketError.ConnectionReset
                || socketEx.SocketErrorCode == SocketError.Shutdown;
        }

        if (e is IOException ioEx && ioEx.InnerException is SocketException innerSocketEx)
        {
            return IsExpectedDisconnectException(innerSocketEx);
        }

        return false;
    }

    /// <summary>
    /// 处理累积缓冲区，提取完整的数据包
    /// </summary>
    private void ProcessAccumBuffer()
    {
        while (_accumLen >= 2)
        {
            // 读取2字节大端长度头（内容长度，不包含这2字节本身）
            int contentLen = (_accumBuf[0] << 8) | _accumBuf[1];

            if (_accumLen < 2 + contentLen)
                break; // 包体不完整，等待更多数据

            // 提取内容部分
            byte[] content = new byte[contentLen];
            Array.Copy(_accumBuf, 2, content, 0, contentLen);

            // 从累积缓冲区移除已处理的数据
            int consumed = 2 + contentLen;
            _accumLen -= consumed;
            if (_accumLen > 0)
                Array.Copy(_accumBuf, consumed, _accumBuf, 0, _accumLen);

            // 解析内容：[2字节命令名长度][命令名][protobuf body]
            if (contentLen < 2) continue;

            int nameLen = (content[0] << 8) | content[1];
            if (contentLen < 2 + nameLen) continue;

            string cmd = Encoding.UTF8.GetString(content, 2, nameLen);
            int bodyLen = contentLen - 2 - nameLen;
            byte[] body = new byte[bodyLen];
            if (bodyLen > 0)
                Array.Copy(content, 2 + nameLen, body, 0, bodyLen);

            if (VerboseNetworkLog)
                _logQueue.Enqueue($"[Net] 收到: {cmd} ({bodyLen} bytes)");
            _msgQueue.Enqueue((cmd, body));
        }
    }
}
