#!/bin/sh
# 对照实验：全量 cookie vs 重建四字段 cookie 打 115 files API
UA="Mozilla/5.0 115Browser/35.6.0.3"
URL="https://webapi.115.com/files?aid=1&cid=0&o=user_ptime&asc=1&offset=0&show_dir=1&limit=1000&snap=0&natsort=0&record_open_time=1&format=json&fc_mix=0"

CK=$(grep -o 'cookie\\":\\"[^\\]*' /tmp/olz/cfg.json | tail -1 | sed 's/^cookie\\":\\"//')
echo "full cookie len=${#CK}"

field() {
  echo "$CK" | tr ';' '\n' | sed 's/^[[:space:]]*//' | grep -i "^$1=" | tail -1 | cut -d= -f2-
}
UID=$(field UID); CID=$(field CID); SEID=$(field SEID); KID=$(field KID)
echo "rebuilt: UID=${#UID}B CID=${#CID}B SEID=${#SEID}B KID=${#KID}B"
REBUILT="UID=$UID;CID=$CID;SEID=$SEID;KID=$KID"

hit() {
  echo "--- $1 ---"
  curl -s --max-time 20 -w '\n[HTTP %{http_code} size=%{size_download}]\n' "$URL" \
    -H "User-Agent: $UA" ${3:+-H "Referer: $3"} -H "Cookie: $2" \
    | sed -e 's/\("pc":"\)[^"]*/\1<R>/g' | head -c 500
  echo
}

hit "rebuilt 4-field cookie" "$REBUILT" "https://115.com/"
hit "full cookie" "$CK" "https://115.com/"
hit "full cookie, no referer" "$CK" ""
