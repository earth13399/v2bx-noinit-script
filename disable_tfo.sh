#!/bin/bash

CONFIG_FILE="/etc/V2bX/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "配置文件不存在: $CONFIG_FILE"
  exit 1
fi

sed -i 's/"EnableTFO": *true/"EnableTFO": false/' "$CONFIG_FILE"

v2bx restart

echo "已将 EnableTFO 设置为 false"
