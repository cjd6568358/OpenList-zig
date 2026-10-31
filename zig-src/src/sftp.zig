//! SFTP 服务端模块入口。
//!
//! 分层（自下而上）：
//!
//!   - `sftp/protocol.zig` —— v3 线协议编解码。零依赖，不感知 SSH、不感知驱动。
//!   - `sftp/session.zig`  —— 会话状态：句柄表 + 虚拟路径归一化。同样不感知 SSH。
//!   - （待做）`sftp/ssh.zig` —— SSH-2 传输层 + 认证 + channel，把上面的
//!     `protocol.parse` 接到 `std.Io.net` 的连接上。
//!   - （待做）`sftp/handler.zig` —— 把 `PacketType` 分发到 `driver.Driver`
//!     vtable（`open` → `link`、`opendir` → `list`、`write` → `put`…）。
//!
//! 这样切分的原因是测试成本：协议层与会话层能纯单测（不需要密钥、不需要
//! 起服务、不需要真实客户端），只有 SSH 层才需要跑互通回归。

pub const protocol = @import("sftp/protocol.zig");
pub const session = @import("sftp/session.zig");
pub const handler = @import("sftp/handler.zig");
pub const ssh = @import("sftp/ssh.zig");
pub const channel = @import("sftp/channel.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
