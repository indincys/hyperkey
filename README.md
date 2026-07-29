# Hyper

一个 macOS 常驻小工具，只做两件事：

1. 把 **Caps Lock 变成 Hyper 键**（⌘⌃⌥⇧ 四修饰键同时按下）；
2. **Hyper + 字母 → 打开 / 切换 / 隐藏对应 app**。

Apple Silicon 原生，无第三方依赖，菜单栏常驻，空闲 CPU 约为 0。

---

## 安装

仓库里带了构建好的 `Hyper.app`。`git clone` 下来的文件不带隔离属性，所以拷过去就能直接打开，不会被 Gatekeeper 拦：

```bash
git clone https://github.com/indincys/hyperkey.git
cp -R hyperkey/Hyper.app /Applications/ && open /Applications/Hyper.app
```

（`git clone` 克隆到终端当前所在目录——刚打开终端的话就是主目录，不是「下载」文件夹。）

如果直接双击了 clone 目录里的 `Hyper.app`，它会主动提示帮你搬进「应用程序」文件夹。**建议接受**：辅助功能授权绑定应用路径，先搬完再授权才不会白授权一次；而且从 git 工作区里运行的话，自动更新会往仓库里写文件。

### 从源码构建

```bash
./build.sh
```

需要 Xcode 命令行工具（`xcode-select --install`）。产出 `./Hyper.app`。

> 正式发布请务必用固定证书签名，否则每次更新用户都要重新授权一次 —— 见下面的「版本更新」。

### 首次运行

**授予「辅助功能」权限。** 没有权限时启动会直接把引导页摆出来，照着点即可。授权后无需重启——程序监听权限变更通知，拿到就自动接管。

**如果装过 Karabiner-Elements，得先让它放开键盘。** 它的 DriverKit 驱动会抢占物理键盘，Caps Lock 在它那里就被处理掉了，根本走不到本工具的重映射。两个办法：在它的 Settings → Devices 里取消勾选键盘（可逆），或者彻底卸载：

```bash
# 注意顺序：官方的 uninstall.sh 不会注销 DriverKit 驱动，
# 却会删掉唯一能注销它的工具，导致系统扩展变成清不掉的孤儿。
/Applications/.Karabiner-VirtualHIDDevice-Manager.app/Contents/MacOS/Karabiner-VirtualHIDDevice-Manager deactivate
sudo "/Library/Application Support/org.pqrs/Karabiner-Elements/uninstall.sh"
rm -rf ~/.config/karabiner ~/.local/share/karabiner
```

跑完重启一次，残留的登录项条目才会消失。`./doctor.sh` 会告诉你清干净了没有。

### 让授权不要每次重建都失效

辅助功能权限绑定在 app 的**代码签名身份**上。`build.sh` 默认用 ad-hoc 签名（`codesign -s -`），每次重建都会产生新身份，于是每次都要重新授权一次。

跑一次这个脚本，建一个固定的自签名证书：

```bash
./make-signing-cert.sh
```

之后这样构建，身份就不再变化，授权一次长期有效：

```bash
SIGN_ID="Hyper Self-Signed" ./build.sh
```

脚本会弹一次登录密码框（写入当前用户的证书信任设置，不碰系统域，不需要 sudo）。首次用它签名时钥匙串还会问一次权限，选「始终允许」。

---

## 分享给别人

先把最重要的一句说清楚：**「下载后双击直接打开、零提示」这个体验做不到。** 公证（notarization）必须要 Developer ID 证书，而它只能通过付费的 Apple Developer Program 获得。自签名证书在别人的电脑上不受信任，帮不上这个忙。

所以剩下的都是绕开 Gatekeeper 的办法。隔离属性（quarantine）是**下载它的那个程序**打上去的——浏览器、邮件、AirDrop 都会打，而有些传输方式不会。这一点决定了哪条路最省事。

### 方案 A：通过 git 仓库分发（推荐，对方不用装开发工具）

`git clone` 下来的文件**不带隔离属性**，Gatekeeper 因此完全不介入。把构建好的 `Hyper.app` 一起提交进仓库，对方：

```bash
git clone <你的仓库地址> && cp -R hyper/Hyper.app /Applications/ && open /Applications/Hyper.app
```

双击即开，没有任何拦截提示。这是几个朋友之间分享最顺的一条路。

### 方案 B：发压缩包 + 一条命令去掉隔离

打包发给对方（微信、网盘、邮件都行），对方拖进 `/Applications` 后跑一次：

