#!/bin/bash
SCRIPT_PATH="/usr/local/bin/clear_archivelog.sh"
CRON_JOB="0 5 * * * $SCRIPT_PATH >/dev/null 2>&1"

# 1. 创建清理脚本
echo "创建脚本 $SCRIPT_PATH..."
cat <<EOF > "$SCRIPT_PATH"
#!/bin/bash
find /var/log/V2bX/archive -type f -delete
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

echo "已添加定时任务：每天凌晨 5:00 自动清理日志"
