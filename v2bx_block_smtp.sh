#!/usr/bin/env bash
# 适用于当前部署结构：/etc/V2bX/<实例>/config.json、route*.json。
# 仅添加 TCP 25/465/587/2525 拦截，不修改其他路由或系统防火墙。
set -Eeuo pipefail
umask 077

if (( EUID != 0 )); then
    echo '请用 root 执行：sudo bash v2bx-block-smtp.sh' >&2
    exit 1
fi
for required in jq find mktemp cp mv chmod chown realpath systemctl; do
    command -v "$required" >/dev/null || { echo "缺少命令：$required" >&2; exit 1; }
done

config_root="${V2BX_CONFIG_DIR:-/etc/V2bX}"
backup_root="${V2BX_BACKUP_DIR:-/var/backups/v2bx-smtp-guard}"
config_root=$(realpath -e -- "$config_root")
[[ -d "$config_root" ]] || { echo "配置目录不存在：$config_root" >&2; exit 1; }
guard='{"type":"field","network":"tcp","port":"25,465,587,2525","outboundTag":"block"}'

declare -A candidates=() route_outbounds=() service_routes=() active_services=()
declare -a changed_files=() staged_files=() saved_files=() restart_services=()
backup_dir=''
committed=0
finished=0

fail() { echo "错误：$*" >&2; exit 1; }

resolve_route() {
    local resolved
    resolved=$(realpath -e -- "$1") || return 1
    [[ "$resolved" == "$config_root/"* ]] || { echo "路由文件不在 $config_root 内：$resolved" >&2; return 1; }
    printf '%s\n' "$resolved"
}

