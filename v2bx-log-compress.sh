#!/usr/bin/env bash
# 将 /usr/local/bin/v2bx-log-compress.sh 写入磁盘并添加 crontab（使用单引号的 here-doc，保证 DATE 在运行时计算）
set -euo pipefail

SCRIPT_PATH="/usr/local/bin/v2bx-log-compress.sh"
CRON_JOB="59 23 * * * $SCRIPT_PATH >/dev/null 2>&1"

echo "创建脚本 $SCRIPT_PATH..."
cat <<'EOF' > "$SCRIPT_PATH"
#!/usr/bin/env bash
# 每天压缩 /var/log/V2bX 目录下的 *.log 文件，并在压缩成功后安全清空原 .log 文件内容

set -euo pipefail

LOGDIR="/var/log/V2bX"
ARCHIVE_ROOT="$LOGDIR/archive"
DATE="$(date +%F)"            # 在脚本运行时计算，例如 2025-12-14
ARCHIVE_DIR="$ARCHIVE_ROOT/$DATE"
LOCK_FILE="/var/lock/v2bx-compress.lock"

# 创建目录
mkdir -p "$ARCHIVE_DIR"

# 加排他锁，避免并发执行
exec 9>"$LOCK_FILE"
if ! flock -n 9; then
  echo "Another instance is running. Exiting."
  exit 0
fi

# 遍历 .log 文件（只在 LOGDIR 根目录下）
find "$LOGDIR" -maxdepth 1 -type f -name '*.log' -print0 |
while IFS= read -r -d '' file; do
  # 跳过 archive 目录下的文件（防止意外匹配）
  case "$file" in
    "$ARCHIVE_ROOT"/*) continue ;;
  esac

  base="$(basename "$file")"
  archive_path="$ARCHIVE_DIR/${base}.${DATE}.gz"

  # 如果文件为空则跳过（可根据需求调整）
  if [ ! -s "$file" ]; then
    echo "Skipping empty file: $file"
    continue
  fi

  # 读取原日志并生成压缩文件，然后清空原文件（保持 inode 不变，适合正在写入的进程）
  if gzip -c -- "$file" > "$archive_path"; then
    # 保证 truncate 成功（比 : > "$file" 更可靠）
    if truncate -s 0 -- "$file"; then
      echo "$(date '+%F %T') Compressed: $file -> $archive_path, truncated original"
    else
      echo "$(date '+%F %T') ERROR: Failed to truncate $file" >&2
    fi
  else
    echo "$(date '+%F %T') ERROR: Failed to compress $file" >&2
    # 如果压缩失败，删除残留的 archive 文件（若有）
    rm -f -- "$archive_path" || true
  fi
done

# 可选：删除超过 N 天的归档（例如保留 30 天）
find "$ARCHIVE_ROOT" -type f -name '*.gz' -mtime +30 -print0 | xargs -r -0 rm -f --

# 释放锁（脚本结束时自动关闭）
exit 0
EOF

# 2. 设置执行权限
chmod +x "$SCRIPT_PATH"
echo "设置执行权限完成。"

# 3. 删除旧的同类任务（如果存在）
TMP_CRON=$(mktemp)
# 如果 crontab 为空或不存在，crontab -l 将返回非 0；使用 || true 以避免脚本退出（set -e）
crontab -l 2>/dev/null | grep -v "$SCRIPT_PATH" > "$TMP_CRON" || true

# 4. 添加新任务（避免重复加入）
# 先检查是否已存在相同任务（严格匹配）
if ! grep -Fxq "$CRON_JOB" "$TMP_CRON" 2>/dev/null; then
  echo "$CRON_JOB" >> "$TMP_CRON"
fi

crontab "$TMP_CRON"
rm -f "$TMP_CRON"

echo "已添加定时任务：每天 23:59 自动压缩日志"
