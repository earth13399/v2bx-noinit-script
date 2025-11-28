#!/bin/bash

# 1. 定义搜索模式
# 解释：匹配 v2bx_*_2????_*.service
# 这里的 2[0-9][0-9][0-9][0-9] 确保只匹配中间数字是以 2 开头的 5 位数
SEARCH_PATTERN="/etc/systemd/system/v2bx_*_2[0-9][0-9][0-9][0-9]_*.service"

echo "========================================================"
echo "正在扫描符合条件的服务 (ID 以 2 开头的 5 位数)..."
echo "========================================================"

# 获取文件列表
TARGET_FILES=$(ls $SEARCH_PATTERN 2>/dev/null)

# 检查是否找到文件
if [ -z "$TARGET_FILES" ]; then
    echo "未找到任何以 2 开头的相关服务文件。"
    echo "如果是 1 开头的服务，脚本已按要求自动忽略。"
    exit 0
fi

# 2. 预演模式：列出将要删除的文件
count=0
for file in $TARGET_FILES; do
    echo "[待删除 Service] $file"
    ((count++))
done

echo "========================================================"
echo "共发现 $count 个服务需要处理。"
echo "警告：此操作将 停止服务、禁止开机自启 并 删除 .service 文件。"
echo "注意：仅清理服务注册，配置文件目录将被保留。"
echo "========================================================"

# 3. 用户确认
read -p "是否确认执行上述删除操作？(输入 Y 确认，任意其他键取消): " confirm

if [[ "$confirm" == "Y" || "$confirm" == "y" ]]; then
    echo ""
    echo "开始执行清理..."
    
    for file in $TARGET_FILES; do
        # 获取文件名
        service_name=$(basename "$file")
        
        echo "-> 正在处理: $service_name"
        
        # 停止服务
        sudo systemctl stop "$service_name" 2>/dev/null
        echo "   [OK] 服务已停止"
        
        # 禁用服务
        sudo systemctl disable "$service_name" 2>/dev/null
        echo "   [OK] 开机自启已禁用"
        
        # 删除 Systemd 服务文件
        sudo rm -f "$file"
        echo "   [OK] 服务文件已删除"

        echo "-----------------------------------"
    done

    # 重载 systemd
    sudo systemctl daemon-reload
    echo "系统服务配置已重载 (Daemon Reloaded)。完成。"
else
    echo "用户取消，未执行任何操作。"
fi
