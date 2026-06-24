#!/bin/bash
# Netdata Child 节点一键配置脚本 - 优化版（彻底禁用日志）
set -e

# 参数检查
PARENT="${1}"
API_KEY="${2}"
HOSTNAME="${3}"
USE_SSL="${4}" # 可选：ssl

if [ -z "$PARENT" ] || [ -z "$API_KEY" ] || [ -z "$HOSTNAME" ]; then
    echo "❌ 使用方法: $0 <PARENT> <API_KEY> \"<机器名称>\" [ssl]"
    echo "示例: $0 192.168.1.100 你的APIKEY \"tokyo-01\""
    echo "      $0 192.168.1.100 你的APIKEY \"tokyo-01\" ssl"
    exit 1
fi

echo "🚀 开始配置 Netdata Child 节点..."
echo " Parent     : ${PARENT}"
echo " API Key    : ${API_KEY}"
echo " 机器名称   : ${HOSTNAME}"
echo " SSL        : ${USE_SSL:-否}"

# 确保 Netdata 已安装
if ! command -v netdata &> /dev/null; then
    echo "⚠️ Netdata 未安装，正在安装..."
    bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) --install-type any --dont-start-it
fi

cd /etc/netdata

# 备份 stream.conf
if [ -f stream.conf ]; then
    sudo cp stream.conf "stream.conf.bak.$(date +%F-%H%M%S)"
    echo "✅ 已备份 stream.conf"
fi

# 配置 stream.conf（加强日志过滤）
if [ "$USE_SSL" = "ssl" ] || [ "$USE_SSL" = "SSL" ]; then
    DESTINATION="${PARENT}:19999:SSL"
else
    DESTINATION="${PARENT}:19999"
fi

sudo cat > stream.conf << EOF
[stream]
    enabled = yes
    destination = ${DESTINATION}
    api key = ${API_KEY}
    # 强烈过滤掉所有日志相关内容
    send charts matching = !*.logs* !*.journal* !*.log.* !systemd* !logs.* !error.* !debug.*
    send charts matching = system.* disk.* net.* memory.* cpu.* processes.* !*.debug*
    buffer size = 20MiB
    reconnect delay = 10s
EOF
echo "✅ stream.conf 配置完成 (已加强日志过滤)"

# 配置 netdata.conf（禁用日志 + 优化）
sudo cat > /tmp/netdata.conf.new << 'EOC'
[global]
    hostname = HOSTNAME_PLACEHOLDER

[health]
    enabled = yes                  # 保留健康告警，但下面会过滤
    enable stock health configuration = no

[plugins]
    systemd-journal = no           # 彻底禁用系统日志采集（最重要）
    go.d = yes                     # 保留 go.d（可监控服务状态，但下面会过滤）

[plugin:go.d]
    systemdunits = yes             # 可选保留服务状态监控

# 禁用其他日志相关
[logs]
    level = error
EOC

# 安全合并 netdata.conf
if [ -f netdata.conf ]; then
    sudo cp netdata.conf "netdata.conf.bak.$(date +%F-%H%M%S)"
    echo "✅ 已备份 netdata.conf"
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    
    # 简单合并（保留原有配置 + 新配置）
    sudo awk '1' netdata.conf /tmp/netdata.conf.new > /tmp/netdata.conf.merged 2>/dev/null || true
    sudo mv /tmp/netdata.conf.merged netdata.conf
else
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    sudo mv /tmp/netdata.conf.new netdata.conf
fi

echo "✅ netdata.conf 配置完成（已彻底禁用日志采集）"

# 重启 Netdata
sudo systemctl restart netdata
echo "✅ Netdata 已重启"

echo ""
echo "🎉 配置完成！"
echo "🔍 检查 stream 配置："
cat /etc/netdata/stream.conf
echo ""
echo "📋 检查日志（应该看不到 journal 相关错误）："
echo " sudo journalctl -u netdata -n 50 --no-pager | grep -E 'STREAM|journal|error'"
echo ""
echo "刷新 Parent 仪表盘，确认机器名为：${HOSTNAME}"
