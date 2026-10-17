# Zcode Connect HTTP bridge

This optional Node.js service provides a separate HTTP connection mode for the iOS client. It is not the native ZCode relay protocol and is not required when using the official relay.

这个可选的 Node.js 服务提供独立 HTTP 桥接模式，与原生扫码配对协议不同。使用官方中转时无需部署它。

## Development

Requires Node.js 22.13 or later. Run offline tests with:

```sh
cd bridge
npm test
```

Configure your own local environment before starting a service. Keep tokens, runtime state and private diagnostics outside Git. Start scripts are provided for development; they must not be pointed at another user's desktop data or live pairing environment without their authorization.

配置服务时使用自己的本地环境和凭据；密钥、运行状态与诊断日志不要提交到 Git。开发脚本不得未经授权指向他人的桌面数据或真实配对环境。

See the [project overview](../README.md), [development notes](../docs/DEVELOPMENT.md), and [security policy](../SECURITY.md).
