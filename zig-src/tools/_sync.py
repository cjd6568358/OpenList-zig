import re

# --- TODO.md 头部 ---
p = 'zig-src/TODO.md'
s = open(p, encoding='utf-8', newline='').read()
NL = '\r\n' if '\r\n' in s else '\n'
old = ('> 最后更新：2026-10-30（网页端上传 network error 根因 = `multipart_enabled` 撒谎，' + NL +
       '> 已改 false 并部署；新增请求体安全阀 `zig.max_upload_mb`（默认 64 MiB）与' + NL +
       '> `/api/*` 未注册路径 501 JSON 兜底，见 STATUS §55/§56。' + NL +
       '> **下一轮主项 = §5.5 分片直传**）')
new = ('> 最后更新：2026-10-30（**分片直传落地**：`/api/fs/multipart/*` 全实现、189pc 直传 + ' + NL +
       '> 全驱动回退、`multipart_enabled` 翻回 true，见 STATUS §57 / §5.5 ✅；' + NL +
       '> 同日早些时候：请求体安全阀 `zig.max_upload_mb`（默认 64 MiB）与' + NL +
       '> `/api/*` 未注册路径 501 JSON 兜底，见 STATUS §55/§56）')
assert old in s, 'o1'
s = s.replace(old, new, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('todo ok')

# --- driver.zig 模块头：补 mp_* 槽位说明 ---
p = 'zig-src/src/driver.zig'
s = open(p, encoding='utf-8', newline='').read()
old2 = ('//! `copy` is **optional**' + NL +
        "//! (`null` = the upstream driver's `Copy` is `NotSupport`), and `space` is" + NL +
        '//! optional too (null = no quota).')
new2 = ('//! `copy` is **optional**' + NL +
        "//! (`null` = the upstream driver's `Copy` is `NotSupport`), `space` is" + NL +
        '//! optional too (null = no quota), and the `mp_*` chunked-direct-upload' + NL +
        '//! quartet is optional as a whole (2026-10-30; implemented by 189pc —' + NL +
        '//! other drivers fall back to the generic spool path, see api.zig' + NL +
        "//! `handleMultipart` / STATUS §57).")
assert old2 in s, 'o2'
s = s.replace(old2, new2, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('driver ok')

# --- MEMORY.md 功能边界：分片上传移出"刻意不做" ---
p = '.workbuddy-ai/memory/MEMORY.md'
s = open(p, encoding='utf-8', newline='').read()
old3 = ('- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / 分片上传 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管整个存储。')
new3 = ('- **刻意不做**：分享 / SSH 公钥 / webauthn / 2FA / LDAP / 多用户·SQLite·SSO / 搜索索引 / 离线下载 / S3·FTP·SFTP·MCP 服务。中心思想：单管理员管整个存储。' + NL +
        '- **分片上传已实现**（2026-10-30，STATUS §57）：网页端 >10MiB 默认走 /api/fs/multipart/*；' + NL +
        '  189pc 直传零落盘无上限，其余驱动落盘回退（上限 ≈ min(tmpfs 剩余, RAM 可用)，当前 ~130MB 浮动）。')
assert old3 in s, 'o3'
s = s.replace(old3, new3, 1)
open(p, 'w', encoding='utf-8', newline='').write(s)
print('memory ok')
