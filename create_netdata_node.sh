#!/bin/bash
# Netdata Child 节点一键配置脚本 - 最终优化版
# 彻底禁用日志 + 解决安装交互问题

set -e
export DEBIAN_FRONTEND=noninteractive

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

# ==================== 安装 Netdata（重点修复）====================
if ! command -v netdata &> /dev/null; then
    echo "⚠️ Netdata 未安装，正在安装..."

    # 强制清理残留
    sudo systemctl stop netdata 2>/dev/null || true
    sudo apt-get purge -y netdata netdata-repo-edge 2>/dev/null || true
    sudo rm -rf /etc/netdata /var/lib/netdata /var/cache/netdata /tmp/netdata-kickstart* 2>/dev/null || true

    # 尝试 static 安装（最推荐）
    echo "→ 尝试 static 安装..."
    if ! bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) \
        --install-type static --dont-start-it --accept; then
        echo "→ static 失败，尝试 git 方式..."
        bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) \
            --install-type git --dont-start-it --accept
    fi
fi

# 确保进入配置目录
cd /etc/netdata

# ==================== 配置 stream.conf ====================
# 备份
if [ -f stream.conf ]; then
    sudo cp stream.conf "stream.conf.bak.$(date +%F-%H%M%S)"
fi

# 设置 destination
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
    # 彻底过滤日志相关指标
    send charts matching = !*.logs* !*.journal* !*.log* !systemd* !logs.* !error.* !debug.*
    send charts matching = system.* disk.* net.* memory.* cpu.* processes.* !*.debug*
    buffer size = 20MiB
    reconnect delay = 10s
EOF
echo "✅ stream.conf 配置完成（已加强日志过滤）"

# ==================== 配置 netdata.conf ====================
sudo cat > /tmp/netdata.conf.new << 'EOC'
[global]
    hostname = HOSTNAME_PLACEHOLDER
    memory mode = ram
    history = 7200

[health]
    enabled = yes
    enable stock health configuration = no

[plugins]
    systemd-journal = no        # 彻底禁用系统日志采集
    go.d = yes

[logs]
    level = error
EOC

# 合并配置
if [ -f netdata.conf ]; then
    sudo cp netdata.conf "netdata.conf.bak.$(date +%F-%H%M%S)"
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    sudo awk '1' netdata.conf /tmp/netdata.conf.new > /tmp/netdata.conf.merged
    sudo mv /tmp/netdata.conf.merged netdata.conf
else
    sudo sed -i "s|HOSTNAME_PLACEHOLDER|${HOSTNAME}|g" /tmp/netdata.conf.new
    sudo mv /tmp/netdata.conf.new netdata.conf
fi

echo "✅ netdata.conf 配置完成（已禁用日志）"

# ==================== 重启 ====================
sudo systemctl restart netdata
echo "✅ Netdata 已重启"

echo ""
echo "🎉 配置完成！"
echo "🔍 当前 stream 配置："
cat /etc/netdata/stream.conf
echo ""
echo "📋 检查日志命令："
echo "  sudo journalctl -u netdata -n 30 --no-pager | grep -E 'STREAM|journal|error'"
echo ""
echo "请刷新 Parent 仪表盘查看机器：${HOSTNAME}"
