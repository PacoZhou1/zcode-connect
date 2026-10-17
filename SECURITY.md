# Security / 安全说明

Please report security issues privately to **3141791843@qq.com**. Do not post a live pairing link, QR code, API key, password, or signing key in an issue or pull request. Start with the affected version, a short description, and sanitized reproduction steps; arrange a private channel before sending sensitive evidence.

安全问题请先发邮件至 **3141791843@qq.com**。不要在 Issue 或 PR 中提交有效的配对链接、二维码、API Key、密码或签名私钥。先提供版本、问题概述和脱敏复现步骤，需要敏感证据时再确认私下传递方式。

If a credential is exposed, revoke or rotate it first. Deleting the latest file does not remove it from Git history. Keep local credentials, review environments, runtime state, and private debugging evidence outside version control.

如果凭据已经泄露，应先撤销或轮换。仅删除当前文件不会从 Git 历史中移除它。请把本地凭据、审核测试环境、运行状态与私人调试材料留在版本控制之外。

The repository is currently undergoing a pre-publication review. No assertion of vulnerability-free software is made. Check the [review status](docs/security/OPEN_SOURCE_REVIEW_20261017.md) before changing repository visibility.

仓库正在进行公开前审查，不表示软件不存在漏洞。更改仓库可见性前，请先检查 [审查状态](docs/security/OPEN_SOURCE_REVIEW_20261017.md)。
