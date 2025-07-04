#!/bin/bash

set -e

# 文件路径
LOGROTATE_CONF="/etc/logrotate.d/hourly-syslog"
CRON_SCRIPT="/etc/cron.hourly/logrotate"

# 写入 logrotate 配置
echo "创建 logrotate 配置文件：$LOGROTATE_CONF"
sudo tee "$LOGROTATE_CONF" > /dev/null <<EOF
/var/log/syslog /var/log/daemon.log {
    hourly
    missingok
    notifempty
    rotate 0
    copytruncate
    create 640 root adm
    sharedscripts
    postrotate
        /usr/lib/rsyslog/rsyslog-rotate || true
    endscript
}
EOF

# 写入 cron.hourly 执行脚本
echo "创建每小时执行脚本：$CRON_SCRIPT"
sudo tee "$CRON_SCRIPT" > /dev/null <<EOF
#!/bin/bash
/usr/sbin/logrotate -f /etc/logrotate.d/hourly-syslog
EOF

# 设置执行权限
sudo chmod +x "$CRON_SCRIPT"

# 立即执行一次以测试
echo "立即测试 logrotate 运行..."
sudo /usr/sbin/logrotate -f "$LOGROTATE_CONF"

echo -e "\n✅ 安装完成：syslog 和 daemon.log 将每小时清空一次。"
