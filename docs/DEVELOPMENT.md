# Development / 开发说明

[简体中文介绍](../README.md) · [English introduction](../README.en.md)

## 本地构建 / Local build

需要 macOS、支持 iOS 26 SDK 的 Xcode、Swift 6 和 XcodeGen。不要使用作者的签名团队、描述文件或私有设备配置。

You need macOS, Xcode with the iOS 26 SDK, Swift 6, and XcodeGen. Use your own signing team and provisioning profiles when installing on a physical device.

```sh
git clone https://github.com/PacoZhou1/zcode-connect.git
cd zcode-connect/ios
xcodegen generate
open ZCodeMobile.xcodeproj
```

选择 `ZCodeMobile` scheme 和自己的 iOS 26+ 模拟器运行。真机运行时，在 Signing & Capabilities 中选择自己的团队；必要时换用自己唯一的 Bundle ID。不要把签名文件或私钥提交到 Git。

Select the `ZCodeMobile` scheme and your own iOS 26+ simulator. For a physical device, select your team in Signing & Capabilities and use a unique bundle identifier if needed. Never commit signing keys or provisioning profiles.

## 目录 / Layout

| Directory | 内容 / Purpose |
|---|---|
| `ios/` | 原生 iOS App / Native iOS app |
| `bridge/` | 独立 HTTP 桥接与测试 / Separate HTTP bridge and tests |
| `relay-server/` | 自建中转实现 / Self-hosted relay implementation |
| `distribution/starter/` | 部署辅助工具 / Deployment helper tools |
| `mirror/` | 实验模块，不列入当前 App Store 功能宣传 / Experimental module, not advertised as part of the current App Store release |

官方中转与自建中转都需要兼容的桌面运行时。HTTP bridge 是另一种进阶连接方式，不能把一个 HTTP 地址当成原生扫码配对信息。自建服务必须使用自己的域名、TLS 和凭据；先在隔离环境中检查实际桌面版本的兼容性，再接入真实任务。

Both relay options require a compatible desktop runtime. The HTTP bridge is a separate advanced connection mode; an HTTP address is not a native pairing payload. Use your own domain, TLS configuration, and credentials when self-hosting, and verify the actual desktop version in isolation before connecting real tasks.

当前公开的是经过脱敏整理的源码快照，采用 [MIT 许可证](../LICENSE)，不保证与商店二进制一致。安全整理记录见 [公开与安全审查](security/OPEN_SOURCE_REVIEW_20261017.md)。

This privacy-reviewed source snapshot is available under the [MIT License](../LICENSE) and is not guaranteed to match the store binary. See the [publication and security review](security/OPEN_SOURCE_REVIEW_20261017.md).
