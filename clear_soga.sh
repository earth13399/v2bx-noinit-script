#!/bin/bash

# Stop all services starting with 'soga_'
for service in $(systemctl list-units --type=service --no-pager --no-legend | grep soga_ | awk '{print $1}'); do
    echo "Stopping $service..."
    systemctl stop "$service"
done

# Disable all services starting with 'soga_'
for service in $(systemctl list-unit-files --type=service --no-pager --no-legend | grep soga_ | awk '{print $1}'); do
    echo "Disabling $service..."
    systemctl disable "$service"
done

# Remove service files starting with 'soga_' from /etc/systemd/system
target_dir="/etc/systemd/system"
find "$target_dir" -type f -name "soga_*" -delete

# Reload systemd daemon
systemctl daemon-reload

systemctl stop soga_*

echo 'success'
