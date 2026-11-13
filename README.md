# SandboxExplorer · 沙盒管家

一个**独立重写**的 iOS 应用：用 `forcequitOS/worse_query` 的沙盒扩展技术，配合
`hseons/WQManager` 的产品形态，实现「获取当前 App 沙盒目录 + 访问/读取/写入其它
App 数据容器」。整个工程由 **GitHub Actions 在 macOS runner 上构建出 IPA**，
Windows 上无需 Xcode 即可得到成品。

> 本工程不含上游任何源码文件，核心链路按原理重新实现，许可证为
> **GPL-3.0-or-later**（见 `LICENSE` 与 `THIRD_PARTY_NOTICES.md`）。

---

## 1. 功能

| 页面 | 能力 |
|---|---|
| **沙盒** | 显示本 App 的 `Home / Documents / Library / Caches / tmp / App Group 容器` 绝对路径，可复制、直接打开、查看属性；显示 Bundle ID、签名的 App Groups、生效 group、系统版本、已持有扩展数；一键写入示例文件验证读写 |
| **容器** | 用 `fsgetpath` 枚举 `/private/var/mobile/Containers/Data/Application` 等父目录下的 UUID 容器（快速 / 完整扫描、进度与取消、可换父目录、可手动输入绝对路径）；读取 `com.apple.containermanager.identifier` xattr 显示 Bundle ID；点击后自动申请 sandbox extension 并进入文件浏览器 |
| **文件** | 任意目录浏览（目录/文件/链接、大小、权限、mtime、inode）；UTF-8 文本查看、十六进制查看、**编辑并原地写入（保持 inode）**、属性与 xattr 查看、新建文件/文件夹、重命名、删除、另存到 `Documents/Exports`、分享、从「文件」App 导入、释放全部扩展 |
| **工具** | 手动输入路径 → 消费/释放 sandbox extension（自动 / alt / 标准 flags），实时查看 handle 与错误码；查看已持有的扩展列表；诊断日志的查看/复制/导出/清空；GPL 与上游声明 |

**自身沙盒读写不需要任何特殊权限，装上就能用。** 其它 App 数据容器的读写才依赖
worse_query 技术（iOS 26+ 与可用 App Group）。

---

## 2. 技术原理

```
1) App Group 探测
   SecTaskCopyValueForEntitlement("com.apple.security.application-groups")
   → containerURLForSecurityApplicationGroupIdentifier: 取第一个可用 group

2) 交换点（WQBridge.m，相对上游 PoC 的改进）
   Library/Caches ──rename──> .sandboxexplorer-caches-original
   Library/Caches <──symlink── 目标路径
   flock(.sandboxexplorer-query.lock) 保证查询串行
   （崩溃后下次启动会自动恢复原 Caches，绝不递归删除原有内容）

3) 签发扩展
   dlopen("/usr/lib/system/libsystem_containermanager.dylib")
   container_query_create → set_class(7) → set_group_identifiers(group)
   → operation_set_part(3) → operation_set_flags(0x0000000800000000 / 0x0000008000000000)
   → container_query_get_single_result → container_copy_sandbox_token
   → sandbox_extension_consume → 得到 handle
   恢复 Caches；验证 open(target) 不再返回 EPERM；成功的一组 flags 会被记住

4) 容器枚举（WQPathLeak.m）
   在本 App tmp 建探针文件取当前最大 APFS object id（+ 10 万安全余量）
   并行 fsgetpath(buffer, fsid, id) 逐 id 反查路径，前缀匹配出直接子目录
   getxattr(path, "com.apple.containermanager.identifier") → Bundle ID

5) 文件操作（WQFileOps.m）
   普通 POSIX/NSFileManager 调用；遇到 EPERM/EACCES 自动 WQGrant(父目录) 后重试
   handle 用 192 上限的 LRU 缓存，避免触到内核单进程扩展数量限制
```

与上游 PoC 的差异：`rename` 保留 Caches 原内容 + 崩溃恢复、`flock` 串行、
双 flags 自动回退、token 有效性校验、LRU 缓存、非递归删除、纯 ObjC/UIKit
传统 `pbxproj`（objectVersion 56，Xcode 26.6 / 27 均可构建，不依赖 Xcode 27
的 JSON 工程格式）。

