# 公开与安全审查 / Publication and security review

2026-10-17 · Zcode Connect

## 已完成 / Completed

- 仓库改名为 `PacoZhou1/zcode-connect`；加入中英文用户说明、App Store 入口、正式图标与四张脱敏宣传图。
- 按用户要求从当前树删除 1,339 个历史调试／内部过程文件，包括日志、截图、录屏和验收材料；配套清理可达 Git 历史中的同类路径。
- 测试需要的少量输入另存 `tests/fixtures/`，去掉执行记录与环境信息；不是保留调试日志。Bridge 回归样例已改为公开演示数据。
- 将界面演示数据中的历史项目名、聊天摘录和主机记录替换为完全虚构的示例，并移除原文件的历史版本。
- 修复测试入口中的作者绝对路径；测试输出改用临时目录，避免重新产生已跟踪日志。
- 增加凭据与内部材料忽略规则、可复查的 Gitleaks 配置和安全说明。原开发目录的未提交 App 功能改动不在本次提交中。

## 初始审查 / Initial review

- Gitleaks 8.30.1 扫描初始 46 个可达提交、1,554 个已跟踪文件对应的历史，以及包含 1,577 个文本文件的当前工作区快照；App 内部署工具包的文本另行展开检查。
- 初扫历史 17 处、工作区 18 处命中均为源码 SHA-256 清单，不是 API Key。仅对已复核的完整清单行设置精确例外后，两项扫描为 0 命中。
- 额外 hash 候选为合成认证向量或输入内容摘要；未确认真实活跃凭据，也没有使用候选值访问外部服务。
- 对 226 张历史 PNG/JPG 进行本地 OCR／二维码检查，106 张含本机路径或 `.local` 设备名；0 张识别失败，未检出带配对参数的二维码。9 段录屏未宣称逐帧清审，直接按用户要求删除。
- 新增的四张宣传图和 App 图标共 5 张另行检查，0 张命中私人主机规则；内容为公开演示示例。
- 核查时 GitHub 无 Release 附件、Actions artifacts、PR 或 fork。

## 发布说明 / Publication notes

1. **代码许可证：MIT。** 2026-10-19 经项目所有者明确选择，已加入根目录 [LICENSE](../../LICENSE)。Apple 机模、产品照片与第三方标志不随原创代码重新授权，见 [素材说明](../marketing/ASSETS.md)。
2. **本次公开的源码范围。** GitHub 原有快照早于 App Store 1.1；本地尚有未提交的功能和本地化改动。本次不把它们未经复核地一并推送，也不宣称当前源码与商店二进制完全一致。
3. **只基于清理后的历史继续发布。** 旧工作目录和私有备份含原历史，不能把它们直接合并或推回公共仓库。

2026-10-17 整理期间保持仓库 Private；2026-10-19 按所有者要求发布审查后的历史，并采用 MIT。由于 GitHub 仍缓存旧提交，原仓库保留为私有归档，公开地址使用独立新仓库，只推送已审查历史。仓库外另有私有备份用于恢复。不公开扫描识别正文、QR 内容、账号审核记录、私有连接信息或原始扫描输出。

## 清理后核验 / Post-cleanup verification

- GitHub 两个分支的 SHA、全部可达提交和完整目录树已通过 API 回读，与过滤后的本地镜像一致：35 个可达提交，当前 237 个文件。
- 对全部可达历史再次运行 Gitleaks：0 命中；删除规则覆盖的文件为 0，原界面演示数据的历史 blob 为 0。
- Bridge 完整回归为 128/128 通过；Relay Core、Relay Auth、Relay Adapter 自测及对应 iOS 26 SDK 编译检查通过。最终演示数据与展示文字改动另做 Swift 语法解析，文档本地链接检查通过。
- 此核验覆盖当前分支可达历史，不代表 GitHub 服务端缓存或既有私有克隆已被物理抹除。旧工作目录与恢复备份仍应保持私有。

The remote branches, complete commit lists and file tree match the cleaned mirror. The final history scan has zero findings. No removed artifact paths or original presentation-data blobs remain reachable from those branches. Bridge regression tests pass (128/128); relay self-tests and Swift syntax checks also pass. Existing private clones and server-side unreachable-object retention are outside this verification.

## 复查 / Recheck

```sh
brew install gitleaks
sh scripts/check-public-secrets.sh
```

Gitleaks 检查不是渗透测试，也不代替媒体、归档、依赖版权和源码构建验证。未发现已确认密钥不等于不存在任何敏感信息。处理历史时参照 [GitHub 官方指引](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/removing-sensitive-data-from-a-repository)。

On 2026-10-19, the owner authorized publication under MIT. The original repository remains a private archive because GitHub retained old unreachable commits. A separate repository at the public project URL receives only the reviewed history. Only compact synthetic test inputs and finished marketing assets are retained. The initial secret-scan hits were integrity hashes; no live credential was confirmed or exercised. The published snapshot is not guaranteed to match the store binary. Existing private clones must not reintroduce the old history.