```bash
xattr -dr com.apple.quarantine /Applications/Hyper.app
```

一条命令，之后正常打开。缺点是要开终端。

### 方案 C：不用终端，走系统设置放行

对方双击 → 被拦 → 打开「系统设置 → 隐私与安全性」→ 往下滚，会看到「已阻止使用 Hyper」→ 点「仍要打开」。

注意 macOS 15 之后**右键→打开**这个老办法已经失效了，只剩系统设置这一条 GUI 路径。

### 方案 D：让对方自己构建

需要先装 Xcode 命令行工具（`xcode-select --install`，约 700MB）：

```bash
git clone <仓库> && cd hyper && ./build.sh && cp -R Hyper.app /Applications/
```

本地构建出来的东西同样不带隔离属性。适合技术型朋友。

### 无论哪条路都躲不掉的一步

**每台电脑都要各自授予「辅助功能」权限。** 这是 macOS 的强制要求，没有任何办法代劳或预置。好在应用启动时如果没权限，会直接把引导页摆在对方面前，照着点就行。

---

## 版本更新

### 更新后会不会又要重新授权？

**只要每次发版都用同一个证书签名，就不会。**

macOS 把辅助功能授权绑定在 app 的「指定要求」（Designated Requirement）上。用固定证书签名后，这个要求长这样：

```
identifier "com.indincys.hyper" and certificate leaf = H"aa2aee…"
```

它认的是**证书**，不是二进制哈希。所以新版本只要还是这张证书签的，就满足同一个要求，**授权原样保留**。

对比一下 ad-hoc 签名（`codesign -s -`）的指定要求：

```
cdhash H"…"
```

认的是二进制哈希，改一行代码就变，于是**每次更新都要重新授权**。

所以发布正式版必须用 `SIGN_ID` 构建，不能图省事用默认的 ad-hoc。

### ⚠️ 一定要备份证书私钥

这张证书的私钥只在你这台机器的钥匙串里。**弄丢了就再也签不出「同一个身份」**，此后每个用户的每次更新都要重新授权，且无法挽回。

导出备份：

```bash
security export -k ~/Library/Keychains/login.keychain-db \
    -t identities -f pkcs12 -o hyper-signing-backup.p12
```

会让你设一个保护口令。把这个 `.p12` 和口令存到安全的地方（密码管理器里），**不要提交进仓库**。

### 发新版本

用 `release.sh`，不要手工发：

```bash
./release.sh 1.0.3 [发布说明文件]
```

它会改版本号、用固定证书构建、**校验签出来的确实是证书身份**（是 ad-hoc 就中止并回滚改动）、提交打 tag、推送、创建 GitHub Release 并上传压缩包。

那个校验不是多余的。发版时如果哪一次忘了用固定证书，退回 ad-hoc 签名，所有用户的辅助功能授权都会失效——而且发出去就收不回来了。

### 应用内自动更新

已实现。每天自动检查一次，也可以从菜单栏「检查更新…」手动触发。发现新版本会提示，确认后自动下载、替换、重启。

几个设计要点：

- **下载来的东西必须先过安全关卡。** 那是从网络拿到的可执行代码，安装前必须满足**当前运行版本**的指定要求（同 bundle ID + 同签名证书）。被篡改的下载、被劫持的发布资源、中间人替换，都会在这一步被拒掉并丢弃。
- **不会触发 Gatekeeper。** 隔离属性是下载方主动打的（浏览器，或声明了 `LSFileQuarantineEnabled` 的程序）。用 `URLSession` 自己下载、而我们没声明那个键，所以文件不带隔离属性。
- **替换可回滚。** 进程不能替换自己正在运行的 bundle，所以替换交给一个分离出去的脚本，等本进程退出后执行。它先把旧版挪到一边而不是删掉，新版就位后才清理；任何一步失败都回滚到旧版并照常启动——**绝不会让用户落到「没有应用」的状态**。
- **更新不需要重新授权**，前提还是那条：同一张证书。

---

## 配置

菜单栏图标 → **设置…**（或 ⌘,）。没有辅助功能权限时，应用启动会直接把引导页摆出来——它没权限就什么都做不了，静静待在菜单栏只会让人一头雾水。