---

## 3. 用 GitHub 构建 IPA（Windows 推荐）

工程根目录：`C:\Users\Administrator\Desktop\trae测试\构建ipa\SandboxExplorer\`

### 方式 A — 一键脚本（建仓 → 推送 → 触发 → 下载 IPA）

1. 在 https://github.com/settings/tokens 生成一个带 `repo` **和 `workflow`** 权限的
   token（推送 `.github/workflows/*.yml` 需要 `workflow` 权限）。
2. 在 PowerShell 中执行：

```powershell
cd "C:\Users\Administrator\Desktop\trae测试\构建ipa\SandboxExplorer"
$env:GITHUB_TOKEN = "ghp_xxxxxxxxxxxxxxxxxxxx"
python Scripts\verify_project.py          # 本地静态校验，无 Xcode 也能跑
.\Scripts\push_to_github.ps1 -Repo SandboxExplorer
```

脚本会自动创建私有仓库、提交代码、push 到 `main`、等待 Actions 完成，
并把产物解压到：

```
C:\Users\Administrator\Desktop\trae测试\构建ipa\SandboxExplorer\dist\
    SandboxExplorer-unsigned.ipa
    SandboxExplorer.entitlements.plist
    build-report.txt
    github-artifact.zip
```

也可以直接调用 Python 版（跨平台）：

```bash
python Scripts/github_build.py --repo SandboxExplorer --sign-mode unsigned
```

### 方式 B — 手动推送

```bash
git init -b main
git add .
git commit -m "Build SandboxExplorer IPA"
git remote add origin https://github.com/<you>/SandboxExplorer.git
git push -u origin main
```

进入仓库 **Actions → Build SandboxExplorer IPA → 下载 `SandboxExplorer-IPA-*`**。
`workflow_dispatch` 还可以在页面上直接改 Bundle ID / App Group / 显示名 / 签名模式。

### 方式 C — 本地 macOS 构建（需要 Xcode 26+）

```bash
bash Scripts/configure.sh \
  --bundle-id com.yourname.sandbox \
  --app-group group.com.yourname.sandbox \
  --display-name "沙盒管家"
bash Scripts/build_ipa.sh
```

或直接用 Xcode 打开 `SandboxExplorer.xcodeproj` → 选择真机 → Run。

---

## 4. 可配置项

| 位置 | 参数 | 默认值 | 说明 |
|---|---|---|---|
| `workflow_dispatch` | `bundle_id` | `dev.local.SandboxExplorer` | 必须与描述文件的 App ID 匹配 |
| `workflow_dispatch` | `app_group` | `group.dev.local.SandboxExplorer` | **必须在描述文件中启用** |
| `workflow_dispatch` | `display_name` | `沙盒管家` | 主屏幕名称 |
| `workflow_dispatch` | `sign_mode` | `unsigned` | `unsigned` / `signed` |
| `workflow_dispatch` | `xcode_path` | 空 | 指定 `/Applications/Xcode_27.2.app` 之类的路径 |
| `Config/Project.xcconfig` | 三个标识 | 同上 | `configure.sh` 会统一改写它、entitlements 与 Info.plist |

### 已签名模式（可选）

在仓库 **Settings → Secrets and variables → Actions** 添加：

| Secret | 内容 |
|---|---|
| `IOS_P12_BASE64` | `.p12` 证书的 base64 |
| `IOS_P12_PASSWORD` | 证书密码 |
| `IOS_PROVISION_PROFILE_BASE64` | `.mobileprovision` 的 base64 |
| `IOS_TEAM_ID` | Team ID |
| `KEYCHAIN_PASSWORD` | 任意随机串（CI 临时钥匙串密码） |

生成 base64：

```powershell
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\cert.p12")) | Set-Clipboard
[Convert]::ToBase64String([IO.File]::ReadAllBytes("C:\path\profile.mobileprovision")) | Set-Clipboard
```

工作流会导入钥匙串、安装描述文件、用 `CODE_SIGN_STYLE=Manual` 构建并产出
`SandboxExplorer-signed.ipa`。

---

## 5. 签名与侧载（决定功能能否用，务必读）

- `unsigned` IPA **不能直接安装**，需要用 Sideloadly / AltStore / iOS App Signer /
  爱思助手等用自己的证书重签。产物里的 `SandboxExplorer.entitlements.plist`
  就是给重签工具用的，必须保留其中：

  ```xml
  <key>com.apple.security.application-groups</key>
  <array><string>group.dev.local.SandboxExplorer</string></array>
  ```

- **App Group 需要付费 Apple Developer 账号**。免费账号的 7 天签名不支持
  App Groups，`containerURLForSecurityApplicationGroupIdentifier:` 会返回 nil，
  `WQQueryRaw` 直接返回 `-1`，容器访问全部失效（但本 App 自身沙盒的浏览、
  读取、写入仍然完全可用）。
- 描述文件（Development 或 Ad Hoc）的 App ID 必须勾选 **App Groups** capability
  并包含与你填写的 `app_group` **完全一致**的 group id；否则 token 签不出来。
- 重签工具如果会自己生成 entitlements，记得把上面的 group 合并进去，并同步
  修改 `WQAppGroupIdentifier`（Info.plist）与 `APP_GROUP_ID`（xcconfig），
  三者保持一致。

---

## 6. 运行要求与限制

- 容器访问技术适用范围（按上游 README）：**iOS 26.0 – 26.7.2 / 27.2**。
  更高版本可能被 Apple 封堵。
- `IPHONEOS_DEPLOYMENT_TARGET = 16.0` 只是为了让工程能在各种 iOS 26 SDK 上
  顺利编译；运行时容器功能仍要求 iOS 26+。
- 必须在**真机**上验证：模拟器沙盒基本不生效，不能作为技术有效性证据。
- 删除操作**不递归**（`rmdir` 只允许删空目录），避免误删整个容器子树。
- 写入采用 `open(O_WRONLY|O_TRUNC)` 原地覆盖，保持 inode / 属主 / xattr 不变。
- 容器枚举是 id 暴力反查，完整扫描在 Id 数百万的设备上可能要数分钟，
  支持随时取消。
- 大文件编辑只载入前 2 MB 并会拒绝保存以防截断；大文件请用「另存到我的导出」。

---

## 7. 目录结构

```
SandboxExplorer/
├── .github/workflows/build-ipa.yml        GitHub Actions：选 Xcode → 配置 → 构建 → 打 IPA → 上传
├── Config/
│   ├── Project.xcconfig                  Bundle ID / App Group / 显示名 / 部署目标
│   ├── Info.plist                        SceneDelegate、文件共享、WQAppGroupIdentifier
│   ├── SandboxExplorer.entitlements      App Group entitlement（configure.sh 生成）
│   └── SandboxExplorer.entitlements.template
├── Scripts/
│   ├── configure.sh                      统一改写三个标识
│   ├── build_ipa.sh                      xcodebuild + Payload 打包 + 校验 + 报告
│   ├── verify_project.py                 Windows 本机可跑的工程静态校验
│   ├── github_build.py                   建仓/推送/轮询/下载 IPA 一键脚本
│   └── push_to_github.ps1                PowerShell 薄封装
├── SandboxExplorer.xcodeproj/            传统 pbxproj + 共享 scheme
├── Sources/
│   ├── WQKit.h / WQUI.h                 接口声明
│   ├── WQLog.m / WQBridge.m             日志、环境路径、worse_query 桥接
│   ├── WQPathLeak.m                     fsgetpath 容器枚举 + xattr
│   ├── WQFileOps.m                      读写/创建/删除/复制/属性/格式化
│   ├── main.m / AppDelegate.m / SceneDelegate.m
│   └── Home/Containers/Browser/Editor/Tools ViewController.m
├── LICENSE                              GPL-3.0 全文
└── THIRD_PARTY_NOTICES.md                上游声明
```

---

## 8. 许可

GPL-3.0-or-later。分发 IPA 时必须同时提供完整对应源码、保留 `LICENSE`、
`THIRD_PARTY_NOTICES.md` 以及 App 内「工具 → 技术与上游声明」页面。

本项目与 Apple 无关，也不适用于越狱环境；它利用的是 stock iOS 上的
App Group 容器查询行为。对其它 App 数据的写入会直接改动目标 App 的内容，
操作前请自行确认目标路径。
