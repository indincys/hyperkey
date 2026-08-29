## 应用隐藏

- Chrome、Codex 等应用现在会被真正隐藏，不再只切换到前一个应用后留在后台可见。
- 优先通过辅助功能设置目标进程自身的标准隐藏状态，避开菜单栏应用调用 `NSRunningApplication.hide()` 时被系统拒绝的问题。
- 不模拟 Command-H，因此即使用户仍按住 Hyper 的 Control、Option、Shift、Command，也不会误触其他组合键。
- 目标不支持标准隐藏属性时，仍会依次尝试应用自身的 Hide 菜单和系统隐藏请求，最后才切换前台应用兜底。
