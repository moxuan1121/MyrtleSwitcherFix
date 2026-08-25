# Myrtle Switcher Fix Diagnostics

这是针对以下环境的第一阶段只读诊断项目：

- iOS 15.6
- iPhone 13 Pro Max / arm64e
- Dopamine RootHide
- Myrtle 1.4.1

当前 `0.1.0` 版本只记录运行时信息，不添加或删除后台卡片，不终止应用，也不修改 Myrtle 状态。

## GitHub Actions 自动打包

仓库包含 `.github/workflows/build-roothide.yml`。每次推送到 `main` 会自动构建，也可以在 GitHub 的 Actions 页面手动运行 `Build RootHide arm64e package`。

工作流使用 RootHide 官方 Theos 安装脚本，并在上传构建产物前强制验证：

- Debian 包架构必须是 `iphoneos-arm64e`；
- 成品必须只有一个 `.deb`；
- 包内不得包含 `preinst`、`postinst`、`prerm` 或 `postrm`；
- 必须保留 `mobilesubstrate`（ElleKit 兼容接口）依赖；
- 同时生成 `SHA256SUMS.txt`。

验证通过的 `.deb` 位于对应工作流运行页面的 Artifacts 区域，产物名称为 `MyrtleSwitcherFix-iOS15.6-RootHide-arm64e`。

## 安全边界

- 只注入 `com.apple.springboard`。
- 不包含 `preinst`、`postinst`、`prerm` 或 `postrm` 维护脚本。
- 安装和卸载均不会删除、覆盖、停用、重装或重启 ElleKit。
- 包只依赖 ElleKit 提供兼容实现的 `mobilesubstrate` 接口；卸载本包不会卸载依赖包。
- 不运行 `apt autoremove`，不修改任何软件源或包管理配置。
- 日志是本包唯一创建的持久数据，位置为：
  `/var/mobile/Library/Logs/MyrtleSwitcherFix.log`
- 为避免误删用户数据，卸载时故意不自动删除日志。确认不再需要后可手动删除这一个文件。

## 使用 RootHide Theos 编译

确保使用支持 RootHide scheme 的 Theos/toolchain，然后在项目目录运行：

```sh
export THEOS=/path/to/theos
make clean package FINALPACKAGE=1
```

项目已设置：

```make
ARCHS = arm64e
TARGET = iphone:clang:15.6:15.0
THEOS_PACKAGE_SCHEME = roothide
```

生成的包应为 `iphoneos-arm64e` 架构。安装或卸载后请手动执行一次用户熟悉且确认安全的 Respring；本包不会自行操作 ElleKit 服务。

## 复现步骤

1. 安装诊断包并手动 Respring。
2. 确保待测 App 当前不在上滑后台菜单中。
3. 使用 Myrtle 分屏打开该 App，操作几秒。
4. 打开上滑后台菜单。
5. 关闭 Myrtle 分屏窗口。
6. 再选择一个原本已有后台卡片的 App，用 Myrtle 打开一次。
7. 导出 `/var/mobile/Library/Logs/MyrtleSwitcherFix.log`。

日志包含类名、方法签名、Scene Bundle ID 和调用映像，不会主动读取应用内容、账号、剪贴板或网络数据。发送前仍建议自行检查日志内容。

## 卸载

在包管理器中只卸载：

```text
Myrtle Switcher Fix Diagnostics
```

不要选择自动清理未使用依赖，也不需要重新安装或卸载 ElleKit。卸载完成后手动 Respring 即可。
