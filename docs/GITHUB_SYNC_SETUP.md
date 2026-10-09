# GitHub 登录与加密备份（Android）

## 普通用户如何使用

普通用户不需要注册 GitHub App、填写 Client ID、创建访问令牌或自行构建应用。官方发布版会内置项目的公开 GitHub App Client ID。

1. 在“账户”页点“使用 GitHub 登录”。应用会显示一次性验证码；点“打开 GitHub”，在 GitHub 页面输入验证码并授权，然后返回应用。
2. 在 GitHub 创建一个专用私有仓库，或选择已有的私有仓库。GitHub 的“授权应用”和“安装应用”是两项不同操作；登录只完成了前者。
3. 回到应用，在“账户”页点 GitHub 加密备份的设置按钮，填写仓库所有者、仓库名和至少 12 个字符的备份口令，并选择是否开启每周备份。
4. 应用会打开 GitHub App 安装页。选择自己的账户，选择 **Only select repositories**，只勾选这个专用备份仓库，再返回应用完成检查。
5. 应用会先在手机上加密账本，再上传第一份备份。口令保存在本机 Android 加密存储中；换机恢复时需要记住它。

目标仓库必须是私有仓库，而且 GitHub App 必须安装到该仓库并有内容写入权限。不要选择“All repositories”；只授权专用备份仓库即可。

## 为什么应用需要 Client ID

Client ID 是 GitHub 用来识别“哪个应用正在请求授权”的公开编号，不是用户的密码、访问令牌或 Client Secret。GitHub 的 Device Flow 要求每个应用提供自己的 Client ID。项目维护者为皮卡丘记账创建并配置一次；发布的 APK 会携带这个公开编号，因此普通用户不需要配置或注册自己的 App。安卓客户端不保存 Client Secret。

如果应用页面显示“这个构建版本还没有接入 GitHub 授权服务”，说明安装的是未配置 GitHub 登录的本地开发构建。普通用户应使用项目发布的 APK；从源码自行构建的开发者按下面的维护者说明配置自己的测试 App。

## 项目维护者的一次性配置

只有要发布应用的维护者需要做这些步骤：

1. 在 GitHub 账户 **Settings → Developer settings → GitHub Apps → New GitHub App** 创建公开 GitHub App。主页 URL 可填写本仓库地址，不需要配置 webhook。
2. 启用 **Device Flow**，允许安装到 **Any account**。
3. 只申请应用所需权限：
   - **Contents: write**，用于把加密备份写入用户明确授权的仓库。
   - **Metadata: read**，GitHub 默认授予的仓库只读权限。
   如果现有 App 注册仍启用了 **Repository creation: write**，请移除该权限；当前应用不再通过 GitHub API 创建仓库。
4. 保存 GitHub App 后，记录 **Client ID** 和应用 URL 中的 **slug**。不要把 Client Secret、个人访问令牌或用户的备份口令写入源码。
5. 在本项目 GitHub 仓库打开 **Settings → Secrets and variables → Actions → Variables**，添加：

   | 名称 | 值 |
   | --- | --- |
   | `PIKACHU_GITHUB_APP_CLIENT_ID` | 第 4 步得到的公开 Client ID |
   | `PIKACHU_GITHUB_APP_SLUG` | GitHub App URL 中的 slug |

   正式发布工作流会把这两个公开值编入 APK。它们不是 Actions Secrets。
   GitHub 保留 `GITHUB_` 前缀，因此仓库变量使用 `PIKACHU_GITHUB_` 前缀；工作流会再映射为 Dart define。

## 本地开发构建

从源码运行时，在命令中传入维护者自己注册的测试 App 信息：

```powershell
flutter run `
  --dart-define=GITHUB_APP_CLIENT_ID=Iv23ctLQ3eE96O7iilWP `
  --dart-define=GITHUB_APP_SLUG=pikachu-ledger-backup
```

普通用户不用执行这些命令，也不用阅读或修改本文件才能登录。

## 加密、权限和恢复

- 账单和预算先压缩，再使用 PBKDF2-HMAC-SHA256（600,000 次迭代）派生密钥，并以 AES-256-GCM 加密。仓库只保存密文和解密参数。
- 账单及自定义分类都包含在加密快照中。每次上传覆盖私有仓库内的 `pikachu-ledger/backup.json`；这是单向快照，不会在多台设备间合并记录。
- 私有仓库由用户在 GitHub 创建或选择。安装时可将 GitHub App 限定到专用备份仓库；应用不会要求用户授予对不相关仓库的写入访问。
- 恢复备份前会再次要求口令，并在用户确认后替换本机账单、预算和自定义分类。建议恢复前先导出本地备份。
- 每周后台任务由 Android WorkManager 调度，执行时间可能延迟。GitHub 无法访问时系统会按规则重试；VPN 由用户自行开启。
- 用户可以关闭每周备份、删除备份设置、在 GitHub 撤销应用授权，或删除专用私有仓库。
- 丢失加密口令后，应用无法解密仓库中的账单。请把口令保存在安全的密码管理器中。

## 平台范围

当前交付 Android 版本；iOS 尚未实现或发布。
