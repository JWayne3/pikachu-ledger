# GitHub 登录与加密备份设置（Android）

## 先决条件

GitHub 备份需要一个 GitHub App Client ID 和 App Slug。Device Flow 不需要在应用里放置 Client Secret。公开发布的维护者应创建并维护项目自己的 GitHub App；个人本地构建也可以使用自己的测试 App。

1. 在 GitHub Developer Settings 中创建 GitHub App，将可安装范围设为 **Any account**（公开 App），启用 **Device Flow**，并授予 `Contents: Read and write` 权限。应用会请求 `offline_access`，以使用短期访问令牌和可刷新的令牌；每周同步可在访问令牌过期后刷新。
2. 安装 GitHub App 时选择 **Only select repositories**，只勾选用于账本备份的那个私有仓库。GitHub 的 App 安装设置决定仓库访问范围；登录授权本身只用于确认用户身份和授权 App 代表用户执行操作。
3. 复制 App 的 Client ID 和 URL slug。分别以构建参数提供：

```powershell
flutter run --dart-define=GITHUB_APP_CLIENT_ID=Iv1.example --dart-define=GITHUB_APP_SLUG=pikachu-ledger
```

正式构建也需要传入同一个公开 Client ID。不要把 Client Secret、个人访问令牌或加密口令写进源码、提交记录或构建日志。

## 在应用中开启备份

1. 在 Android 版应用的“账户”页使用 GitHub 登录，并在 GitHub 授权页面输入一次性验证码。
2. 点“安装或管理 GitHub App”，在 GitHub 页面把 App 安装到你的账户，并仅选择一个**私有仓库**。
3. 在应用中填写该仓库的所有者和仓库名；应用会验证它确为私有仓库并有写入权限。
4. 设置至少 12 个字符的加密口令。应用会把口令写入 Android 加密存储，以便后台任务加密后上传；换机恢复时需要再次输入同一口令。
5. 开启每周自动备份与提醒，并允许 Android 通知权限。
6. 可随时点“立即备份”手动上传，或在新设备上选择“从 GitHub 恢复”。恢复会替换本机所有账单和预算。

## 备份行为与限制

- 账单和预算先压缩，再使用 PBKDF2-HMAC-SHA256（600,000 次迭代）派生密钥，以 AES-256-GCM 加密。仓库中只保存密文和解密所需的算法参数。
- 每次上传都覆盖仓库中的 `pikachu-ledger/backup.json`。这是单向快照备份，不提供多设备自动合并；建议只在一台设备上录入，或在换设备时先恢复再继续使用。
- GitHub 仓库必须保持私有。应用会在保存设置、上传和恢复时检查仓库是否为私有并确认授权具有写入权限。
- Android WorkManager 和通知均由系统调度，执行时间可能延迟，省电策略也可能影响执行。此功能不会启动或检查 VPN；在 GitHub 无法访问的网络下，任务会失败并按系统重试策略再试。
- Android 13 及以上版本需要通知权限才能显示每周提醒。拒绝提醒权限不会阻止已开启的后台备份。
- 丢失加密口令后，应用无法解密云端账本。请把口令记在安全的密码管理器中。

## 平台范围

当前仓库只配置并交付 Android 版本。Flutter 保留未来扩展平台的空间，但本项目尚未实现或发布 iOS 版本。
