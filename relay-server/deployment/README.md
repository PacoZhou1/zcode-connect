# Self-hosted relay / 自建中转

For users with a server and deployment experience. The relay forwards the phone's native control protocol to an existing ZCode desktop runtime. It does not host your projects or run model inference.

适合有常驻服务器和部署经验的用户。中转负责转发手机与桌面间的控制消息；项目、任务和模型请求仍由工作电脑上的 ZCode 负责。

## Requirements / 准备

- Node.js 22+, npm, Python 3, and a working C/C++ toolchain for native dependencies.
- A private local state directory owned by the service account, with mode 0700.
- Your own HTTPS domain, trusted TLS certificate, and reverse proxy with WebSocket support.
- A separately verified compatible ZCode desktop runtime.

Install dependencies on the target machine rather than copying `node_modules` from another computer. Keep the listener on loopback; terminate HTTPS/WSS at your reviewed proxy. Do not expose the pairing registry or log URL query strings.

在目标机器安装依赖，不直接复制别的电脑的 node_modules。服务只监听 loopback，由自己的代理提供 HTTPS/WSS。不要公开配对库，也不要记录含凭据的查询串。

## Templates / 模板

The templates and helper scripts in this directory require your own executable paths, service account, domain and state directory. Review them before installation; they do not configure a production server automatically. Never reuse a developer's device identity, pairing credentials, signing material or existing service configuration.

本目录模板需要填写自己的路径、服务账号、域名和状态目录，检查后再安装；它们不会自动把服务器配置成生产环境。不要复用开发者的设备身份、配对凭据、签名材料或服务配置。

Use `node src/cli.mjs --help` from the `relay-server` directory to inspect supported commands. Pairing/enrollment files are private credentials: transfer them through a secure channel and keep them out of Git, screenshots and issue reports.

从 relay-server 目录运行 `node src/cli.mjs --help` 查看命令。登记文件和配对信息属于私有凭据，应安全传递，不放进 Git、截图或公开反馈。

Start with an isolated setup, then verify desktop authentication, phone read/write, reconnect and restart recovery separately. A successful health check alone does not verify the complete connection.

先在隔离环境中配置，再分别检查桌面鉴权、手机读写、断线重连和重启恢复；健康接口正常不代表完整链路已通过。
