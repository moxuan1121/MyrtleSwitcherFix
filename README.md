# Myrtle Switcher Fix 0.5.3 clean baseline

面向 iOS 15、Dopamine RootHide 与 Myrtle 1.4.1。

仅保留已经实机验证的四项功能：

- 分屏应用后台卡片登记、排序和删除联动；
- App 内固定高度键盘避让；
- 无分屏窗口时重新加载当前全屏应用；
- 分屏切换时保持主屏幕原页面。

不包含后续加入的手柄底部限制、键盘点击外部关闭窗口、触摸穿透与 Scene
路由、窗口裁剪与横屏修复、字母启动器和直接选择器 Hook，也不包含诊断日志、
应用侧注入、MyrtleSupport 或常驻轮询。

构建参数：

```sh
export THEOS=/path/to/roothide-theos
make clean package FINALPACKAGE=1
```

产物必须为 Apple 新 ABI 的原生 arm64e，并且仅注入 `com.apple.springboard`。
