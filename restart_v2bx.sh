#!/bin/bash

# 脚本作用：每天在凌晨 4:00 到 4:59 的随机时间自动重启 V2bX

SCRIPT_PATH="/usr/local/bin/restart_v2bx.sh"
RANDOM_MINUTE=$((RANDOM % 60))
CRON_JOB="$RANDOM_MINUTE 4 * * * $SCRIPT_PATH >/dev/null 2>&1"

# 1. 创建重启脚本
echo "创建脚本 $SCRIPT_PATH..."
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
systemctl daemon-reload
systemctl restart v2bx_*
EOF

# 2. 设置执行权限
chmod +x "$SCRIPT_PATH"
echo "设置执行权限完成。"

# 3. 删除旧的同类任务（如果存在）
TMP_CRON=$(mktemp)
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > "$TMP_CRON"

# 4. 添加新任务
echo "$CRON_JOB" >> "$TMP_CRON"
crontab "$TMP_CRON"
rm "$TMP_CRON"

echo "已添加定时任务：每天凌晨 4:$RANDOM_MINUTE 自动重启 V2bX"
