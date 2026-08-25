# Myrtle Switcher Fix

为 Myrtle 1.4.1 补充 iOS 15 App Switcher 登记，目标环境：

- iOS 15.6
- iPhone 13 Pro Max
- Dopamine RootHide
- `iphoneos-arm64e` Debian 包
- 包内原生 `arm64e` Mach-O

## 原理

对 Myrtle 1.4.1 的 Objective-C 元数据和选择器交叉引用分析确认：真正的分屏入口位于 `MyrtleHostManager`；大型宿主创建方法在窗口和 Host View 建立过程中写入 `currentBundleID`，关闭方法 `MT_IlllIIIlIIIlIlllIIIl::` 会清空该值并移除 Host View。本插件因此直接 Hook Myrtle 自身的提交点，不再猜测通用 FrontBoard Scene 初始化类：

1. Hook `-[MyrtleHostManager setCurrentBundleID:]`，取得 Myrtle 已确认的目标 Bundle ID；
2. 优先复用 iOS 15 `recentAppLayouts` 中的 `SBAppLayout`，让已有卡片移动到最前；
3. 没有旧卡片时，通过兼容工厂创建布局并加入 `SBAppSwitcherModel`；
4. Hook 后台卡片删除入口，仅当卡片与 Myrtle 当前 Bundle ID 相同时调用 Myrtle 自己的关闭方法。

点击生成的卡片仍由 SpringBoard 按系统方式全屏打开应用。诊断日志会写入 `/var/mobile/Library/Preferences/com.local.myrtleswitcherfix.log`，不依赖系统日志流。

## 构建

```sh
export THEOS=/path/to/roothide-theos
make clean package FINALPACKAGE=1
```

关键配置：

```make
ARCHS = arm64e
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
DEB_ARCH = iphoneos-arm64e
```

GitHub Actions 会自动验证：

- 外层包架构必须为 `iphoneos-arm64e`；
- 包内 Mach-O 必须为原生 `arm64e`，与 A15 SpringBoard 一致；
- Mach-O 的原始 CPU subtype 必须为 `0x80000002`（Apple 新 arm64e ABI），发现 Linux 旧 ABI `0x00000002` 时立即拒绝产物；
- 不得存在 `preinst`、`postinst`、`prerm`、`postrm`；
- 必须保留 `mobilesubstrate`/ElleKit 兼容依赖。

## 安装与卸载安全

- 只注入 `com.apple.springboard`；
- 不包含安装或卸载维护脚本；
- 不删除、覆盖、停止、更新或卸载 ElleKit；
- 不调用 `apt autoremove`；
- 安装或卸载后手动 Respring；
- 卸载时只选择 `com.local.myrtleswitcherfix`，不要自动清理依赖。

## 版本说明

- `0.3.4`：不再猜测 Model 所有者类名；直接 Hook `-[SBAppSwitcherModel init]` 并保存 SpringBoard 创建的真实实例，同时记录真机 Model 方法。
- `0.3.3`：根据设备日志改为从 `SBMainSwitcherControllerCoordinator` 取得其持有的 `SBAppSwitcherModel`；iOS 15 的 Model 没有 `sharedInstance`。删除卡片 Hook 同步迁移到 Coordinator。
- `0.3.2`：改用 macOS/Xcode 工作流生成 Apple 新 arm64e ABI，并增加 CPU subtype 强制检查；不依赖可能造成系统不稳定的 `oldabi`。
- `0.3.1`：为解决 0.3.0 纯 arm64 不注入而恢复 arm64e，但 Linux 工具链生成的是旧 ABI；虽然 ElleKit 可以映射 dylib，却在首个 Objective-C 常量字符串 `retain` 时崩溃，禁止安装。
- `0.3.0`：直接 Hook Myrtle 1.4.1 的 HostManager 生命周期，并联动后台卡片删除与 Myrtle 关闭入口。
- `0.2.1`：枚举实际 Scene Host 类，不再依赖写死的类名或调用来源解析。
- `0.2.0`：首次正式 Hook 版，因 Host 类名未命中而不生效。
- `0.1.2`：文件日志诊断版，已停止使用。
- `0.1.1`：首次 arm64 诊断版，已停止使用。
- `0.1.0`：旧初始化器传入了无效对象并在 `isEqualToString:` 崩溃；崩溃报告同时证明 arm64e dylib 已被 ElleKit 正常注入。产物已撤回，禁止安装。
