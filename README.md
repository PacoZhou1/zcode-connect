# ZCode for iOS

原生 SwiftUI / iOS 26 ZCode 远程客户端。以提供的 13 张 iPhone 17 Pro Max 截图与录屏为视觉依据，使用 Apple 原生导航、菜单、弹框、照片/文件选择器和公开 Liquid Glass API。

当前仍在验收中：模拟器与本机隔离桥接的真实任务链路已通；逐像素材质校准、真实官方 Relay 和真机语音/联网验收尚未完成。不要将参考模式、构建成功或离线协议测试理解为这些项目已验收。

## 在本机运行

环境：Xcode 26.6、iOS 26.5 Simulator、Swift 6、XcodeGen。最低部署版本 iOS 26.0。

```sh
cd "/Users/developer/claude code/zcode-native-ios/ios"
xcodegen generate
xcodebuild -project ZCodeMobile.xcodeproj -scheme ZCodeMobile \
  -configuration Debug \
  -destination 'platform=iOS Simulator,id=68D82EC9-8A3E-40F4-8B49-699F97C29347' \
  -derivedDataPath DerivedData CODE_SIGNING_ALLOWED=YES CODE_SIGN_IDENTITY=- build
```

从项目根目录打开截图对照模式：

```sh
python3 scripts/launch-simulator.py --install --reference --screen home
```

可选页面：`home`、`offline`、`goal`、`agents`、`keyboard`、`reasoning`、`permissions`、`attachments`、`advanced`、`files`、`thread-menu`、`rename`、`new`、`voice`。参考内容只在显式 Debug 启动参数启用；`voice` 的演示音量不证明实际识别。第三方键盘不是 App 内容。

当前已运行的桥接保留在原目录 `/Users/developer/claude code/zcode-mobile/bridge`，私有 runtime 没有复制到本工作树。检查状态：

```sh
cd "/Users/developer/claude code/zcode-mobile/bridge"
python3 scripts/background-server.py status
```

连接这套本机验收服务（项目根目录执行）：

```sh
python3 scripts/launch-simulator.py --install \
  --token-file '/Users/developer/claude code/zcode-mobile/bridge/.runtime/pairing-token'
```

不要在运行旧服务时再启动本工作树中的第二个桥接。密钥通过启动环境传递，不进入命令参数或截图。正式 App 从连接页扫描/粘贴官方连接信息，或填写桥接地址和密钥；官方控制器连接可能替换另一台手机，界面会请求确认。

## 已有功能与实际边界

- 主机/项目选择、任务列表与搜索、固定/归档/重命名、会话菜单。
- 新任务、持久正文/附件草稿、稳定输入 ID 重试、流式回复、停止任务、工具步骤与结构化审批/问答。
- 从主机读取模型、思考强度、权限和方案模式；保留主机选定模型，不替换为参考模型。
- 目标和智能体入口由主机活动决定；暂停/恢复只在主机提供能力时出现。不伪造移除目标或未支持的主机命令。
- 照片/文件/相机入口、已发送图片预览、文件树/搜索/预览、工作区变更。PDF 理解取决于主机模型，不声称当前模型支持。
- 麦克风音量驱动波形、中文语音识别、停止留稿/直接发送、取消与后台清理。真实中文 ASR 尚待实际录音验收。
- 官方 Relay 适配层、历史加载、任务列表分页、手动重连、Keychain 凭据；实际官方连接尚未配对验收。
- HTTPS 证书 pin、主机名校验、拒绝重定向、SSE：专用模拟器 TLS fixture 5/5 通过。没有打开 LAN/公网监听，真机远程可达性未验。

当前桥接对既有桌面任务只读；由本客户端创建的任务使用隔离 CLI store，可完整控制。官方 Relay 的真实桌面控制能力须在正式配对后逐项验收。

## 验收与交接

- [持续进展](docs/PROGRESS.md)
- [13 图验收地图](docs/REFERENCE_MAP.md)
- [录屏动效依据与对照](docs/MOTION_REFERENCE.md)
- [前端流程审查](docs/audit/FRONTEND_FLOW_REVIEW.md)
- [分页并发回归](docs/audit/SESSION_PAGINATION_REVIEW.md)
- [后端交接](docs/backend/HANDOFF.md)
- [安全远程连接方案](docs/backend/SECURE_CONNECTION.md)

`evidence/` 保留构建日志、模拟器截图/录屏、独立验收数据。不同编号来自不同构建，最终统一截图仍在更新；不存在“全部像素已一致”的验收结论。源码没有推送 GitHub，也没有上传 TestFlight。真机签名需在 Xcode 中选择自己的开发团队。
