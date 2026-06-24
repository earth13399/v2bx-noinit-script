#!/bin/bash
# Netdata Child 节点一键配置脚本 - 最终优化版
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

# ==================== 1. 安装 Netdata ====================
if ! command -v netdata &> /dev/null; then
    echo "⚠️ Netdata 未安装，正在安装..."

    # 强制清理残留
    sudo systemctl stop netdata 2>/dev/null || true
    sudo apt-get purge -y netdata netdata-repo-edge 2>/dev/null || true
    sudo rm -rf /etc/netdata /var/lib/netdata /var/cache/netdata /tmp/netdata-kickstart* 2>/dev/null || true

    # 使用最新非交互方式安装
    echo "→ 使用非交互方式安装 Netdata..."
    if ! bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) \
        --non-interactive --dont-start-it; then
        echo "→ 尝试 static-only 方式..."
        bash <(curl -Ss https://get.netdata.cloud/kickstart.sh) \
            --non-interactive --static-only --dont-start-it
    fi

    # 再次检查是否安装成功
    if ! command -v netdata &> /dev/null; then
        echo "❌ Netdata 安装失败，请手动检查后重试"
        exit 1
    fi
    echo "✅ Netdata 安装成功"
fi

# ==================== 2. 进入配置目录（此时目录已存在） ====================
sudo mkdir -p /etc/netdata
cd /etc/netdata

# ==================== 3. 配置 stream.conf ====================
if [ -f stream.conf ]; then
    sudo cp stream.conf "stream.conf.bak.$(date +%F-%H%M%S)"
fi

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
    # 只过滤日志相关内容，保留核心指标
    send charts matching = !*.logs* !*.journal* !*.log.* !debug.*
    buffer size = 20MiB
    reconnect delay = 10s
EOF
echo "✅ stream.conf 配置完成"

# ==================== 4. 配置 netdata.conf ====================
if [ -f netdata.conf ]; then
    sudo cp netdata.conf "netdata.conf.bak.$(date +%F-%H%M%S)"
fi

sudo cat > netdata.conf << EOF
[global]
    hostname = ${HOSTNAME}
    memory mode = ram
    history = 7200

[health]
    enabled = yes
    enable stock health configuration = no

[plugins]
    systemd-journal = no
    go.d = yes

[logs]
    level = error
EOF
echo "✅ netdata.conf 配置完成（已禁用日志）"

# ==================== 5. 重启 Netdata ====================
sudo systemctl restart netdata
echo "✅ Netdata 已重启"

echo ""
echo "🎉 配置完成！"
echo "🔍 当前 stream 配置："
cat /etc/netdata/stream.conf
echo ""
echo "📋 建议检查命令："
echo "  sudo journalctl -u netdata -n 30 --no-pager | grep -E 'STREAM|error'"
echo ""
echo "请刷新 Parent 仪表盘，查看机器名：${HOSTNAME}"