- **快捷键**：「添加应用」弹出可搜索的应用列表（自动扫描 `/Applications`、`/System/Applications`、`~/Applications`），点一下就加进来。按键那一栏**直接按你想要的键**即可录入，不是从下拉框里挑。按 Esc 取消录入。重复的按键会标橙，找不到的应用会标红。
- **通用**：开机自启、重复按键是否隐藏、单击 Caps Lock 的行为、调试日志。

所有改动即时写入配置文件，没有「未保存」状态。手改文件同样即时生效，两边不会打架。

配置文件在 `~/.config/hyper/config.json`，首次运行自动生成。

```json
{
  "enabled": true,
  "tapAction": "none",
  "tapThresholdMs": 200,
  "toggleHideIfFrontmost": true,
  "bindings": {
    "c": "com.google.Chrome",
    "t": "com.mitchellh.ghostty",
    "w": "com.tencent.xinWeChat",
    "e": "/Applications/Microsoft Excel.app"
  }
}
```

| 字段 | 说明 |
| --- | --- |
| `enabled` | 总开关。菜单栏也能临时暂停。 |
| `debug` | 打开后把每个按键的**键码**记到 debug 日志，用于排查「按了没反应」。平时请保持关闭。 |
| `bindings` | 键 → app。值可以是 bundle ID，也可以是 `.app` 路径。 |
| `toggleHideIfFrontmost` | `true`：目标 app 已在最前时再按一次会隐藏它。`false`：永远只切到前台。**按住 Hyper 不松手连按同一个键即可来回切换**。 |
| `tapAction` | 单击 Hyper（按下又快速松开、中间没按别的键）触发什么。默认 `none`。 |
| `tapThresholdMs` | 判定为「单击」的时间上限，毫秒。 |

