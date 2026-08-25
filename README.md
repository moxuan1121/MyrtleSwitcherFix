# Myrtle Switcher Fix

为 Myrtle 1.4.1 补充 iOS 15 App Switcher 登记，目标环境：

- iOS 15.6
- iPhone 13 Pro Max
- Dopamine RootHide
- `iphoneos-arm64e` Debian 包
- 包内 `arm64` Mach-O

## 原理

Myrtle 会通过 `FBSceneLayerHostContainerView initWithScene:debugDescription:` 托管应用 Scene，但没有把目标应用布局加入 `SBAppSwitcherModel`。本插件只在该调用的返回地址确认为 `Myrtle.dylib` 时：

1. 从 Scene/client process 取得 Bundle ID；
2. 取得对应 `SBApplication`；
3. 创建正常的全屏 `SBDisplayLayout`；
4. 调用 `SBAppSwitcherModel addToFront:`。

点击生成的卡片仍由 SpringBoard 按系统方式全屏打开应用。上滑卡片时由系统终止对应应用 Scene；Myrtle 自带的 Scene Layer 更新观察器会收到 Scene 失效。

## 构建

```sh
export THEOS=/path/to/roothide-theos
make clean package FINALPACKAGE=1
```

关键配置：

```make
ARCHS = arm64
TARGET = iphone:clang:latest:15.0
THEOS_PACKAGE_SCHEME = roothide
DEB_ARCH = iphoneos-arm64e
```

GitHub Actions 会自动验证：

- 外层包架构必须为 `iphoneos-arm64e`；
- 包内 Mach-O 必须为 `arm64`，不得是 `arm64e`；
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

- `0.2.0`：正式 Hook 版，直接补充 App Switcher 卡片。
- `0.1.2`：文件日志诊断版，已停止使用。
- `0.1.1`：首次 arm64 诊断版，已停止使用。
- `0.1.0`：错误的 arm64e Mach-O 构建，会导致 SpringBoard 安全模式；产物已撤回，禁止安装。

