// Loaded in memory by NetWatch.ps1; no network configuration is changed.
using System;
using System.Collections.Generic;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Threading.Tasks;
using System.Diagnostics;
using System.Text;

namespace NetWatch {
    public sealed class ProbeResult {
        public string Status;
        public long LatencyMs;
        public int Code;
        public string Detail;
    }
    public static class Probes {
        [DllImport("iphlpapi.dll", SetLastError=true)]
        static extern IntPtr IcmpCreateFile();
        [DllImport("iphlpapi.dll", SetLastError=true)]
        static extern bool IcmpCloseHandle(IntPtr handle);
        [DllImport("iphlpapi.dll", SetLastError=true)]
        static extern uint IcmpSendEcho2Ex(IntPtr handle, IntPtr evt, IntPtr apc, IntPtr context,
            uint source, uint destination, byte[] data, ushort size, IntPtr options,
            IntPtr reply, uint replySize, uint timeout);
        static uint Address(string address) {
            IPAddress ip = IPAddress.Parse(address);
            if (ip.AddressFamily != AddressFamily.InterNetwork) throw new ArgumentException("IPv4 required");
            return BitConverter.ToUInt32(ip.GetAddressBytes(), 0);
        }
        public static Task<ProbeResult> Ping(string source, string target, int timeout) {
            return Task.Run(() => {
                IntPtr h = IntPtr.Zero, buffer = IntPtr.Zero;
                try {
                    uint src = Address(source), dst = Address(target);
                    h = IcmpCreateFile();
                    if (h == new IntPtr(-1)) throw new System.ComponentModel.Win32Exception();
                    buffer = Marshal.AllocHGlobal(512);
                    uint count = IcmpSendEcho2Ex(h, IntPtr.Zero, IntPtr.Zero, IntPtr.Zero,
                        src, dst, new byte[32], 32, IntPtr.Zero, buffer, 512, (uint)timeout);
                    // First three DWORDs of ICMP_ECHO_REPLY: address, status, RTT (both x86/x64).
                    int code = count == 0 ? Marshal.GetLastWin32Error() : Marshal.ReadInt32(buffer, 4);
                    return new ProbeResult { Status = code == 0 ? "OK" : "FAIL",
                        Code = code, LatencyMs = code == 0 ? Marshal.ReadInt32(buffer, 8) : -1 };
                } catch (Exception ex) {
                    return new ProbeResult { Status="ERROR", LatencyMs=-1, Detail=ex.Message };
                } finally {
                    if (buffer != IntPtr.Zero) Marshal.FreeHGlobal(buffer);
                    if (h != IntPtr.Zero && h != new IntPtr(-1)) IcmpCloseHandle(h);
                }
            });
        }
        public static Task<ProbeResult> Dns(string source, string server, string hostname, int timeout) {
            return Task.Run(() => {
                var watch = Stopwatch.StartNew();
                try {
                    byte[] id = Guid.NewGuid().ToByteArray();
                    var bytes = new List<byte>(new byte[] {id[0],id[1],1,0,0,1,0,0,0,0,0,0});
                    foreach (string label in hostname.TrimEnd('.').Split('.')) {
                        byte[] part = Encoding.ASCII.GetBytes(label);
                        if (part.Length == 0 || part.Length > 63) throw new ArgumentException("Invalid DNS label");
                        bytes.Add((byte)part.Length); bytes.AddRange(part);
                    }
                    bytes.AddRange(new byte[] {0,0,1,0,1}); // IN A, recursion desired
                    using (var socket = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp)) {
                        socket.ReceiveTimeout = timeout; socket.SendTimeout = timeout;
                        socket.Bind(new IPEndPoint(IPAddress.Parse(source), 0));
                        socket.Connect(new IPEndPoint(IPAddress.Parse(server), 53));
                        socket.Send(bytes.ToArray());
                        byte[] reply = new byte[4096];
                        int n = socket.Receive(reply);
                        if (n < 12 || reply[0] != id[0] || reply[1] != id[1] || (reply[2] & 128) == 0)
                            throw new Exception("Invalid DNS response");
                        int rcode = reply[3] & 15, answers = (reply[6] << 8) | reply[7];
                        string state = (reply[2] & 2) != 0 ? "TRUNCATED" :
                            rcode != 0 ? "RCODE_" + rcode : answers == 0 ? "NO_ANSWER" : "OK";
                        return new ProbeResult { Status=state, Code=rcode, LatencyMs=watch.ElapsedMilliseconds,
                            Detail="UDP A query; answers=" + answers };
                    }
                } catch (Exception ex) {
                    return new ProbeResult { Status="ERROR", LatencyMs=-1, Detail=ex.Message };
                }
            });
        }
    }
}

