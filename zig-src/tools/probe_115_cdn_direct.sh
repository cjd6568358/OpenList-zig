#!/bin/sh
# 115 CDN 403 归因：抓新鲜直链，在设备上直接打，试不同头组合。
# 1) 触发一次实例代理下载（会 403，但 run.log 里留下新鲜直链 URL）
# 2) 从日志增量提取 URL
# 3) 直接 curl 该 URL：无头 / 仅 UA / UA+Cookie / UA+Cookie+Referer
UA="Mozilla/5.0 115Browser/35.6.0.3"
FILE="/dav/115/olz-diag-1792295204-root.txt"
BASIC="admin:e2e-test-123456"

MARK=$(wc -c < /tmp/olz/run.log)
echo "mark=$MARK"
curl -s -o /dev/null -w 'instance proxy: %{http_code}\n' \
  "http://127.0.0.1:15399$FILE" \
  -u "$BASIC" -H "User-Agent: $UA"

URL=$(tail -c +$((MARK+1)) /tmp/olz/run.log | grep -o 'https://cdnfhnfile[^ ]*' | tail -1)
if [ -z "$URL" ]; then
  echo "NO FRESH URL IN LOG"; exit 1
fi
echo "fresh url host: $(echo "$URL" | cut -d/ -f3)"

# 会话 cookie（与实例同款：cfg 里重建四字段）
CK=$(grep -o 'cookie\\":\\"[^\\]*' /tmp/olz/cfg.json | tail -1 | sed 's/^cookie\\":\\"//')
f() { echo "$CK" | tr ';' '\n' | sed 's/^[[:space:]]*//' | grep -i "^$1=" | tail -1 | cut -d= -f2-; }
UID=$(f UID); CID=$(f CID); SEID=$(f SEID); KID=$(f KID)
REBUILT="UID=$UID;CID=$CID;SEID=$SEID;KID=$KID"

hit() {
  echo "--- $1 ---"
  shift
  curl -s --max-time 20 -o /dev/null -D - -w 'BODY%{size_download}\n' "$@" "$URL" 2>&1 \
    | grep -iE '^HTTP/|^content-range|^accept-ranges|^content-type|^BODY'
}

hit "no headers"
hit "UA only" -H "User-Agent: $UA"
hit "UA + session cookie" -H "User-Agent: $UA" -H "Cookie: $REBUILT"
hit "UA + cookie + referer" -H "User-Agent: $UA" -H "Cookie: $REBUILT" -H "Referer: https://115.com/"
hit "UA + cookie + range" -H "User-Agent: $UA" -H "Cookie: $REBUILT" -H "Range: bytes=0-4"
hit "full cookie" -H "User-Agent: $UA" -H "Cookie: $CK"