**键名**：`a`–`z`、`0`–`9`、`,` `.` `/` `;` `'` `[` `]` `-` `=` `` ` `` `\`、`space` `tab` `return` `delete` `escape`、`f1`–`f12`、`f13`–`f20`、`up` `down` `left` `right`。表里没有的键可以写原始键码，例如 `"kc:42"`。

> 键名对应的是 ANSI（美式 QWERTY）**物理键位**，因为虚拟键码描述的就是位置。这正好符合肌肉记忆——你按的是那个位置的键。

**查 bundle ID**：

```bash
/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "/Applications/某个应用.app/Contents/Info.plist"
```

**`tapAction` 的写法**：`"none"`、`"escape"`、`"f18"`、`"cmd+space"`、`"kc:53"` 这类。修饰键可用 `cmd` / `ctrl` / `opt` / `shift`。

### 让单击去触发别的 app（例如输入法的语音输入）

```json
{ "tapAction": "f18", "tapThresholdMs": 200 }
```

然后到那个 app 里把它的快捷键**录成 F18**。单击 Caps Lock 会合成一次 F18，长按不会——因为「单击」的判定是在松开的那一刻才做的：中间按过任何别的键、或者按住超过 `tapThresholdMs`，这一下就不算单击。

两个坑：

- **别在那边直接按 Caps Lock 去录快捷键。** 录进去的是 F19，而 F19 在按住 Hyper 的整个过程里都处于按下状态，长按一样会触发它。这正是上面「为什么映射到 F19」要解决的问题。
- **别用普通键或常规组合键**（比如 `⌥Z`）。合成出来的那一下是真事件，前台 app 也收得到，可能撞上它自己的快捷键。F18 没有哪块键盘上有，不会跟任何人抢。

---

## 工作原理

### 为什么不能只用 event tap 拦 Caps Lock

macOS 在 IOHIDSystem 内部就把 Caps Lock 的锁定状态和 LED 处理完了，**然后**事件才到达 `CGEventTap`。所以 tap 里 `return nil` 只能吞掉事件，拦不住状态翻转，而且照样吃到系统给 Caps Lock 的那段内置按下延迟。

所以第一步走 IOKit HID 层：把 Caps Lock 的 HID usage（`0x700000039`）重映射成 F19（`0x70000006E`），也就是 `hidutil property --set` 背后那套接口。这一层在 caps 逻辑之前，按键根本走不到锁定判定，直接以一个普通 F19 的身份出现。不需要 root，不需要内核扩展或系统扩展。

这个映射是**每次启动、每次设备接入**都要重下的，所以程序在启动时、系统唤醒后、以及监听到任意 HID 设备接入时都会重新应用，并回读校验。

### 为什么映射到 F19，而不是惯例的 F18

因为**这个键会被别人看见**，而且是在我们之前看见。

事件监听（`CGEventTap`）不是链条的最前端：输入法之类的东西也会挂自己的监听，还可能排在我们前面。程序在自己的监听里把这个键完全吞掉，只能保证它不再往下游走，拦不住排在前面的人。于是每一次按住 Hyper——哪怕只是准备接着按个字母——在它们眼里都是一次实打实的按键。

F18 恰恰是最容易被人绑走的那个键：它是各路改键工具的惯例目标，于是也就成了大家在输入法、启动器里录快捷键时会录到的键。比如把微信输入法的「语音输入」设成 F18，那么每次长按 Hyper 都会开始录音。

所以内部改用 F19，把 F18 空出来：**它只在真正的单击时由 `tapAction` 合成一次**，长按永远不发。要把单击接到外部工具上，就用它——见「配置」里的 `tapAction`。

### 怎么变成「真 Hyper」

事件监听里收到 F19 按下时，程序按硬件的顺序逐个合成并注入 `flagsChanged` 事件：Option → Control → **Shift** → **Command**，松开时反序卸载。

这个顺序不是随便排的，两个键不能被下游单独看见：

- **Shift 不能单独按下再单独松开**。中文输入法（微信输入法、搜狗、系统拼音……）正是用「单独敲一下 Shift」来切换中/英的。按住 Hyper 期间如果没有任何按键透传出去——轻点一下，或者按的是被完全吞掉的绑定键——注入序列就恰好是一次干净的 Shift 单击，用户的输入法会被切掉。所以 Shift 排在别人之后按下、在别人之前松开：它的按下和松开事件里都带着别的修饰键，而且两者之间还夹着 Command 的一按一松。
- **Command 不能单独按下**。只有 Command 按下的那一瞬间会让某些 app 闪一下菜单栏提示，所以它最后按下、最先松开。

于是最外层落到 Option 头上，它在首尾各有一瞬间是独自按下的——macOS 上没有任何东西会去读一次单独的 Option。

于是有两条路径同时成立：

- **配置里绑定过的键** —— 事件被完全吞掉，转成启动动作，下游 app 什么都收不到；
- **其他所有键** —— 原样透传，只是 flags 里合并了 ⌘⌃⌥⇧。这就是为什么 Hyper+K 在别的 app 里也能当普通快捷键注册。

### 防「修饰键卡死」

这是这类工具最危险的失效模式：如果 F19 的抬起事件丢了，四个修饰键会永久锁住，机器直接没法用。所有出口都汇到同一处清理逻辑：

- 事件监听被系统停用（`tapDisabledByTimeout` / `tapDisabledByUserInput`）→ 清理状态并立刻重新启用；
- 系统睡眠 / 唤醒、锁屏 / 屏保 → 清理；
- 收到 `SIGTERM` / `SIGINT` / `SIGHUP` → 走正常退出流程，顺带还原 Caps Lock。

其中「事件监听被系统停用后不重新启用」是这类工具「用着用着突然失灵」的头号原因。

> 曾经这里还有一条「切换前台 app → 清理」。它是个错误：**启动应用本身就会触发前台切换**，于是每次成功启动后程序都把 hyper 状态清成「已松开」，用户手还按着却认为松开了——按住 Hyper 连按多个键因此完全失效。防卡死的措施把它要保护的功能给废了。现在前台切换只用来记录「谁在最前」，不碰 hyper 状态。

有一种失效是事件监听自己看不见的：**Secure Input 在按住期间开启**，会把 F19 的抬起事件吞掉。这种情况用一个一次性看门狗兜底——按下时挂上、正常抬起时取消，所以平时根本不会触发。它触发时也不会盲目松开，而是先问 HID 层「F19 到底还按着没有」，还按着就重新挂上。因此故意长按永远不会被打断。

### 为什么不做定时轮询

早期版本有两个定时器（2 秒查一次权限、10 秒查一次健康状态），已经全部拆掉，换成事件驱动：

| 要感知的事 | 触发源 |
| --- | --- |
| 辅助功能权限被授予 / 撤销 | `com.apple.accessibility.api` 分布式通知 + 前台 app 切换（从系统设置切回来时正好命中） |
| 事件监听被停用 | 系统会把 `tapDisabled` 事件送进回调本身 |
| HID 映射失效 | IOKit 设备接入通知 + 系统唤醒通知 |
| 配置文件被改 | `DispatchSource` 文件监听 |
| 菜单栏状态过期 | 菜单打开的那一刻顺手校验 |

### 侵入性管理

`UserKeyMapping` 是一份**全系统共享的列表**。程序启动时先读一遍现有内容，只往里加自己那一条（caps lock → F19），其余条目原样带过；退出时也只摘掉自己那条，别人的原样放回。所以哪怕你另外用 `hidutil` 设过键位映射，装不装这个工具都不受影响。

退出时还原覆盖了正常退出、菜单退出、以及 `SIGTERM`/`SIGINT`/`SIGHUP`。只有 `kill -9` 兜不住。

### 修饰键状态跟踪

一旦开始往事件上叠加 hyper 掩码，事件自带的 flags 就不再能反映用户**真正**按住了什么。所以程序不读 flags，而是按状态转移来跟踪：修饰键只在真实状态变化时才发 `flagsChanged`，所以它此前在不在按下集合里，就唯一确定了这次是按下还是松开。松开 Hyper 时按这个真实集合还原，用户手里真按着的 Shift 不会被误清掉。

---

## 已知限制

- **Secure Input 场景下不工作**：系统密码框、以及某些终端开启安全输入时，event tap 收不到键盘事件，快捷键不响应。Karabiner 的虚拟 HID 驱动在这一层之下所以不受影响 —— 这是本方案相比 Karabiner 唯一实质性的能力损失。
- **上不了 App Store**：辅助功能权限与沙盒不兼容。
- **进程被 `SIGKILL`（`kill -9`）时无法清理**：Caps Lock 会停留在 F19 状态。手动恢复：

  ```bash
  hidutil property --set '{"UserKeyMapping":[]}'
  ```

---

## 排查

先跑体检脚本，它会一次性检查进程、HID 映射、抢占键盘的其他软件、配置合法性，并附上最近日志：

```bash
./doctor.sh
```

**最常见的一种失败**：Karabiner 没有退干净。退出 Karabiner-Elements 的界面程序**不会**停掉它的后台服务和 DriverKit 驱动，而驱动会抢占物理键盘——caps lock 在它那里就被规则转成了 ⌘⌃⌥⇧，根本走不到本工具的 F19 重映射。`./doctor.sh` 会直接报出来。

彻底停掉 Karabiner 有两条路：

```bash
# 可逆：打开 Karabiner-Elements → Settings → Devices → 取消勾选键盘
# 它就不再抢占该设备，随时可以勾回来

