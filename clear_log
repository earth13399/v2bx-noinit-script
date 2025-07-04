#!/bin/bash

# 定义定时任务命令
CRON_JOB="0 * * * * echo > /var/log/daemon.log && echo > /var/log/syslog"

# 检查是否已存在相同任务
crontab -l 2>/dev/null | grep -F "$CRON_JOB" >/dev/null
if [ $? -eq 0 ]; then
    echo "定时任务已存在，无需重复添加。"
    exit 0
fi

# 添加任务
(crontab -l 2>/dev/null; echo "$CRON_JOB") | crontab -

echo "定时任务已添加：每小时清空 daemon.log 和 syslog"
