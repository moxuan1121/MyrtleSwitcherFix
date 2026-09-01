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

Myrtle 自带的“全屏打开”会先复用窗口关闭流程，再调用 `launchApplicationWithIdentifier:suspended:`。不同界面存在两条入口：`-[MyrtleViewController MT_llIIIlIIlIlllIlIIIII]` 和实际窗口流程使用的 `+[MyrtleHostCore MT_IllIlllIIllIllIIIIII:]`。插件同时 Hook 两者，并兼容启动调用发生在 `currentBundleID` 清空之前或之后，因此能区分“关闭 B 返回 A”和“全屏进入 B”：前者前置 A，后者保持 B 位于后台第一张。

点击生成的卡片仍由 SpringBoard 按系统方式全屏打开应用。稳定版在预处理阶段完全裁掉诊断日志调用及其参数求值，不查询日志文件、不创建诊断字符串、不执行磁盘写入；已经验证的卡片登记、排序、关闭与全屏时序保持不变。

## 键盘避让

`0.5.1` 继续直接使用 Myrtle 自身的键盘显示、隐藏与圆盘构造入口，不注册全局键盘监听，也不注入应用进程：

1. Myrtle 确认应用内键盘与手柄相交并保存原位置后，插件按固定的 360 pt 竖屏键盘高度计算手柄位置；
2. 仅为当前 Myrtle `handleHitView` 实例建立位置保护，键盘存在期间只约束纵坐标，保留 Myrtle 原有的横向移动、缩放和透明度动画；
3. 圆盘构造使用与手柄相同的中心高度，避免打开或收起圆盘时先向下跳再返回；
4. 键盘隐藏时临时放行 Myrtle 的原始恢复流程，手柄正常回到键盘出现前的位置；
5. 不处理 Spotlight，不包含 16:9 或应用侧兼容代码，不运行定时器或常驻轮询。

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
- 最终 dylib 不得包含旧日志路径或代表性诊断格式字符串，避免误发带日志构建。

## 安装与卸载安全

- 只注入 `com.apple.springboard`；
- 不包含安装或卸载维护脚本；
- 不删除、覆盖、停止、更新或卸载 ElleKit；
- 不调用 `apt autoremove`；
- 安装或卸载后手动 Respring；
- 卸载时只选择 `com.moxuan.myrtleswitcherfix`，不要自动清理依赖；新包通过 Debian 的 `Conflicts`/`Replaces` 正常替换旧标识符 `com.local.myrtleswitcherfix`，不会处理 ElleKit。

## 版本说明

- `0.5.4.2`：删除无键盘状态下的手柄 720 pt 底部限制、手柄拖动 Hook 与启动时边界修正；保留应用内固定 360 pt 键盘高度、18 pt 间距、圆盘高度保持和键盘隐藏后的原位恢复。
- `0.5.4.1`：在 0.5.4 稳定功能和时序完全不变的前提下，删除已被预处理裁掉的旧日志宏、日志调用及其空分支，让编译器重新覆盖全部有效源码；不增加 Hook、定时任务、文件 I/O 或后台轮询。
- `0.5.4`：稳定化 Myrtle 1.4.1 的 iOS 15 分屏窗口触摸路由。无键盘时将窗口外触摸交还给桌面或后方全屏 App；键盘存在时保留 Myrtle 原生的窗口外关闭行为。窗口冷启动、拖动、缩放以及手柄吸附复位均在 Myrtle 原生完整坐标环境中完成，稳定后才按最终可见区域建立 WindowServer 边界。删除全部场景快照、诊断计数、日志格式化和磁盘写入；静止状态无轮询、无定时器、无 Bundle ID 持续获取，并为跨窗口会话的延迟吸附任务增加代次失效保护。
- `0.5.1`：稳定化已经通过真机验证的固定高度应用内键盘避让；在 Myrtle 手柄实例的最终位置入口约束纵坐标，使圆盘打开、收起期间始终保持在键盘上方，同时在键盘隐藏时放行原始位置恢复。无 Spotlight、16:9、应用侧注入、日志或常驻轮询。
- `0.5.0`：新增只在 SpringBoard 内工作的固定 360 pt 应用内键盘避让基础实现，并保留 Myrtle 的键盘资格判断与原位置保存/恢复逻辑。
- `0.4.4.1`：基于 0.4.4 稳定逻辑制作无日志性能版；编译期裁掉全部诊断日志调用、参数求值和文件 I/O，并删除一次性的能力探测日志，不修改卡片时序、Hook 范围或卸载行为。
- `0.4.4`：删除打开分屏后固定等待 0.35 秒且要求窗口仍存活的限制；在 0、0.08、0.20、0.35 秒按需尝试真实 Scene 卡片登记，首次成功后停止后续尝试。极快关闭时仍补充 B 卡片，但不加入 B 的前置队列，并再次前置底层 A，保证最终为 `[A, B, ...]`。
- `0.4.3`：根据 0.4.2 真机日志确认部分全屏动作不调用 Myrtle 的两个显式启动帮助方法，而是在清空 Bundle ID 前由 SpringBoard 连续发布模型变化；在模型回调中比对系统 `_currentAppLayout` 与 Myrtle 当前 Bundle ID，系统已切换到 B 时直接标记全屏转换，消除无旧卡片应用等待系统最终登记后才回到首位的延迟。
- `0.4.2`：根据 0.4.1 真机日志确认 ViewController 全屏入口虽成功 Hook 但测试按钮未经过它；新增实际命中的 MyrtleHostCore 启动入口，并加入 0.75 秒最近关闭关联和 0.08 秒普通关闭判别窗口，覆盖 Myrtle 在启动调用前后清空 Bundle ID 的两种顺序。
- `0.4.1`：识别 Myrtle 自带的全屏启动入口，避免全屏进入 B 时被普通关闭逻辑误判为返回 A；全屏转换会立即保持 B 的后台最近顺序，并让过期的 A 前置任务失效。
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
