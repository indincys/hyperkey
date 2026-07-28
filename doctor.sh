#!/usr/bin/env bash
# 一键体检：把 Hyper 不工作时该看的东西全打出来。
cd "$(dirname "$0")"

ok()   { printf "  \033[32m✓\033[0m %s\n" "$1"; }
bad()  { printf "  \033[31m✗\033[0m %s\n" "$1"; }
warn() { printf "  \033[33m!\033[0m %s\n" "$1"; }

echo
echo "── Hyper 进程"
if pgrep -f "Hyper.app/Contents/MacOS/Hyper" >/dev/null; then
    ok "运行中 (pid $(pgrep -f 'Hyper.app/Contents/MacOS/Hyper' | tr '\n' ' '))"
    ps -o comm= -p "$(pgrep -f 'Hyper.app/Contents/MacOS/Hyper' | head -1)" | sed 's/^/    /'
else
    bad "未运行 —— open /Applications/Hyper.app"
fi

echo
echo "── Caps Lock → F18 的 HID 映射"
MAP=$(hidutil property --get "UserKeyMapping" | tr -d '\n ')
if [[ "$MAP" == *"30064771181"* && "$MAP" == *"30064771129"* ]]; then
    ok "已生效 (30064771129 → 30064771181)"
else
    bad "未生效，当前值: $MAP"
fi

echo
echo "── 抢占键盘的其他软件"
KCFG=~/.config/karabiner/karabiner.json
if ! pgrep -f -i karabiner >/dev/null; then
    ok "Karabiner 已完全停止"
elif [[ -f "$KCFG" ]] && python3 - "$KCFG" <<'PY' 2>/dev/null
import json, sys
p = json.load(open(sys.argv[1]))["profiles"][0]
kb = [d for d in p.get("devices", []) if d.get("identifiers", {}).get("is_keyboard")]
sys.exit(0 if kb and all(d.get("ignore") for d in kb) else 1)
PY
then
    ok "Karabiner 在运行，但键盘已设为 ignore —— 没有抢占，不影响 Hyper"
    warn "它的 caps_lock 规则还留着：一旦在 Devices 里重新勾选键盘，Hyper 会立刻失效"
else
    bad "Karabiner 正在抢占物理键盘 —— Hyper 收不到任何按键"
    echo "    修复：打开 Karabiner-Elements → Settings → Devices → 取消勾选键盘"
    echo "    或彻底卸载：sudo \"/Library/Application Support/org.pqrs/Karabiner-Elements/uninstall.sh\""
fi
if pgrep -f -i hapigo >/dev/null; then
    warn "HapiGo 在运行 —— 它若也绑了 Hyper+字母，同一个键会被两边同时接管"
else
    ok "HapiGo 未运行"
fi

echo
echo "── 配置"
CFG=~/.config/hyper/config.json
if [[ -f "$CFG" ]]; then
    if python3 -c "import json,sys; json.load(open('$CFG'))" 2>/dev/null; then
        ok "$CFG ($(python3 -c "import json;print(len(json.load(open('$CFG')).get('bindings',{})))") 条绑定)"
    else
        bad "$CFG 不是合法 JSON"
    fi
else
    warn "$CFG 不存在（首次启动会自动生成）"
fi

echo
echo "── 最近日志"
log show --last 10m --info --debug \
    --predicate 'subsystem == "com.indincys.hyper"' --style compact 2>/dev/null \
    | tail -20 | sed 's/^/    /'

echo
echo "提示：想看实时按键，把配置里的 \"debug\" 设为 true，然后另开一个终端跑"
echo "  log stream --level debug --predicate 'subsystem == \"com.indincys.hyper\"'"
echo
