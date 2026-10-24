#!/bin/sh
# =========================================================================
#  /opt/script/openlist_watchdog.sh —— openlist 端口存活守卫（2026-10-24）
#
#  为什么需要
#  ----------
#  2026-10-24 生产实例（15244）在 `POST /api/admin/config/import` 之后
#  **静默死亡**：日志停在那条 import 成功行（完整行、带换行，说明死在其后），
#  没有 panic、没有优雅退出行（`http: ... exiting`）、dmesg 无 OOM，
#  `ulimit -c = 0` 所以连 core 都没有。服务就这么没人发现地挂着。
#
#  本脚本只做一件事：端口不在听 ⇒ 记现场 + 拉起。判定用端口，不用进程名
#  子串（2026-10-15 误杀过生产，铁律见 openlist_start.sh 的注释）。
#
#  ⚠ 熔断是必需的，不是可选
#  ------------------------
#  绝不能"无限重启"——每次拉起都要把 14 个存储重新 init 一遍，而其中：
#    * WoPan 的 refresh_token **一次性轮换**（刷一次旧的即作废，见
#      zig-src/tools/creds.local.json 的说明）；
#    * 迅雷登录有上游限频（`shield_reject: Operation too frequent`）。
#  重启循环等于拿一次性凭据去撞墙。所以：窗口内最多 `-n` 次，超了停手
#  并打 FATAL —— 宁可让它停着等人来看，也不能把令牌刷光。
#
#  用法
#  ----
#    /bin/sh /opt/script/openlist_watchdog.sh [-p 15244] [-i 30] [-n 5] [-w 600] [-s <start.sh>]
#      -p  要守的 TCP 端口
#      -i  探活间隔（秒）
#      -n  窗口内最多拉起几次
#      -w  熔断窗口（秒）
#      -g  拉起后的静默期（秒，默认 300）
#      -s  拉起脚本（默认 /opt/script/openlist_start.sh，幂等）
#
#  单实例：/tmp/openlist_watchdog_<port>.pid，重复调用自行退出。
#  自身日志：/tmp/openlist_watchdog_<port>.log（现场取证也写这里）。
#  开机自启：/opt/script/user_init.sh 里加一行（见文件末尾注释）。
#
#  ⚠ 两个刻意不做的事（别"顺手补上"，会出事）
#  ------------------------------------------
#  1. **不 kill 进程**。openlist_start.sh 内部最多重试 15 轮 ×（等 10s 端口
#     + 睡 6s）≈ 240s 才起来（CDN 取不到前端时就是这样）。看门狗若在它启动
#     途中 kill，等于把重试循环无限重置。所以这里只调 `start` —— 它在进程
#     已存在时只打 "already running" 然后什么都不做（幂等），慢启动不会被
#     打断。代价：进程活着但彻底卡死（端口一直不听）的情况不会自愈，只会在
#     日志里反复记 DOWN，留给人处理。
#  2. **不用进程名/exe 去判定"僵尸进程"**。实测按 exe 匹配（`*/openlist/
#     openlist`）会跨服务命中 —— 守别的端口时能把生产实例认成僵尸。判定只
#     用端口，与设备上的铁律一致（2026-10-15 误杀过生产）。
#  3. 拉起后静默 `-g` 秒（默认 300 > start.sh 的 240s 预算）再探，避免
#     把一次慢启动当成多次故障。
# =========================================================================
export PATH=/bin:/sbin:/usr/bin:/usr/sbin

PORT=15244
INTERVAL=30
MAX=5
WINDOW=600
GRACE=300
START=/opt/script/openlist_start.sh

while getopts 'p:i:n:w:g:s:h' opt; do
    case "$opt" in
        p) PORT=$OPTARG ;;
        i) INTERVAL=$OPTARG ;;
        n) MAX=$OPTARG ;;
        w) WINDOW=$OPTARG ;;
        g) GRACE=$OPTARG ;;
        s) START=$OPTARG ;;
        h|*)
            sed -n '2,40p' "$0" | sed 's/^# \{0,2\}//'
            exit 2
            ;;
    esac
done

PIDF=/tmp/openlist_watchdog_${PORT}.pid
LOG=/tmp/openlist_watchdog_${PORT}.log
HITS=/tmp/openlist_watchdog_${PORT}.hits

# ---- 单实例 -------------------------------------------------------------
if [ -f "$PIDF" ]; then
    old=$(cat "$PIDF" 2>/dev/null)
    if [ -n "$old" ] && [ -d "/proc/$old" ]; then
        echo "watchdog for $PORT already running (pid=$old)"
        exit 0
    fi
fi
echo $$ > "$PIDF"
trap 'rm -f "$PIDF"' EXIT INT TERM

say() { echo "[$(date '+%F %T')] $*" >> "$LOG"; }

# ---- 判定：端口在不在听 --------------------------------------------------
listening() {
    netstat -ltn 2>/dev/null | grep -q ":${PORT} "
}

# 仅用于**取证打印**，不参与判定（见文件头：按 exe 匹配会跨服务命中）
openlist_pids() {
    for p in $(ls /proc 2>/dev/null | grep -E '^[0-9]+$'); do
        e=$(readlink "/proc/$p/exe" 2>/dev/null)
        case "$e" in
            */openlist/openlist) echo "$p" ;;
        esac
    done
}

# ---- 现场取证：下次真崩了靠这些 -----------------------------------------
record() {
    say "--- 现场 ---"
    grep -E 'MemTotal|MemAvailable' /proc/meminfo >> "$LOG" 2>&1
    say "openlist pids: $(openlist_pids | tr '\n' ' ')"
    echo "--- dmesg tail ---" >> "$LOG" 2>&1
    dmesg 2>/dev/null | tail -n 12 | cut -c1-140 >> "$LOG" 2>&1
    echo "--- openlist.log tail ---" >> "$LOG" 2>&1
    tail -n 15 /tmp/openlist.log >> "$LOG" 2>&1
    say "--- 现场结束 ---"
}

# 只保留窗口内的记录
prune_hits() {
    now=$(date +%s)
    [ -f "$HITS" ] || return 0
    awk -v now="$now" -v win="$WINDOW" 'now - $1 < win' "$HITS" > "$HITS.tmp" 2>/dev/null
    mv -f "$HITS.tmp" "$HITS"
}

# 预建计数文件：否则首次 DOWN 时 `wc -l < $HITS` 的 ash 重定向会打印一句
# "can't open"（无害，但污染日志）。
[ -f "$HITS" ] || : > "$HITS"

say "watchdog started: port=$PORT interval=${INTERVAL}s max=${MAX}/${WINDOW}s grace=${GRACE}s start=$START (pid=$$)"

while true; do
    if ! listening; then
        say "DOWN: :$PORT not listening"
        record
        prune_hits
        n=$(wc -l < "$HITS" 2>/dev/null || echo 0)

        if [ "$n" -ge "$MAX" ]; then
            say "FATAL: 已在 ${WINDOW}s 内拉起 $n 次（上限 $MAX），停手等人处理 —— 继续重启会消耗一次性凭据（WoPan refresh_token）"
            exit 1
        fi

        # 只调 `start`（幂等）：它内部已在跑时会自己说 already running 并退出，
        # 不会打断慢启动。见文件头"两个刻意不做的事"。
        say "restarting (attempt $((n + 1))/$MAX)"
        /bin/sh "$START" >> "$LOG" 2>&1
        rc=$?
        date +%s >> "$HITS"
        say "start script rc=$rc; 静默 ${GRACE}s（> start.sh 的 ~240s 重试预算）"
        sleep "$GRACE"
        continue
    fi
    sleep "$INTERVAL"
done
