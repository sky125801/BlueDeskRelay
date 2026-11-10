import Foundation

/// 一条最小的阻塞式 TCP 连接（IPv4）。
///
/// 为什么不用 Network.framework：`NWConnection` 是回调式的，而本项目的发送侧
/// 是一条专属写线程 + 同步返回成功/失败（见 PhoneLink 的「发送队列」）。
/// 用 POSIX socket 才能保持 `write(_:) -> Bool` 这种同步语义，改动面最小。
final class TcpConnection {

    private var fd: Int32 = -1
    private let lock = NSLock()

    var isOpen: Bool {
        lock.lock()
        defer { lock.unlock() }
        return fd >= 0
    }

    /// 建立连接；`timeout` 内连不上就返回 false（调用方据此回落蓝牙）
    func connect(host: String, port: UInt16, timeout: TimeInterval) -> Bool {
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else {
            NSLog("[TcpConnection] 非法 IPv4 地址：\(host)")
            return false
        }

        let s = socket(AF_INET, SOCK_STREAM, 0)
        guard s >= 0 else {
            NSLog("[TcpConnection] 创建 socket 失败：errno \(errno)")
            return false
        }

        // 对端提前关闭时不要让进程收到 SIGPIPE
        var on: Int32 = 1
        setsockopt(s, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))

        // 非阻塞 connect + poll 超时，否则手机不在同网段时会卡住几十秒
        let flags = fcntl(s, F_GETFL, 0)
        _ = fcntl(s, F_SETFL, flags | O_NONBLOCK)

        let rc = withUnsafePointer(to: &addr) { ptr -> Int32 in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) { sa in
                Darwin.connect(s, sa, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }

        if rc != 0 {
            guard errno == EINPROGRESS else {
                NSLog("[TcpConnection] connect \(host):\(port) 失败：errno \(errno)")
                Darwin.close(s)
                return false
            }
            var pfd = pollfd(fd: s, events: Int16(POLLOUT), revents: 0)
            guard poll(&pfd, 1, Int32(timeout * 1000)) > 0 else {
                NSLog("[TcpConnection] connect \(host):\(port) 超时")
                Darwin.close(s)
                return false
            }
            var err: Int32 = 0
            var len = socklen_t(MemoryLayout<Int32>.size)
            getsockopt(s, SOL_SOCKET, SO_ERROR, &err, &len)
            guard err == 0 else {
                NSLog("[TcpConnection] connect \(host):\(port) 失败：SO_ERROR \(err)")
                Darwin.close(s)
                return false
            }
        }

        _ = fcntl(s, F_SETFL, flags)          // 恢复阻塞
        setsockopt(s, IPPROTO_TCP, TCP_NODELAY, &on, socklen_t(MemoryLayout<Int32>.size))

        lock.lock()
        fd = s
        lock.unlock()
        return true
    }

    /// 写完整块数据（阻塞）。返回 false 表示链路已不可用。
    func write(_ data: Data) -> Bool {
        lock.lock()
        let s = fd
        lock.unlock()
        guard s >= 0 else { return false }

        var sent = 0
        return data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return true }
            while sent < data.count {
                let n = send(s, base.advanced(by: sent), data.count - sent, 0)
                if n > 0 {
                    sent += n
                    continue
                }
                if n < 0 && errno == EINTR { continue }
                if n < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) {
                    usleep(2_000)
                    continue
                }
                NSLog("[TcpConnection] 写入失败：errno \(errno)")
                return false
            }
            return true
        }
    }

    /// 读一批数据。返回 nil 表示连接已关闭；空 Data 表示这次只是超时（没有数据）。
    func readSome(timeout: TimeInterval) -> Data? {
        lock.lock()
        let s = fd
        lock.unlock()
        guard s >= 0 else { return nil }

        var pfd = pollfd(fd: s, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pfd, 1, Int32(timeout * 1000))
        if ready == 0 { return Data() }
        if ready < 0 { return errno == EINTR ? Data() : nil }

        var buf = [UInt8](repeating: 0, count: 256 * 1024)
        let n = recv(s, &buf, buf.count, 0)
        if n < 0 { return errno == EINTR || errno == EAGAIN ? Data() : nil }
        if n == 0 { return nil }
        return Data(buf[0..<n])
    }

    func close() {
        lock.lock()
        let s = fd
        fd = -1
        lock.unlock()
        if s >= 0 { Darwin.close(s) }
    }
}
