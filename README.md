# 🐵 跳跳猴 / TiaoTiaoHou

**中文**　跳跳猴是使用 **Cloudflare Worker** 的 VPN。点一下就接入，网页、YouTube 和游戏走自己的通讯协议，外面默认套 HTTP/3。

**English**　TiaoTiaoHou is a VPN that uses **Cloudflare Workers**. Tap once to connect. Web, YouTube, and games use its own protocol, with HTTP/3 by default.

**中文**　Cloudflare 给用户一份免费额度，可以直接用。Worker 这条路大约每天 10 万次请求，首页能看到今天用了多少。没有自己的服务器也能用；有服务器时可以再自动搭一条落地。

**English**　Cloudflare gives each user a free quota you can use directly. The Worker path is about 100,000 requests a day, and the home screen shows how much you have used. It works without your own server. If you have one, you can add a landing server automatically.

| 系统 / System | 下载 / Download | 中文 | English |
| --- | --- | --- | --- |
| Windows | [tiaotiaohou-Setup.exe](https://github.com/luuuunet/tiaotiaohou/releases/download/windows/tiaotiaohou-Setup.exe) | 双击安装 | Double-click to install |
| macOS | [tiaotiaohou-macos.zip](https://github.com/luuuunet/tiaotiaohou/releases/download/windows/tiaotiaohou-macos.zip) | 解压后打开。若被拦住，到「系统设置 → 隐私与安全性」点仍要打开 | Unzip and open. If blocked, allow it in System Settings → Privacy & Security |
| Android | [tiaotiaohou.apk](https://github.com/luuuunet/tiaotiaohou/releases/download/windows/tiaotiaohou.apk) | 安装后在应用里填 `127.0.0.1:1080`。连上后允许通知，并同意在后台继续运行 | After install, set apps to `127.0.0.1:1080`. Allow notifications and background running |

**中文**　装好后按这四步：

1. 左侧 **搭建**，或在 **节点** 里导入一条已经有的配置。
2. 回到 **连接**，点黄色区域或「开始连接」。
3. **优选 IP** 保持打开。地址慢了，点 **换一个**。
4. 浏览器会跟着走。游戏填 `127.0.0.1:1080`。

**English**　After install:

1. Open **Setup** on the left, or import a node under **Nodes**.
2. Go back to **Connect** and tap the yellow area, or **Connect**.
3. Keep **Best IP** on. If the address is slow, tap **Another**.
4. The browser follows. For games, use `127.0.0.1:1080`.

## 连接 / Connect

![连接页 / Home](docs/home.png)

**中文**　这是平时用的页面。当前节点如果走 Cloudflare Worker，流量就用上面的免费额度。

**English**　This is the page you use every day. If the node goes through a Cloudflare Worker, traffic uses the free quota above.

| 中文 | English |
| --- | --- |
| 上面选节点。点哪一条，下面就换成哪一条。 | Pick a node at the top. The card below switches to it. |
| 绿色标记表示能开什么：网页、橙云网站、游戏 UDP。 | Green marks show what works: web, orange-cloud sites, game UDP. |
| 中间可以测延迟、下载和上传。 | The middle measures ping, download, and upload. |
| **优选 IP** 会自动挑一条更快的 Cloudflare 地址。 | **Best IP** picks a faster Cloudflare address automatically. |
| 晚上变堵就点 **换一个**。正在连接时会按新地址重接。 | If it gets slow at night, tap **Another**. A live connection switches over. |
| 看 YouTube 可以开到 4K。网页优先 HTTP/3，视频不稳时改走 HTTP/2。 | YouTube can play at 4K. Web prefers HTTP/3. Video moves to HTTP/2 when that is steadier. |

## 节点 / Nodes

![节点页 / Nodes](docs/nodes.png)

**中文**　节点可以有很多条，点一条就能连。

**English**　You can keep many nodes. Tap one to connect.

| 中文 | English |
| --- | --- |
| **导入**：贴一条或一批配置。 | **Import**: paste one node or a batch. |
| **添加**：自己填一条。 | **Add**: type one yourself. |
| **测试**：只看这条现在能不能用。 | **Test**: checks whether it works, not how fast. |
| **分享**：可以设过期时间和次数，也可以停用。 | **Share**: set an expiry and a use limit, or turn it off. |
| **订阅**：填地址。失败会再试，手动加的节点不会被冲掉。 | **Subscription**: paste a URL. It retries, and nodes you added by hand stay. |

**中文**　列表里能看到走法：Cloudflare 直连、橙云 + 服务器、Worker + 落地。名字里能认出的国家会显示国旗。

**English**　Each row shows the path: Cloudflare direct, orange cloud + server, or Worker + landing. Recognized country names show a flag.

## 搭建 / Setup

![搭建页 / Setup](docs/setup.png)

**中文**　有服务器就点推荐的 **橙云 + 服务器**。填令牌、域名、公网 IP 和 root 密码，点 **去搭建**，剩下的自动完成。

**English**　If you have a server, use the recommended **Orange cloud + server**. Fill in the token, domain, public IP, and root password, then tap **Set up**. The rest is automatic.

| | 中文 | English | 适合 / For |
| --- | --- | --- | --- |
| 🟠 **橙云 + 服务器** | 域名走橙云，回到你的服务器。不创建 Worker。网页优先 HTTP/3，游戏 UDP 也能开。 | The domain goes through Cloudflare orange cloud and back to your server. No Worker. Web prefers HTTP/3, and game UDP works. | 已经有一台服务器。 / You already have a server. |
| 🧩 **Worker + 服务器** | 网页先到 Worker，再从服务器出去。 | Web hits the Worker first, then leaves from your server. | 橙云回源不稳的时候。 / When orange-cloud origin is unstable. |
| ☁️ **只用 Cloudflare** | 只有域名，没有自己的服务器。普通网站可以打开。游戏 UDP 不行。 | Domain only, no server of your own. Ordinary sites open. Game UDP does not. | 还没有服务器。 / You do not have a server yet. |

**中文**　同一台机器可以两套一起用，请用两个不同域名。有的网站进不去时，到本机打开「打开打不开的网站」。

**English**　One machine can run two setups. Use two different domains. If some sites will not open, turn on **Open blocked sites** under Device.

## 本机 / Device

![本机页 / Device](docs/device.png)

**中文**　这里是开关，改完保存即可。

**English**　These are switches. Change them and save.

| 中文 | English |
| --- | --- |
| **当前节点出口**：Cloudflare 直连、Worker + 落地、橙云 + 服务器、直连 VPS。 | **Exit**: Cloudflare direct, Worker + landing, orange cloud + server, or direct VPS. |
| **优先走更快线路**：不通就自动换。看视频也会自己选。 | **Faster route**: switches automatically when a path fails. Video picks its own. |
| **Cloudflare 优选 IP**：自动挑更快的地址，也可以重新优选或换一个。 | **Best Cloudflare IP**: picks a faster address. You can rescan or try another. |
| **打开打不开的网站**：只用 Cloudflare、没有服务器时再开。改完重启浏览器。 | **Open blocked sites**: use this only with Cloudflare and no server. Restart the browser after. |
| **连接后设置系统代理**：浏览器跟着走。只听 `127.0.0.1`，浏览器 `8080`，SOCKS `1080`。 | **System proxy**: the browser follows. It listens only on `127.0.0.1`, HTTP `8080`, SOCKS `1080`. |
| **国内网站直连**：百度、淘宝不绕出去。 | **China sites direct**: Baidu and Taobao stay off the proxy. |
| **掉线自动换节点**：这条不行就换下一条。 | **Switch node if down**: tries the next node. |
| **断了先拦住**：掉线不走真实网络。自己断开或退出仍会关掉代理。 | **Hold if dropped**: a drop does not leak onto the real network. Disconnect or quit still turns the proxy off. |
| **开机自启**：开机静默连上，换网也会恢复。 | **Start at login**: connects quietly, and reconnects when the network changes. |

## 协议 / Protocol

**中文**　通讯协议是自己的 **RSQ/1**。一条本地连接变成一条加密请求，正文是原始字节，中间不再拆包。

**English**　The protocol is **RSQ/1**. One local connection becomes one encrypted request. The body is the raw bytes, with no extra framing in the middle.

| | 中文 | English |
| --- | --- | --- |
| **HTTP/3** | 默认。QUIC 上的 TLS 1.3，适合打开网页和看视频。 | Default. TLS 1.3 over QUIC, for web and video. |
| **HTTP/2** | UDP 被挡住，或者视频这条路更稳时用。 | Used when UDP is blocked, or when video is steadier on this path. |
| **HTTP/1** | 前两条都不通时的保底。 | The fallback when the other two do not connect. |
