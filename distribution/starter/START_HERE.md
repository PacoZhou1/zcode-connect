# ZCode Remote 使用与部署指南

把本文件交给电脑上的 AI 助手即可开始。先读“选择连接方式”，不要默认部署服务器。

## 选择连接方式

**官方连接，最少步骤：** 工作电脑已安装 ZCode，打开左下角手机图标 → 移动端远程控制 → 开启；手机 App 添加连接，扫描二维码或粘贴完整链接，选择项目。无需本工具包的服务器部分，无需修改 ZCode。

**自建中转：** 手机 → 你自己的中转服务器 → 运行 ZCode 的工作电脑。服务器仅转发远程控制消息；模型请求、任务、文件仍在工作电脑。需要域名、有效 HTTPS/WSS 入口和持续在线的服务器。支持已验证的 macOS ZCode 3.11.2；启动工具检查程序内容版本，更新后需重新验证兼容性，不能绕过检查。手机不能替代电脑保持运行。

**HTTP 桥接：** 独立任务服务的另一套协议，不是 Relay 地址，也不接管原 ZCode 会话。本包不启用该服务。仅在管理员另行提供兼容服务地址和访问令牌时使用 App 的 HTTP 桥接入口。

## 手机安装

本包提供 iOS 源码，未包含可直接分发的 App Store/TestFlight 安装。已经获得 App 的朋友无需重复编译；其他人需要提供者的 TestFlight 邀请，或用 Xcode 及自己的 Apple 开发签名安装 `ios/ZCodeMobile.xcodeproj` 的 ZCodeMobile scheme。最低 iOS 26，真机安装需设备开启开发者模式。自行签名时，AI 应在构建命令中指定自己的 `DEVELOPMENT_TEAM` 与唯一的 `PRODUCT_BUNDLE_IDENTIFIER`（如 `com.yourname.zcoderemote`），不要沿用作者的签名身份。不要复用提供者的账号、证书、配对库或 API Key。

## 给 AI 助手的执行指令

请按以下顺序完成配置与验证。先核实系统、现有服务、ZCode 版本和用户选择的方式，再执行适用步骤。不得改写 ZCode 安装包、运行数据库或会话文件，不强制退出当前任务，不复制作者私有配置。不要修改与此服务无关的防火墙、反向代理或 DNS。

### A. 自建中转服务器（macOS 工具路径）

1. 用户提供自己的域名/HTTPS origin（如 `https://relay.example.com`），服务器需可被工作电脑和手机访问。安装 Node.js 22+、npm、Python 3、Xcode Command Line Tools（`fs-ext` 原生依赖需要构建工具）。本包压缩与依赖版本已固定，无需自己调整算法。
2. 将整个目录放到固定的本地路径，不放网络盘；先运行 `python3 tools/server.py --origin https://relay.example.com` 做检查，再运行相同命令加 `--install`。脚本安装本机依赖并创建独立 LaunchAgent，监听 `127.0.0.1:28791`，配对库权限 0700，日志 0600；不会覆盖已存在的同名服务。重启服务器后需要用户登录，此脚本不是系统级无人值守服务。
3. 配置域名解析、证书与反向代理。新建独立 Caddy 站点可参考：

   ```caddyfile
   relay.example.com {
       @relay path /zcode/*
       reverse_proxy @relay 127.0.0.1:28791
   }
   ```

   不添加包含查询参数的 access log（配对链接可能带密钥）。已有 Caddy 配置只添加本域名路由，先验证语法再重载，保留原文件供回滚。WSS Upgrade 由 Caddy 自动转发。不要把 28791 直接暴露公网。非默认 HTTPS 端口须同时配置外网端口映射。
4. 检查 `https://relay.example.com/zcode/health`，必须是本 Relay 的 `ok:true`/protocol 1。只有健康检查成功不等于手机能控制。
5. Linux 服务器可用相同 `relay-server` 源码与 CLI，由 AI 配置独立 systemd 服务；`tools/server.py` 仅面向 macOS，不要在 Linux 执行。

### B. 工作电脑的一次性配置

