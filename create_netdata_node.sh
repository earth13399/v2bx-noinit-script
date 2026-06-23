#!/bin/bash
# Netdata Child 节点一键配置脚本（支持 SSL 开关）- 已禁用日志采集

set -e

# 参数检查
PARENT="${1}"
API_KEY="${2}"
HOSTNAME="${3}"
USE_SSL="${4}"   # 可选：ssl

if [ -z "$PARENT" ] || [ -z "$API_KEY" ] || [ -z "$HOSTNAME" ]; then
    echo "❌ 使用方法: $0 <PARENT> <API_KEY> \"<机器名称>\" [ssl]"
    echo "示例: $0 192.168.1.100 你的APIKEY \"prod-web-01\""
    echo "      $0 192.168.1.100 你的APIKEY \"prod-web-01\" ssl"
    exit 1
fi

echo "🚀 开始配置 Netdata Child 节点..."
echo "   Parent     : ${PARENT}"
echo "   API Key    : ${API_KEY}"
echo "   机器名称   : ${HOSTNAME}"
echo "   SSL        : ${USE_SSL:-否}"

# 确保 Netdata 已安装
if ! command -v netdata &> /dev/null; then
    echo "⚠️  Netdata 未安装，正在安装..."
    bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) --install-type any --dont-start-it
fi

cd /etc/netdata

# 备份
if [ ! -f stream.conf.bak ]; then
    sudo cp stream.conf "stream.conf.bak.$(date +%F-%H%M%S)"
    echo "✅ 已备份 stream.conf"
fi

# 构建 destination
if [ "$USE_SSL" = "ssl" ] || [ "$USE_SSL" = "SSL" ]; then
    DESTINATION="${PARENT}:19999:SSL"
else
    DESTINATION="${PARENT}:19999"
fi

# 写入 stream.conf
sudo cat > stream.conf << EOF
[stream]
enabled = yes
destination = ${DESTINATION}
api key = ${API_KEY}

# 推荐优化 - 过滤掉日志相关
send charts matching = system.* disk.* net.* memory.* cpu.* !*.debug !logs.* !systemd.journal.*
buffer size = 15MiB
reconnect delay = 15s
EOF

echo "✅ stream.conf 配置完成 (SSL: ${USE_SSL:-否})"

# 配置自定义机器名称 + 资源优化 + 禁用日志
sudo cat > /tmp/netdata.conf.new << 'EOC'
[global]
    hostname = HOSTNAME_PLACEHOLDER
    memory mode = ram
    history = 7200

[health]
    enabled = no

[web]
    mode = none

# 禁用系统日志采集（重要！）
[plugin:proc:systemd-journal]
    enabled = no

[plugin:proc:logs]
    enabled = no

[logs]
    retention = 86400     # 日志最多保留1天
EOC

# 安全合并
if [ -f netdata.conf ]; then
    sudo cp netdata.conf "netdata.conf.bak.$(date +%F-%H%M%S)"
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    sudo awk '1' netdata.conf /tmp/netdata.conf.new > /tmp/netdata.conf.merged 2>/dev/null || true
    sudo mv /tmp/netdata.conf.merged netdata.conf
else
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    sudo mv /tmp/netdata.conf.new netdata.conf
fi

echo "✅ netdata.conf 配置完成（已禁用日志采集）"

# 重启
sudo systemctl restart netdata
echo "✅ Netdata 已重启"

echo ""
echo "🎉 配置完成！"
echo "🔍 当前 stream 配置："
cat /etc/netdata/stream.conf
echo ""
echo "📋 建议检查："
echo "   sudo journalctl -u netdata -n 30 --no-pager | grep -E 'STREAM|error'"
echo ""
echo "刷新 Parent 仪表盘，应该看到机器名为：${HOSTNAME}"
