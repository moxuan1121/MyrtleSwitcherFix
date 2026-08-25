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
2. 从 iOS 15 的 `SBMainSwitcherViewController.recentAppLayouts` 查找现有 `SBAppLayout`，并通过 `_addAppLayoutToFront:` 移到最前；
3. 没有旧卡片时，从 Myrtle 正在托管的真实 Scene 取得 identifier，创建对应 `SBDisplayItem`，再通过 `addAppLayoutForDisplayItem:completion:` 写入正常最近任务模型；
4. Hook 后台卡片删除入口，仅当卡片与 Myrtle 当前 Bundle ID 相同时调用 Myrtle 自己的关闭方法。

点击生成的卡片仍由 SpringBoard 按系统方式全屏打开应用。诊断日志会写入 `/var/mobile/Library/Preferences/com.moxuan.myrtleswitcherfix.log`，不依赖系统日志流。

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

- 包标识符必须为 `com.moxuan.myrtleswitcherfix`，并包含旧标识符的安全迁移声明；
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
- 卸载时只选择 `com.moxuan.myrtleswitcherfix`，不要自动清理依赖；新包通过 Debian 的 `Conflicts`/`Replaces` 正常替换旧标识符 `com.local.myrtleswitcherfix`，不会处理 ElleKit。

## 版本说明

- `0.4.0`：包标识符改为 `com.moxuan.myrtleswitcherfix`，日志文件同步使用新标识符；声明替换旧包 `com.local.myrtleswitcherfix`，避免迁移时两个插件同时注入 SpringBoard。
- `0.3.9`：为后台排序重试增加批次代号和 10 秒硬截止，已有卡片与新建卡片统一清理待排序状态；新的 Myrtle 状态变化会取消旧的“返回主应用”延迟任务；诊断日志达到 1 MiB 后自动重置，避免长期无限增长。
- `0.3.8`：打开分屏应用时记录其下方的主应用；Myrtle 关闭分屏并清空 Bundle ID 时，立即将主应用已有卡片前置，使关闭 B 返回 A 后无需等待系统延迟即可得到 `[A, B, ...]`。
- `0.3.7`：删除会生成临时、幽灵及重复卡片的 `_insertCardForDisplayIdentifier:` 测试入口；改用 Myrtle 实际 Scene identifier 创建 `SBDisplayItem`，再调用生产接口 `addAppLayoutForDisplayItem:completion:`。待排序状态改为有序队列，并 Hook 用户直接删除卡片的回调。
- `0.3.6`：确认无卡片插入会异步落入模型后，记录最新 Myrtle Bundle ID，并在模型变化、后台界面出现及定时重试时调用已验证有效的 `_addAppLayoutToFront:`，保证最终索引为 0。
- `0.3.5`：按 iOS 15.5/15.6 的真实类结构改用 `SBMainSwitcherViewController` 单例；严格分离已有卡片前置与无卡片插入，并在调用后验证真实索引。删除卡片 Hook 也迁移到该类。
- `0.3.4`：尝试 Hook `-[SBAppSwitcherModel init]`；真机日志证明模型并不经过这个入口，因此未能获得实例。
- `0.3.3`：根据设备日志改为从 `SBMainSwitcherControllerCoordinator` 取得其持有的 `SBAppSwitcherModel`；iOS 15 的 Model 没有 `sharedInstance`。删除卡片 Hook 同步迁移到 Coordinator。
- `0.3.2`：改用 macOS/Xcode 工作流生成 Apple 新 arm64e ABI，并增加 CPU subtype 强制检查；不依赖可能造成系统不稳定的 `oldabi`。
- `0.3.1`：为解决 0.3.0 纯 arm64 不注入而恢复 arm64e，但 Linux 工具链生成的是旧 ABI；虽然 ElleKit 可以映射 dylib，却在首个 Objective-C 常量字符串 `retain` 时崩溃，禁止安装。
- `0.3.0`：直接 Hook Myrtle 1.4.1 的 HostManager 生命周期，并联动后台卡片删除与 Myrtle 关闭入口。
- `0.2.1`：枚举实际 Scene Host 类，不再依赖写死的类名或调用来源解析。
- `0.2.0`：首次正式 Hook 版，因 Host 类名未命中而不生效。
- `0.1.2`：文件日志诊断版，已停止使用。
- `0.1.1`：首次 arm64 诊断版，已停止使用。
- `0.1.0`：旧初始化器传入了无效对象并在 `isEqualToString:` 崩溃；崩溃报告同时证明 arm64e dylib 已被 ElleKit 正常注入。产物已撤回，禁止安装。