1. 工作电脑先打开过一次 ZCode，然后运行 `python3 tools/desktop.py --mode custom-saved --origin https://relay.example.com`。这是只读计划，不启动或改写 ZCode；它读取当前安装使用的 `~/.zcode/v2/telemetry-state.json` 中既有 deviceMid，只输出设备标识。将结果中的 deviceMID 用于下一步 `YOUR_DEVICE_MID`，不要生成随机 ID。后续工作电脑命令可省略 `--mid`。
2. 在服务器为此 MID 签发短期许可，输出目录须是当前用户所有、0700，目标文件必须不存在：

   ```sh
   node relay-server/src/cli.mjs enroll --state-dir "$HOME/Library/Application Support/ZCodeRemoteRelay" --origin https://relay.example.com --mid YOUR_DEVICE_MID --out /your/private/directory/enrollment.json
   ```

   默认10分钟有效，用安全传输送到工作电脑的0700目录，文件0600；不要贴进聊天、日志或本分享包。
3. 等工作电脑现有任务完成，正常退出 ZCode。先运行 `python3 tools/desktop.py --origin https://relay.example.com --mid YOUR_DEVICE_MID --enrollment-file /private/path/enrollment.json --log-directory /private/log/directory` 查看计划，再加 `--launch` 启动原 ZCode。目录需事先0700。工具不退出现有程序、不改默认数据目录、不自动刷新配对。
4. 工作电脑打开移动端远程控制，由用户点击“刷新二维码”并确认。首次切换会使旧配对失效。通过新二维码/链接打开 HTTPS 连接页，点“复制连接信息”，再粘贴到手机 App，确认显示“自建 Relay · 你的域名”。不要用 HTTP 高级入口。
5. 已配对后，后续使用 `python3 tools/desktop.py --mode custom-saved --origin https://relay.example.com --mid YOUR_DEVICE_MID --log-directory /private/log/directory --launch`，不再需要许可文件。AI 可用 `--mode custom-saved --origin https://relay.example.com --log-directory /private/log/directory --save-launcher /your/path/启动ZCode中转.command` 直接生成可双击启动文件，不加 `--launch`。工具会正确引用路径且不包含许可密钥，避免每次敲命令。直接使用原 Dock 图标不保证加载自建配置。
6. 删除已过期的许可文件，保留用户自己的配对库；不要将它打包分享。返回官方连接要恢复官方启动配置并由用户重新配对。

### C. 手机验收与交付

依次确认：扫码/粘贴识别 → 正确电脑/项目 → 原会话正文 → 切换会话 → 发送一条用户授权的测试消息 → 接收回复 → 后台返回 → Wi-Fi/蜂窝切换。服务器健康、构建成功、安装成功、真实手机收发分别记录。未验项目如实标记。

运行中可发送跟进消息，排队消息右侧“…”打开编辑/引导/取消菜单；只有电脑确认的结果才作为成功。不重复提交不确定状态的命令。

## 已包含的弱网优化

Relay 默认 permessage-deflate level 9、1024 B 阈值、并发4、双端不跨消息共享压缩上下文、1 MiB 解压帧限制。App使用分页正文、轻量元数据、并发读取合并、有效数据存活判断和有限重连；这些代码都在包内，无需魔改 ZCode。真实断网或电脑休眠仍可能断线。队列、设置和恢复行为以电脑当前协议能力为准。

## 排障与回滚

先核实工作电脑开机联网、正确启动方式、远控开启、服务器 health、TLS/WSS。不要反复刷新二维码。VPN是否相关需看实际路由；如确有误走代理，只对用户自己的 Relay 域名设置 DIRECT，而不是放行全部流量。

卸载本包创建的服务：先 `launchctl bootout gui/$(id -u) "$HOME/Library/LaunchAgents/dev.zcode.remote-relay.plist"`，然后仅移除该 plist；保留用户配对库与工作电脑数据。反向代理恢复之前备份。不要删除原 ZCode 数据。

## 包内测试

在 relay-server 目录执行 `node --test tests/cli.test.mjs tests/pairing-helper.test.mjs tests/registry.test.mjs tests/relay.test.mjs tests/tls.test.mjs` 可验证服务、鉴权、压缩兼容和持久化。`npm test` 还会检查本机安装的特定 ZCode 版本，因此仅在匹配版本的工作电脑执行完整套件。测试使用临时目录和本地端口，不连接用户的实际配对库。