# 彻底：官方卸载脚本（需要输入密码）
sudo "/Library/Application Support/org.pqrs/Karabiner-Elements/uninstall.sh"
```

看日志：

```bash
log show --last 5m --info --debug --predicate 'subsystem == "com.indincys.hyper"' --style compact
```

实时跟：

```bash
log stream --level debug --predicate 'subsystem == "com.indincys.hyper"'
```

查当前 HID 映射（应该能看到 `30064771129` → `30064771182`，即 caps lock → F19）：

```bash
hidutil property --get "UserKeyMapping"
```

---

## 源码结构

| 文件 | 职责 |
| --- | --- |
| `Sources/Hyper/HIDRemapper.swift` | Caps Lock → F19 的 HID 层重映射、设备接入监听、回读校验 |
| `Sources/Hyper/HyperTap.swift` | 事件监听、Hyper 修饰键合成、按键拦截、状态清理 |
| `Sources/Hyper/AppLauncher.swift` | 启动 / 切换 / 隐藏，含路径解析缓存 |
| `Sources/Hyper/Config.swift` | 配置读写、校验、文件监听热重载 |
| `Sources/Hyper/AppDelegate.swift` | 菜单栏、权限、事件驱动的状态维护、信号处理 |
| `Sources/Hyper/SettingsModel.swift` | 设置界面的数据层，每次改动直接落盘 |
| `Sources/Hyper/SettingsView.swift` | 设置界面与权限引导页（SwiftUI） |
| `Sources/Hyper/SettingsWindowController.swift` | 设置窗口的宿主 |
| `Sources/Hyper/KeyRecorderField.swift` | 「按下你想要的键」录入控件（AppKit 绘制） |
| `Sources/Hyper/AppCatalog.swift` | 扫描已安装应用，供选择器使用 |
| `Sources/Hyper/Updater.swift` | 应用内更新：检查、下载、签名校验、可回滚替换 |
| `Sources/Hyper/InstallLocation.swift` | 检测并引导搬进「应用程序」文件夹 |
| `Sources/Hyper/Keys.swift` | 键码表与修饰键映射表 |
