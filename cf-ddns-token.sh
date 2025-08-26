#!/usr/bin/env bash
set -o errexit
set -o nounset
set -o pipefail

# === 配置参数 ===
CFKEY=
CFUSER=
CFZONE_NAME=
CFRECORD_NAME=
CFRECORD_TYPE=A
CFTTL=60
FORCE=false
WANIPSITE="http://ipv4.icanhazip.com"

# === 获取参数 ===
while getopts k:u:h:z:t:f: opts; do
  case ${opts} in
    k) CFKEY=${OPTARG} ;;
    u) CFUSER=${OPTARG} ;;
    h) CFRECORD_NAME=${OPTARG} ;;
    z) CFZONE_NAME=${OPTARG} ;;
    t) CFRECORD_TYPE=${OPTARG} ;;
    f) FORCE=${OPTARG} ;;
  esac
done

# === 认证方式判断 ===
if [ "$CFUSER" = "token" ]; then
  # API Token 模式
  AUTH_HEADER=(-H "Authorization: Bearer $CFKEY")
else
  # Global API Key 模式
  AUTH_HEADER=(-H "X-Auth-Email: $CFUSER" -H "X-Auth-Key: $CFKEY")
fi

# === 获取公网 IP ===
if [ "$CFRECORD_TYPE" = "AAAA" ]; then
  WANIPSITE="http://ipv6.icanhazip.com"
fi
WAN_IP=$(curl -s ${WANIPSITE})

# === 获取 Zone ID ===
CFZONE_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones?name=$CFZONE_NAME" \
  "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)

# === 获取 Record ID ===
CFRECORD_ID=$(curl -s -X GET "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records?name=$CFRECORD_NAME" \
  "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" | grep -Po '(?<="id":")[^"]*' | head -1)

# === 更新 DNS ===
RESPONSE=$(curl -s -X PUT "https://api.cloudflare.com/client/v4/zones/$CFZONE_ID/dns_records/$CFRECORD_ID" \
  "${AUTH_HEADER[@]}" \
  -H "Content-Type: application/json" \
  --data "{\"id\":\"$CFZONE_ID\",\"type\":\"$CFRECORD_TYPE\",\"name\":\"$CFRECORD_NAME\",\"content\":\"$WAN_IP\", \"ttl\":$CFTTL}")

if echo "$RESPONSE" | grep -q "\"success\":true"; then
  echo "✅ Updated successfully: $WAN_IP"
else
  echo "❌ Update failed"
  echo "Response: $RESPONSE"
  exit 1
fi
