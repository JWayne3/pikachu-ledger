# Android 正式版发布

本仓库的 Android CI 会在提交和 Pull Request 上做静态分析并构建 Debug APK。正式版由推送 `vX.Y.Z` 标签触发，GitHub Actions 使用维护者配置的签名密钥构建 APK，并创建 GitHub Release。

## 一次性配置

### 1. 选定唯一应用包名

正式包名已设为 `io.github.jwayne3.pikachuledger`。发布后不要更改，否则 Android 会把它视为另一个应用，用户也无法直接覆盖升级。只有确定要更换应用身份时，才设置 GitHub 仓库变量 `ANDROID_APPLICATION_ID` 覆盖默认值。

当前工程的 `com.example.ledger_app` 仅用于本地开发。正式版工作流会拒绝这个占位包名。

### 2. 创建并保管签名密钥

使用 JDK 的 `keytool` 在自己可信的电脑上生成密钥。妥善保管密钥文件和密码，并另存一份离线备份；丢失密钥后，无法用同一应用身份发布可覆盖升级的版本。不要把密钥提交到 Git。

```powershell
keytool -genkeypair -v -keystore pikachu-ledger-release.jks -keyalg RSA -keysize 2048 -validity 10000 -alias pikachu-ledger
```

将密钥文件 Base64 编码，然后把以下值添加到 GitHub 仓库的 **Settings → Secrets and variables → Actions**：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Secret | `ANDROID_KEYSTORE_BASE64` | `pikachu-ledger-release.jks` 的 Base64 内容 |
| Secret | `ANDROID_KEYSTORE_PASSWORD` | 密钥库密码 |
| Secret | `ANDROID_KEY_ALIAS` | 上一步使用的 `pikachu-ledger` |
| Secret | `ANDROID_KEY_PASSWORD` | 密钥密码 |
| Variable（可选） | `ANDROID_APPLICATION_ID` | 仅在明确需要覆盖默认包名时设置 |

PowerShell 编码命令：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("pikachu-ledger-release.jks")) | Set-Clipboard
```

### 3. 配置 GitHub 登录

按 [GitHub 登录与加密备份设置](GITHUB_SYNC_SETUP.md) 创建公开 GitHub App，启用 Device Flow，并将其 `Contents: Read and write` 权限限定安装到用户自己选择的私有仓库。将下列非机密值添加为 Actions 仓库变量：

| 类型 | 名称 | 值 |
| --- | --- | --- |
| Variable | `GITHUB_APP_CLIENT_ID` | GitHub App Client ID |
| Variable | `GITHUB_APP_SLUG` | GitHub App URL slug |

不要在客户端或 GitHub Actions 中配置 GitHub App Client Secret；Android Device Flow 不需要它。GitHub App 的 Client ID 和 slug 是公开配置值。

## 发布一个版本

1. 在 `pubspec.yaml` 中递增版本，例如 `0.1.0+1` 改为 `0.2.0+2`。
2. 提交并推送更改到 GitHub。
3. 创建与版本名一致的标签并推送：

   ```powershell
   git tag v0.2.0
   git push origin v0.2.0
   ```

4. 等待 **Actions → Android Release** 完成。工作流会检查标签版本、应用包名和所需的签名/GitHub App 配置，再构建签名 APK 并上传到 GitHub Release。

首次公开发布前，还应确认应用名称、图标和宣传内容具备公开使用授权。若要在 Google Play 上架，需要额外准备 Play App Signing/AAB 发行流程；当前 Release 工作流发布 APK，供用户从 GitHub 下载。

## 本地 release 构建

在 `android/key.properties` 中填写以下内容；该文件和 `.jks`/`.keystore` 文件已加入忽略列表，不会被 Git 跟踪：

```properties
applicationId=io.github.jwayne3.pikachuledger
storeFile=pikachu-ledger-release.jks
storePassword=replace-me
keyAlias=pikachu-ledger
keyPassword=replace-me
```

把密钥文件放在 `android/pikachu-ledger-release.jks`，将包名和 GitHub App 值替换为你配置的值，然后运行：

```powershell
flutter build apk --release `
  --dart-define=GITHUB_APP_CLIENT_ID=Iv1.example `
  --dart-define=GITHUB_APP_SLUG=pikachu-ledger
```

如果尚未配置签名，Gradle 不会拿公开共享的 Android Debug 密钥冒充正式签名；这种本地 release APK 不适合发布或供普通用户升级安装。
