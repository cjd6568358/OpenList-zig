"""SSH 端口转发：本地 127.0.0.1:15399 -> 设备 127.0.0.1:15399。

easytier 隧道对 HTTP 偶发断流但 SSH 稳定，全量 e2e 用它兜底。
"""
import socket
import socketserver
import sys
import threading

sys.path.insert(0, 'tools')
import deploy_device as d

LISTEN = ('127.0.0.1', 15399)


class Handler(socketserver.BaseRequestHandler):
    def handle(self):
        try:
            chan = self.ssh_transport.open_channel(
                'direct-tcpip', ('127.0.0.1', 15399), self.request.getpeername())
        except Exception as e:
            print('open_channel fail:', e)
            return
        try:
            while True:
                r, _, _ = socket.select([self.request, chan], [], [], 120)
                if not r:
                    break
                if self.request in r:
                    data = self.request.recv(1 << 16)
                    if not data:
                        break
                    chan.sendall(data)
                if chan in r:
                    data = chan.recv(1 << 16)
                    if not data:
                        break
                    self.request.sendall(data)
        finally:
            chan.close()
            self.request.close()


class Server(socketserver.ThreadingTCPServer):
    allow_reuse_address = True
    daemon_threads = True


c = d.connect()
Server.ssh_transport = c.get_transport()
print('forwarding 127.0.0.1:15399 -> device:15399 (via SSH)', flush=True)
Server(LISTEN, Handler).serve_forever()
