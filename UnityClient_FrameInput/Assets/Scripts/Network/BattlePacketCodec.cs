using System;
using System.Text;
using Google.Protobuf;

/// <summary>
/// 战斗链路业务包编解码。
/// KCP 自带消息边界，这里只需要处理 [2字节命令名长度][命令名][protobuf body]。
/// </summary>
public static class BattlePacketCodec
{
    public static byte[] Encode(string cmd, IMessage message)
    {
        if (string.IsNullOrEmpty(cmd))
        {
            throw new ArgumentException("battle packet cmd is empty", nameof(cmd));
        }

        byte[] nameBytes = Encoding.UTF8.GetBytes(cmd);
        if (nameBytes.Length > ushort.MaxValue)
        {
            throw new ArgumentException("battle packet cmd is too long", nameof(cmd));
        }

        byte[] body = message != null ? message.ToByteArray() : Array.Empty<byte>();
        byte[] packet = new byte[2 + nameBytes.Length + body.Length];
        packet[0] = (byte)(nameBytes.Length >> 8);
        packet[1] = (byte)(nameBytes.Length & 0xFF);
        Buffer.BlockCopy(nameBytes, 0, packet, 2, nameBytes.Length);
        if (body.Length > 0)
        {
            Buffer.BlockCopy(body, 0, packet, 2 + nameBytes.Length, body.Length);
        }

        return packet;
    }

    public static bool TryDecode(byte[] buffer, int length, out string cmd, out byte[] body, out string error)
    {
        cmd = null;
        body = null;
        error = null;

        if (buffer == null)
        {
            error = "buffer is null";
            return false;
        }

        if (length < 2)
        {
            error = "packet too short";
            return false;
        }

        int nameLength = (buffer[0] << 8) | buffer[1];
        int bodyLength = length - 2 - nameLength;
        if (nameLength <= 0 || bodyLength < 0)
        {
            error = "invalid packet lengths";
            return false;
        }

        cmd = Encoding.UTF8.GetString(buffer, 2, nameLength);
        body = new byte[bodyLength];
        if (bodyLength > 0)
        {
            Buffer.BlockCopy(buffer, 2 + nameLength, body, 0, bodyLength);
        }

        return true;
    }
}
