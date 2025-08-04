#!/bin/bash

CONFIG_FILE="/etc/V2bX/config.json"

# 备份原文件
cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"

# 使用 sed 替换 "connIdle": 180 为 "connIdle": 600
sed -i 's/"connIdle": 180/"connIdle": 600/' "$CONFIG_FILE"

# 使用 sed 替换 "bufferSize": 64 为 "bufferSize": 512
sed -i 's/"bufferSize": 64/"bufferSize": 512/' "$CONFIG_FILE"

v2bx restart

echo "修改完成，已备份原文件为 ${CONFIG_FILE}.bak"
