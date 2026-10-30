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

## Relay V2 account connections / 账号连接

ZCode 3.17.1 uses account-owned devices and one-time WebSocket tokens on the official relay. This branch follows the upstream [pairing contract](https://github.com/zai-org/ZCode/blob/a60ba6a7e5a06742270ca605f5d2cc2766afa7e1/docs/web-remote-control/relay-v2-pairing.md) and [CLI browser/poll authorization](https://github.com/zai-org/ZCode/blob/a60ba6a7e5a06742270ca605f5d2cc2766afa7e1/apps/zcode-cli/packages/adapters/src/auth/cli-oauth.ts). It opens the provider page with Safari Services; the app cannot inspect passwords or browser cookies. Only the remote-control session JWT and account identity are kept in device-only Keychain storage. Model-provider access and refresh tokens are discarded. JWTs go only to the fixed official HTTPS origin; custom relays keep their separate legacy credential flow.

新版官方连接需要手机与电脑登录同平台同账号。电脑列表由官方服务器返回；同一电脑多个在线窗口时由用户选择。保存的连接失效后，仅在新的账号设备列表中确认同一电脑恰有一个在线入口时尝试恢复，不自动猜选窗口。聊天缓存、草稿和待确认操作按账号与设备隔离，换设备 SID 不自动重发旧操作。自建部署包仍为 V1，请先检查桌面兼容性。

Run protocol checks from the repository root:

```sh
scripts/tests/run-relay-v2-tests.sh
# Optional live initialization/pending check, without authorizing an account:
scripts/tests/run-relay-v2-tests.sh --live-auth-preflight
```

The iOS test targets include `RelayAccountKeychainTests`, `LocalizationTests`, and `RelayV2OnboardingUITests`. Run them on your own dedicated iOS 26+ Simulator. A separate QA app can use `ZCODE_APP_BUNDLE_ID=dev.example.zcode.relayv2qa` at build time; use ad-hoc signing for Simulator Keychain tests. Provider-page UI tests access official public login pages, so they require network access. They do not sign in. Do not commit generated screenshots, logs, result bundles, authorization URLs, or real pairing information.

真实验收仍需用户在官方页面完成授权，并用已登录的 ZCode 3.17.1 桌面端确认项目、对话、文件、子智能体和重连。协议模拟、登录页展示和真实电脑连接是不同的验收层级；本分支尚未上传或提交商店更新。发布前还需核对隐私说明和审核员登录、连接步骤。

The account vault stores separate Z.ai and BigModel sessions in one device-only Keychain item, with an explicit selected platform. Existing single-account values migrate on the next write. Signing out of one platform preserves the other platform; selecting an account still clears the previous account’s visible workspace state. Closing Safari starts a brief confirmation phase for an in-flight grant; only a verified grant successfully saved to Keychain produces signed-in status. Cancelling in the app cancels the attempt immediately. Pairing and Settings present authorization only from the visible screen, so the hidden onboarding screen cannot dismiss a Settings authorization.

登录后的连接页分别显示平台状态，并把扫码放在电脑列表之前。`--official-account-review` 是仅限 Debug 的界面验收入口，使用独立偏好域、内存账号和虚构内容，不读取或覆盖用户钥匙串。测试截图中的 Demo 登录不能作为真实授权或实连证据。
