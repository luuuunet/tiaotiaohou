# RSQ

自己的 Cloudflare Worker 当 TCP 出口，电脑和手机在本机开 SOCKS5 / HTTP 代理。Windows、Android、macOS 用同一个 Flutter 界面。

这不是一张虚拟网卡。Worker 不能收发原始 IP 包，也没有入站 UDP。能走的是 TCP：浏览器 HTTPS、SSH、一般的 TCP 程序。SOCKS 的 UDP 会直接拒绝。

## 协议

RSQ/1 按 Cloudflare 能终止的流量改过。不在 Worker 里拆多路复用帧，否则免费档 10 毫秒 CPU 会很快被吃完。

一条本地 TCP 对应一条到 Worker 的请求：

```http
POST /rsq/v1/tcp HTTP/3
authorization: Bearer <令牌>
x-rsq-host: example.com
x-rsq-port: 443
x-rsq-v: 1

<上传的原始 TCP 字节>
```

响应体是目标服务器返回的原始 TCP 字节。Worker 用官方的 `connect()` 拨出去，请求体和套接字对拷，中间不再解析。

客户端优先走 HTTP/3（UDP 443）。这条路已经对 `cloudflare.com` 做过握手。UDP 被挡住时自动改走 HTTP/2，Worker 看到的仍是同一个请求。

## 部署 Worker

```powershell
cd worker
npm install
npx wrangler secret put RSQ_TOKEN
npx wrangler deploy
```

令牌用一长串随机字符。本地调试把同一行写进 `worker/.dev.vars`，文件名见 `.dev.vars.example`。不要把令牌提交进仓库。

节点地址是 `https://rsq.lumono.site`。不要用 `workers.dev`，那个域名在国内访问不了。

免费档大约每天 10 万次请求，每次新的 TCP 连接算 1 次。CPU 时间几乎都花在拨号和收尾，转发本身交给运行时。内网地址、本机地址和 25 端口会拒绝。

## 编译客户端

三个平台都要先编 Rust 核心。

Windows：

```powershell
.\tool\build-windows.ps1
```

开发时也可以：

```powershell
cd core
cargo build --release
cd ..\app
flutter run -d windows
```

程序会向上查找 `core\target\release\rsq_core.dll`。

Android 需要 NDK 和 `cargo-ndk`：

```powershell
.\tool\build-android.ps1
```

macOS：

```sh
sh tool/build-macos.sh
```

Xcode 工程会把 `librsq_core.dylib` 拷进 App。沙箱已经打开出站和本机监听。

## 使用

1. 右上角设置里填一次 Worker 地址和令牌，保存。也可以写进 `app/lib/builtin_node.dart` 再编译。
2. 回到主界面，点中间的连接按钮。不用登录。
3. Windows 和 macOS 默认会顺便打开系统代理。浏览器走 `127.0.0.1:8080`，SOCKS 程序走 `127.0.0.1:1080`。

Windows 可以勾选「连接后设置系统代理」。本机地址不会进代理，避免把自己绕进去。代理只监听 `127.0.0.1`。

Android 连接后会挂一个前台通知，避免系统把进程杀掉。系统不会自动把全部 App 导进代理；Firefox 这类能填 SOCKS 的应用，填 `127.0.0.1:1080`。

## 检查

```powershell
cd core
cargo test
cargo test cloudflare_accepts -- --ignored --nocapture
cd ..\worker
node --experimental-strip-types test/guard.test.ts
cd ..\app
flutter test
```