cleanup() {
    local status=$? i unit restore_ok=1
    trap - EXIT INT TERM
    set +e
    if (( ! finished && committed > 0 )); then
        echo '修改或服务检查失败，正在恢复本次备份……' >&2
        for ((i=0; i<committed; i++)); do
            if ! cp -p -- "${saved_files[i]}" "${changed_files[i]}"; then
                restore_ok=0
                echo "恢复失败：${changed_files[i]}；备份：${saved_files[i]}" >&2
            fi
        done
        if (( restore_ok )); then
            for unit in "${restart_services[@]}"; do
                systemctl restart "$unit" || echo "恢复配置后仍无法重启：$unit" >&2
            done
        fi
        echo "备份目录：$backup_dir" >&2
    fi
    for staged in "${staged_files[@]}"; do
        [[ -e "$staged" ]] && rm -f -- "$staged"
    done
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# 同时覆盖默认路由和分流路由，避免以后切换开关时失去拦截。
while IFS= read -r -d '' route; do
    resolved=$(resolve_route "$route") || fail "无法读取路由：$route"
    candidates["$resolved"]=1
done < <(find "$config_root" \( -type f -o -type l \) \( -name route.json -o -name route_default.json \) -print0)

# 读取各实例实际配置的路径，也覆盖自定义文件名的 Xray 路由。
while IFS= read -r -d '' config; do
    jq -e 'type == "object"' "$config" >/dev/null || fail "主配置 JSON 无效：$config"
    instance_dir=$(dirname -- "$config")
    if [[ "$instance_dir" == "$config_root" ]]; then
        unit='V2bX.service'
    else
        unit="v2bx_$(basename -- "$instance_dir").service"
    fi
    while IFS= read -r core; do
        route=$(jq -r '.RouteConfigPath // empty' <<< "$core")
        [[ -n "$route" ]] || fail "Xray 核心未配置 RouteConfigPath：$config"
        [[ "$route" == /* ]] || fail "请先将 RouteConfigPath 改为绝对路径：$config"
        resolved=$(resolve_route "$route") || fail "实际使用的路由不存在或不在配置目录：$route"
        outbound=$(jq -r '.OutboundConfigPath // empty' <<< "$core")
        [[ "$outbound" == /* && -f "$outbound" ]] || fail "OutboundConfigPath 必须是有效的绝对路径：$config"
        jq -e 'type == "array" and any(.[]; .tag == "block" and .protocol == "blackhole")' "$outbound" >/dev/null \
            || fail "出站配置缺少 block/blackhole，未做修改：$outbound"
        candidates["$resolved"]=1
        route_outbounds["$resolved"]="$outbound"
        service_routes["$unit|$resolved"]=1
        if systemctl is-active --quiet "$unit"; then
            active_services["$unit"]=1
        fi
    done < <(jq -c '.Cores[]? | select((.Type // "" | ascii_downcase) == "xray")' "$config")
done < <(find "$config_root" -type f -name config.json -print0)

(( ${#candidates[@]} > 0 )) || fail "在 $config_root 中未找到路由配置"

# 所有文件先校验、生成临时版本；全部成功后才替换正式配置。
for route in "${!candidates[@]}"; do
    jq -e 'type == "object" and (.rules | type == "array")' "$route" >/dev/null \
        || fail "路由 JSON 或 rules 数组无效：$route"
    if [[ -z "${route_outbounds[$route]:-}" ]]; then
        directory=$(dirname -- "$route")
        if [[ "$(basename -- "$route")" == 'route_default.json' ]]; then
            possible_outbounds=("$directory/outbounds_default.json")
        else
            possible_outbounds=("$directory/outbounds.json" "$directory/custom_outbound.json")
        fi
        found=0
        for outbound in "${possible_outbounds[@]}"; do
            if [[ -f "$outbound" ]] && jq -e 'type == "array" and any(.[]; .tag == "block" and .protocol == "blackhole")' "$outbound" >/dev/null; then
                found=1
                break
            fi
        done
        (( found )) || fail "找不到配套的 block/blackhole 出站配置：$route"
    fi
    if jq -e --argjson guard "$guard" '.rules[0] == $guard' "$route" >/dev/null; then
        echo "已存在，跳过：$route"
        continue
    fi
    staged=$(mktemp "${route}.smtp-guard.XXXXXX")
    staged_files+=("$staged")
    jq --argjson guard "$guard" '.rules = [$guard] + [.rules[] | select(. != $guard)]' "$route" > "$staged"
    jq -e --argjson guard "$guard" '.rules[0] == $guard' "$staged" >/dev/null || fail "新路由校验失败：$route"
    chmod --reference="$route" "$staged"
    chown --reference="$route" "$staged"
    changed_files+=("$route")
done

if (( ${#changed_files[@]} == 0 )); then
    finished=1
    echo '全部路由均已有首条 SMTP 拦截规则，无需修改或重启。'
    exit 0
fi

# 只有“实际路由发生变化且原本正在运行”的节点需要重启。
for unit in "${!active_services[@]}"; do
    for route in "${changed_files[@]}"; do
        if [[ -n "${service_routes[$unit|$route]:-}" ]]; then
            restart_services+=("$unit")
            break
        fi
    done
done

mkdir -p -- "$backup_root"
backup_dir=$(mktemp -d "$backup_root/$(date +%Y%m%d-%H%M%S).XXXXXX")
for route in "${changed_files[@]}"; do
    saved="$backup_dir/${route#"$config_root/"}"
    mkdir -p -- "$(dirname -- "$saved")"
    cp -p -- "$route" "$saved"
    saved_files+=("$saved")
done

for ((i=0; i<${#changed_files[@]}; i++)); do
    committed=$((i+1))
    mv -f -- "${staged_files[i]}" "${changed_files[i]}"
    echo "已添加：${changed_files[i]}"
done

for unit in "${restart_services[@]}"; do
    echo "重启原本运行的节点：$unit"
    systemctl restart "$unit" || fail "重启失败：$unit"
done
if (( ${#restart_services[@]} > 0 )); then
    sleep 3
    for unit in "${restart_services[@]}"; do
        systemctl is-active --quiet "$unit" || fail "重启后未保持运行：$unit"
    done
fi

finished=1
echo "完成：修改 ${#changed_files[@]} 个路由文件，重启 ${#restart_services[@]} 个原本运行的节点。"
echo '已将 TCP 25、465、587、2525 的拦截规则置于首位。原本停用的节点保持停用。'
echo "原配置备份：$backup_dir"
echo '提示：邮件客户端通过这些节点连接上述发信端口会被拒绝。'
