# wopan-sdk-go v0.1.5 源码快照（对照参考，非本仓库代码）

## 这是什么

外部 Go 模块 [`github.com/OpenListTeam/wopan-sdk-go`](https://github.com/OpenListTeam/wopan-sdk-go)
v0.1.5 的源码快照。上游 OpenList 的 `drivers/wopan/`（本仓库 Go 树内，仅 4 个小文件）
只是薄封装——HTTP 请求、header 签名、AES 加解密、上传全部在此外部 SDK 里；
该 SDK 是 Go module 依赖，**不在本仓库树内**（本机 Go mod cache 已不可用，
故本快照是目前唯一的本地副本）。

## 为什么在这里

Zig 驱动 `src/drivers/wopan.zig` 是「SDK + driver」两层的合并移植，逐行对齐本快照。
2026-10-17 修通 WoPan 时（`docs/STATUS.md` §36B）对照本源码挖出三个真 bug：
api-user body 缺 `clientId`、响应 DATA 从未被解密、解密 key 写死 wohome。
`wopan.zig` 注释里的 `SDK request.go:42` 等行号引用即指本目录，留档备查。

## 使用须知

- **没有任何构建或工具编译这些文件**——纯参考资料，Zig 侧与 Go 侧均不引用其路径。
- 快照为**部分拷贝**（调试时按需复制）：缺 `consts.go`、`req_body.go`、
  `crypto.go`、`api-user.go`（后两者仅有 _test.go）。完整模块可从上游获取：
  `go mod download github.com/OpenListTeam/wopan-sdk-go@v0.1.5`，或 GitHub 网页。
- 移植已完成并真机验证（`wopan.zig` 头部有无缺口声明）。如无新需求可整个目录删除，
  git 历史保留全部内容。
