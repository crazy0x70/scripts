#!/bin/bash

set -e

VERSION="1.0.1"
VERSION_DATE="2025-10-14"

INSTALL_PATH="/usr/local/bin"
GCPSC_SCRIPT="$INSTALL_PATH/gcpsc"
CONFIG_DIR="/etc/gcpsc"
CONFIG_FILE="$CONFIG_DIR/config.json"
LASTCHECK_DIR="$CONFIG_DIR/lastcheck"
SCRIPT_URL="https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh"

if [ -w "/var/log" ]; then
    LOG_FILE="/var/log/gcpsc.log"
else
    LOG_FILE="/tmp/gcpsc.log"
fi

LOGO="
========================================================
       Google Cloud Spot Instance 保活服务
                Version: $VERSION
                Date: $VERSION_DATE
                 (by crazy0x70)
========================================================
"

if [ -n "$SUDO_USER" ] && [ "$HOME" = "/root" ]; then
    ORIGINAL_USER_HOME=$(eval echo "~$SUDO_USER" 2>/dev/null)
    ORIGINAL_USER_HOME=${ORIGINAL_USER_HOME:-$HOME}
else
    ORIGINAL_USER_HOME="$HOME"
fi

MAX_PARALLEL_STARTS=5

expand_user_path() {
    local input="$1"
    if [ -z "$input" ]; then
        echo ""
        return 1
    fi

    case "$input" in
        "~") echo "$ORIGINAL_USER_HOME" ;;
        "~/"*) echo "$ORIGINAL_USER_HOME/${input:2}" ;;
        *) echo "$input" ;;
    esac
}

sanitize_account_key_filename() {
    echo "$1" | tr -c 'A-Za-z0-9._-' '_'
}

store_service_account_key() {
    local account_email="$1"
    local source_path="$2"
    local dest_dir="$CONFIG_DIR/keys"
    local sanitized
    sanitized=$(sanitize_account_key_filename "$account_email")
    local dest_path="$dest_dir/${sanitized}.json"

    mkdir -p "$dest_dir"
    chmod 700 "$dest_dir" 2>/dev/null || true

    if [ "$source_path" != "$dest_path" ]; then
        cp "$source_path" "$dest_path" || return 1
    fi

    chmod 600 "$dest_path"
    echo "$dest_path"
}

persist_account_entry() {
    local account="$1"
    local type="$2"
    local key_file="$3"

    if jq -e --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE" >/dev/null 2>&1; then
        if [ "$type" = "service" ]; then
            jq --arg acc "$account" --arg file "$key_file" '
                .accounts = (.accounts | map(
                    if .account == $acc then
                        (.projects = (.projects // []))
                        | (.type = "service")
                        | (.key_file = $file)
                    else .
                    end
                ))
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        else
            jq --arg acc "$account" '
                .accounts = (.accounts | map(
                    if .account == $acc then
                        (.projects = (.projects // []))
                        | (.type = "user")
                        | (if has("key_file") then del(.key_file) else . end)
                    else .
                    end
                ))
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
    else
        if [ "$type" = "service" ]; then
            jq --arg acc "$account" --arg file "$key_file" '
                .accounts += [{"account": $acc, "type": "service", "key_file": $file, "projects": []}]
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        else
            jq --arg acc "$account" '
                .accounts += [{"account": $acc, "type": "user", "projects": []}]
            ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
    fi
}

cleanup_lastcheck_files() {
    local account="$1"
    local sanitized="${account//[@.]/_}_"
    rm -f "$LASTCHECK_DIR"/"${sanitized}"* 2>/dev/null || true
}

remove_account_entry() {
    local account="$1"
    local acc_info
    acc_info=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE")

    if [ -z "$acc_info" ] || [ "$acc_info" = "null" ]; then
        echo "账号 $account 不存在"
        return 1
    fi

    local key_file
    key_file=$(echo "$acc_info" | jq -r '.key_file // ""')

    jq --arg acc "$account" '
        .accounts = (.accounts | map(select(.account != $acc)))
    ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"

    if [ -n "$key_file" ] && [[ "$key_file" == "$CONFIG_DIR/keys/"* ]]; then
        rm -f "$key_file"
    fi

    cleanup_lastcheck_files "$account"
    gcloud auth revoke "$account" >/dev/null 2>&1 || true
    log INFO "已删除账号: $account"
    return 0
}

check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 或 sudo 运行此脚本！"
        exit 1
    fi
}

log() {
    local level=$1
    shift
    local msg="$@"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" | tee -a "$LOG_FILE"
}

init_dirs() {
    mkdir -p "$CONFIG_DIR" "$LASTCHECK_DIR"
    touch "$LOG_FILE"
    [ -f "$CONFIG_FILE" ] || echo '{"version":"'$VERSION'","accounts":[]}' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"
}

ensure_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log INFO "正在安装 jq..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y jq
        elif [ -f /etc/redhat-release ]; then
            yum install -y epel-release
            yum install -y jq
        else
            log ERROR "无法自动安装 jq，请手动安装"
            exit 1
        fi
    fi
}

ensure_gcloud() {
    if command -v gcloud >/dev/null 2>&1; then
        return 0
    fi
    
    log INFO "正在安装 Google Cloud SDK..."
    
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYS="$ID"
    else
        SYS="unknown"
    fi
    
    case "$SYS" in
        ubuntu|debian)
            apt-get update
            apt-get install -y apt-transport-https ca-certificates gnupg curl
            echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
            curl https://packages.cloud.google.com/apt/doc/apt-key.gpg | gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
            apt-get update && apt-get install -y google-cloud-sdk
            ;;
        centos|rhel|rocky|almalinux|fedora)
            cat > /etc/yum.repos.d/google-cloud-sdk.repo <<EOF
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-x86_64
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg
       https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOF
            yum install -y google-cloud-sdk
            ;;
        *)
            log ERROR "不支持的操作系统: $SYS"
            exit 1
            ;;
    esac
    
    if ! command -v gcloud >/dev/null 2>&1; then
        log ERROR "gcloud 安装失败"
        exit 1
    fi
    
    log INFO "Google Cloud SDK 安装成功"
}

ensure_crontab() {
    if ! command -v crontab >/dev/null 2>&1; then
        log INFO "正在安装 crontab..."
        if [ -f /etc/debian_version ]; then
            apt-get update && apt-get install -y cron
            systemctl enable cron && systemctl start cron
        elif [ -f /etc/redhat-release ]; then
            yum install -y cronie
            systemctl enable crond && systemctl start crond
        fi
    fi
    
    if ! crontab -l 2>/dev/null | grep -q "$GCPSC_SCRIPT check"; then
        (crontab -l 2>/dev/null ; echo "* * * * * $GCPSC_SCRIPT check >/dev/null 2>&1") | crontab -
        log INFO "已添加定时任务"
    fi
}

perform_install() {
    check_root
    echo "$LOGO"
    echo "正在安装 GCP Spot Check 服务..."
    
    init_dirs
    
    ensure_jq
    ensure_gcloud
    ensure_crontab
    
    log INFO "正在安装 gcpsc 命令..."
    curl -fsSL "$SCRIPT_URL" -o "$GCPSC_SCRIPT"
    chmod +x "$GCPSC_SCRIPT"
    
    ln -sf "$GCPSC_SCRIPT" /usr/bin/gcpsc
    
    log INFO "安装完成！版本: $VERSION"
    echo
    echo "========================================="
    echo "安装成功！"
    echo "版本: $VERSION"
    echo "使用命令: sudo gcpsc"
    echo "日志文件: $LOG_FILE"
    echo "配置目录: $CONFIG_DIR"
    echo "========================================="
    echo
    echo "现在启动管理界面..."
    sleep 2
    exec "$GCPSC_SCRIPT" __installed__
}

perform_uninstall() {
    check_root
    echo "$LOGO"
    echo "正在卸载 GCP Spot Check 服务..."
    
    read -p "确认要卸载吗？这将删除所有配置和日志 [y/N]: " confirm
    if [[ ! "$confirm" =~ ^[Yy]$ ]]; then
        echo "已取消卸载"
        exit 0
    fi
    
    echo
    echo "正在清理..."
    
    if crontab -l 2>/dev/null | grep -q "$GCPSC_SCRIPT"; then
        (crontab -l 2>/dev/null | grep -v "$GCPSC_SCRIPT") | crontab -
        echo "✓ 已删除定时任务"
    fi
    
    [ -f "$GCPSC_SCRIPT" ] && rm -f "$GCPSC_SCRIPT" && echo "✓ 已删除主程序"
    [ -L "/usr/bin/gcpsc" ] && rm -f /usr/bin/gcpsc && echo "✓ 已删除命令链接"
    
    [ -d "$CONFIG_DIR" ] && rm -rf "$CONFIG_DIR" && echo "✓ 已删除配置目录"
    
    [ -f "$LOG_FILE" ] && rm -f "$LOG_FILE" && echo "✓ 已删除日志文件"
    
    echo
    echo "========================================="
    echo "卸载完成！"
    echo "感谢使用 GCP Spot Check 服务"
    echo "========================================="
}

activate_account() {
    local account=$1
    local acc_info=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE")
    
    if [ -z "$acc_info" ] || [ "$acc_info" = "null" ]; then
        log ERROR "账号 $account 未在配置文件中找到"
        return 1
    fi

    local acc_type
    acc_type=$(echo "$acc_info" | jq -r '.type // "service"')
    
    if [ "$acc_type" = "service" ]; then
        local key_file
        key_file=$(echo "$acc_info" | jq -r '.key_file // ""')
        if [ -z "$key_file" ] || [ ! -f "$key_file" ]; then
            log ERROR "账号 $account 的密钥文件不存在，请重新导入"
            return 1
        fi
        if ! gcloud auth activate-service-account --key-file="$key_file" >/dev/null 2>&1; then
            log ERROR "账号 $account 激活失败，请检查密钥文件权限与内容"
            return 1
        fi
    else
        if ! gcloud config set account "$account" >/dev/null 2>&1; then
            log ERROR "无法切换到账号 $account，请检查登录状态"
            return 1
        fi
    fi

    return 0
}

check_single_instance() {
    local account=$1
    local project=$2
    local zone=$3
    local instance=$4
    
    if ! activate_account "$account"; then
        log ERROR "[$account/$project/$zone/$instance] 激活账号失败，无法执行检查"
        return 1
    fi
    
    local status=$(gcloud compute instances describe "$instance" \
        --zone="$zone" --project="$project" \
        --format='get(status)' 2>/dev/null || echo "ERROR")
    
    log INFO "[$account/$project/$zone/$instance] 状态: $status"
    
    if [ "$status" != "RUNNING" ] && [ "$status" != "ERROR" ]; then
        log WARN "[$account/$project/$zone/$instance] 不在运行状态，正在启动..."
        if gcloud compute instances start "$instance" \
            --zone="$zone" --project="$project" --quiet 2>/dev/null; then
            log INFO "[$account/$project/$zone/$instance] 启动命令已发送"
            
            echo "等待实例启动..."
            local max_wait=30
            local waited=0
            while [ $waited -lt $max_wait ]; do
                sleep 2
                local new_status=$(gcloud compute instances describe "$instance" \
                    --zone="$zone" --project="$project" \
                    --format='get(status)' 2>/dev/null || echo "ERROR")
                if [ "$new_status" = "RUNNING" ]; then
                    log INFO "[$account/$project/$zone/$instance] 实例已成功启动"
                    break
                fi
                waited=$((waited + 2))
            done
        else
            log ERROR "[$account/$project/$zone/$instance] 启动失败"
        fi
    elif [ "$status" = "RUNNING" ]; then
        echo "实例状态正常：RUNNING"
    fi
    
    local lastcheck_file="$LASTCHECK_DIR/${account//[@.]/_}_${project}_${zone}_${instance}"
    echo "$(date +%s)" > "$lastcheck_file"
}

add_account() {
    echo
    echo "===== 添加 Google Cloud 账号 ====="
    echo "1) 使用服务账号 JSON 密钥文件（推荐）"
    echo "2) 粘贴 JSON 密钥内容"
    echo "3) 使用个人 Google 账号登录"
    echo "0) 返回主菜单"
    
    read -p "请选择 [0-3]: " choice
    
    case $choice in
        1)
            read -p "请输入 JSON 密钥文件的完整路径: " json_path
            json_path=$(expand_user_path "$json_path")
            if [ ! -f "$json_path" ]; then
                echo "文件不存在！"
                return 1
            fi

            local account_email
            account_email=$(jq -r '.client_email // empty' "$json_path" 2>/dev/null)
            if [ -z "$account_email" ]; then
                echo "无法从密钥文件读取账号信息"
                return 1
            fi

            local stored_key
            stored_key=$(store_service_account_key "$account_email" "$json_path") || {
                echo "保存密钥文件失败，请检查权限"
                return 1
            }
            
            gcloud auth activate-service-account --key-file="$stored_key" 2>/dev/null || {
                echo "认证失败，请检查密钥文件"
                return 1
            }
            
            local account="$account_email"

            persist_account_entry "$account" "service" "$stored_key"
            
            log INFO "成功添加服务账号: $account"
            
            read -p "是否自动发现并导入该账号下的所有实例？[y/N]: " auto_discover
            if [[ "$auto_discover" =~ ^[Yy]$ ]]; then
                auto_discover_resources "$account"
            fi
            ;;
            
        2)
            echo "请粘贴 JSON 密钥内容，按 Ctrl+D 结束："
            json_file="/tmp/gcpsc_key_$(date +%s).json"
            cat > "$json_file"

            local account_email
            account_email=$(jq -r '.client_email // empty' "$json_file" 2>/dev/null)
            if [ -z "$account_email" ]; then
                echo "密钥内容格式不正确"
                rm -f "$json_file"
                return 1
            fi

            local stored_key
            stored_key=$(store_service_account_key "$account_email" "$json_file") || {
                echo "保存密钥文件失败，请检查权限"
                rm -f "$json_file"
                return 1
            }
            
            [ "$stored_key" != "$json_file" ] && rm -f "$json_file"

            gcloud auth activate-service-account --key-file="$stored_key" 2>/dev/null || {
                echo "认证失败，请检查密钥内容"
                rm -f "$stored_key"
                return 1
            }
            
            local account="$account_email"

            persist_account_entry "$account" "service" "$stored_key"
            
            log INFO "成功添加服务账号: $account"
            
            read -p "是否自动发现并导入该账号下的所有实例？[y/N]: " auto_discover
            if [[ "$auto_discover" =~ ^[Yy]$ ]]; then
                auto_discover_resources "$account"
            fi
            ;;
            
        3)
            echo "即将打开浏览器认证链接..."
            gcloud auth login --no-launch-browser
            
            account=$(gcloud config get-value account 2>/dev/null)
            if [ -z "$account" ]; then
                echo "未检测到登录账号，请确认认证流程是否完成"
                return 1
            fi

            persist_account_entry "$account" "user"
            
            log INFO "成功添加个人账号: $account"
            
            read -p "是否自动发现并导入该账号下的所有实例？[y/N]: " auto_discover
            if [[ "$auto_discover" =~ ^[Yy]$ ]]; then
                auto_discover_resources "$account"
            fi
            ;;
            
        0)
            return 0
            ;;
            
        *)
            echo "无效选择"
            ;;
    esac
}

auto_discover_resources() {
    local account=$1
    
    echo
    echo "正在扫描账号下的所有资源，请稍候..."
    
    if ! activate_account "$account"; then
        echo "账号激活失败，请检查认证信息"
        return 1
    fi
    
    local projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
    
    if [ -z "$projects" ]; then
        echo "未发现任何项目"
        return 1
    fi
    
    local total_instances=0
    local new_instances=0
    local default_interval=10
    
    echo "发现的项目："
    echo "$projects"
    echo
    
    read -p "请输入默认检查间隔（分钟，默认10）: " user_interval
    [ -n "$user_interval" ] && default_interval=$user_interval
    
    echo
    echo "开始导入实例..."
    
    while IFS= read -r project_id; do
        [ -z "$project_id" ] && continue
        echo "正在扫描项目: $project_id"
        
        local instances_info=$(gcloud compute instances list --project="$project_id" \
            --format="csv[no-heading](name,zone,status)" 2>/dev/null)
        
        if [ -z "$instances_info" ]; then
            echo "  项目 $project_id 中没有实例"
            continue
        fi
        
        local project_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" \
            '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .id' \
            "$CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$project_exists" ]; then
            jq --arg acc "$account" --arg proj "$project_id" \
                '(.accounts[] | select(.account == $acc) | .projects) += [{"id": $proj, "zones": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
        
        while IFS=',' read -r instance_name zone_full status; do
            [ -z "$instance_name" ] && continue
            
            zone=$(echo "$zone_full" | rev | cut -d'/' -f1 | rev)
            
            total_instances=$((total_instances + 1))
            echo "  发现实例: $instance_name (区域: $zone, 状态: $status)"
            
            local zone_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$zone_exists" ]; then
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones) += [{"name": $z, "instances": []}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            fi
            
            local instance_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[] | select(.name == $inst) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$instance_exists" ]; then
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" --argjson int "$default_interval" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) += [{"name": $inst, "interval": $int}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                
                new_instances=$((new_instances + 1))
                log INFO "导入实例: $account/$project_id/$zone/$instance_name"
                
                echo "  立即检查实例状态..."
                check_single_instance "$account" "$project_id" "$zone" "$instance_name"
            else
                echo "    实例已存在，跳过"
            fi
        done <<< "$instances_info"
    done <<< "$projects"
    
    echo
    echo "========================================="
    echo "自动发现完成！"
    echo "发现实例总数: $total_instances"
    echo "新导入实例数: $new_instances"
    echo "========================================="
    log INFO "账号 $account 自动发现完成，新导入 $new_instances 个实例（共发现 $total_instances 个）"
    
    read -p "按回车继续..."
}

delete_account_menu() {
    local accounts_list=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
    if [ -z "$accounts_list" ]; then
        echo "当前没有可删除的账号"
        return
    fi

    echo
    echo "===== 删除账号 ====="
    local idx=1
    while IFS= read -r acc; do
        echo "$idx) $acc"
        idx=$((idx+1))
    done <<< "$accounts_list"

    read -p "请输入要删除的账号序号: " del_choice
    local target=$(echo "$accounts_list" | sed -n "${del_choice}p")
    if [ -z "$target" ]; then
        echo "无效选择"
        return
    fi

    read -p "确认删除账号 $target 及其所有配置？[y/N]: " confirm
    if [[ "$confirm" =~ ^[Yy]$ ]]; then
        if remove_account_entry "$target"; then
            echo "账号 $target 已删除"
        else
            echo "删除账号失败，请检查日志"
        fi
    else
        echo "已取消删除操作"
    fi
}

show_accounts_menu() {
    local accounts=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$accounts" ]; then
        echo "还没有添加任何账号，请先添加账号"
        add_account
        return
    fi
    echo
    echo "===== 已添加的账号 ====="
    
    local i=1
    while IFS= read -r acc; do
        local count=$(jq -r --arg acc "$acc" \
            '[.accounts[] | select(.account == $acc) | .projects[].zones[].instances[]] | length' \
            "$CONFIG_FILE" 2>/dev/null)
        echo "$i) $acc (监控 $count 个实例)"
        i=$((i+1))
    done <<< "$accounts"
    
    echo
    echo "a) 添加新账号"
    echo "d) 删除账号"
    echo "0) 返回主菜单"
    
    read -p "请选择 [数字/a/d/0]: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    elif [ "$choice" = "a" ]; then
        add_account
        show_accounts_menu
    elif [ "$choice" = "d" ] || [ "$choice" = "D" ]; then
        delete_account_menu
        show_accounts_menu
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_account=$(echo "$accounts" | sed -n "${choice}p")
        if [ -n "$selected_account" ]; then
            show_account_instances "$selected_account"
        else
            echo "无效选择"
        fi
    else
        echo "无效输入"
    fi
}

show_account_instances() {
    local account=$1
    
    while true; do
        echo
        echo "===== 账号: $account ====="
        echo
        
        local instances_list=$(jq -r --arg acc "$account" '
            .accounts[] | select(.account == $acc) | 
            .projects[] as $p | 
            $p.zones[] as $z | 
            $z.instances[] | 
            "\($p.id)|\($z.name)|\(.name)|\(.interval)"
        ' "$CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$instances_list" ]; then
            echo "该账号下没有监控的实例"
            echo
            echo "1) 自动发现并导入所有实例"
            echo "0) 返回"
            
            read -p "请选择 [0-1]: " choice
            case $choice in
                1) auto_discover_resources "$account" ;;
                0) return 0 ;;
            esac
            continue
        fi
        
        echo "实例列表："
        echo "-----------------------------------------------------------"
        printf "%-3s %-30s %-20s %-10s\n" "No" "实例名" "区域" "检查间隔"
        echo "-----------------------------------------------------------"
        
        local i=1
        while IFS='|' read -r proj zone inst interval; do
            printf "%-3d %-30s %-20s %d分钟\n" "$i" "$inst" "$zone" "$interval"
            i=$((i+1))
        done <<< "$instances_list"
        
        echo "-----------------------------------------------------------"
        echo
        echo "操作选项："
        echo "1) 立即检查指定实例"
        echo "2) 修改实例检查间隔"
        echo "3) 批量修改所有实例检查间隔"
        echo "4) 删除实例监控"
        echo "5) 自动发现新实例"
        echo "6) 查看实例详情"
        echo "0) 返回"
        
        read -p "请选择 [0-6]: " choice
        
        case $choice in
            1)
                read -p "请输入要检查的实例序号: " inst_num
                local selected=$(echo "$instances_list" | sed -n "${inst_num}p")
                if [ -n "$selected" ]; then
                    IFS='|' read -r proj zone inst interval <<< "$selected"
                    echo "正在检查实例 $inst ..."
                    check_single_instance "$account" "$proj" "$zone" "$inst"
                    read -p "按回车继续..."
                fi
                ;;
                
            2)
                read -p "请输入要修改的实例序号: " inst_num
                local selected=$(echo "$instances_list" | sed -n "${inst_num}p")
                if [ -n "$selected" ]; then
                    IFS='|' read -r proj zone inst old_interval <<< "$selected"
                    read -p "请输入新的检查间隔（分钟，当前: $old_interval）: " new_interval
                    if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -ge 1 ]; then
                        jq --arg acc "$account" --arg proj "$proj" --arg z "$zone" --arg inst "$inst" --argjson int "$new_interval" \
                            '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[] | select(.name == $inst) | .interval) = $int' \
                            "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                        echo "已更新 $inst 的检查间隔为 $new_interval 分钟"
                        log INFO "更新实例检查间隔: $account/$proj/$zone/$inst -> ${new_interval}分钟"
                        
                        echo "立即执行一次检查..."
                        check_single_instance "$account" "$proj" "$zone" "$inst"
                    fi
                fi
                ;;
                
            3)
                read -p "请输入新的检查间隔（分钟）: " new_interval
                if [[ "$new_interval" =~ ^[0-9]+$ ]] && [ "$new_interval" -ge 1 ]; then
                    jq --arg acc "$account" --argjson int "$new_interval" \
                        '(.accounts[] | select(.account == $acc) | .projects[].zones[].instances[].interval) = $int' \
                        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                    echo "已更新所有实例的检查间隔为 $new_interval 分钟"
                    log INFO "账号 $account 所有实例检查间隔更新为 $new_interval 分钟"
                    
                    read -p "是否立即检查所有实例？[y/N]: " check_now
                    if [[ "$check_now" =~ ^[Yy]$ ]]; then
                        echo "正在检查所有实例..."
                        while IFS='|' read -r proj zone inst interval; do
                            check_single_instance "$account" "$proj" "$zone" "$inst"
                        done <<< "$instances_list"
                    fi
                fi
                ;;
                
            4)
                read -p "请输入要删除的实例序号: " inst_num
                local selected=$(echo "$instances_list" | sed -n "${inst_num}p")
                if [ -n "$selected" ]; then
                    IFS='|' read -r proj zone inst interval <<< "$selected"
                    read -p "确认删除实例 $inst 的监控？[y/N]: " confirm
                    if [[ "$confirm" =~ ^[Yy]$ ]]; then
                        jq --arg acc "$account" --arg proj "$proj" --arg z "$zone" --arg inst "$inst" '
                            .accounts = (.accounts | map(
                                if .account == $acc then
                                    .projects = ((.projects // []) | map(
                                        if .id == $proj then
                                            .zones = ((.zones // []) | map(
                                                if .name == $z then
                                                    .instances = ((.instances // []) | map(select(.name != $inst)))
                                                else .
                                                end
                                            ) | map(select((.instances | length) > 0)))
                                        else .
                                        end
                                    ) | map(select((.zones | length) > 0)))
                                else .
                                end
                            ))
                        ' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                        rm -f "$LASTCHECK_DIR/${account//[@.]/_}_${proj}_${zone}_${inst}"
                        echo "已删除实例监控"
                        log INFO "删除实例监控: $account/$proj/$zone/$inst"
                    fi
                fi
                ;;
                
            5)
                auto_discover_resources "$account"
                ;;
                
            6)
                read -p "请输入要查看的实例序号: " inst_num
                local selected=$(echo "$instances_list" | sed -n "${inst_num}p")
                if [ -n "$selected" ]; then
                    IFS='|' read -r proj zone inst interval <<< "$selected"
                    echo
                    echo "实例详情："
                    echo "  账号: $account"
                    echo "  项目: $proj"
                    echo "  区域: $zone"
                    echo "  实例: $inst"
                    echo "  检查间隔: $interval 分钟"
                    
                    local lastcheck_file="$LASTCHECK_DIR/${account//[@.]/_}_${proj}_${zone}_${inst}"
                    if [ -f "$lastcheck_file" ]; then
                        local lastcheck=$(cat "$lastcheck_file")
                        echo "  最后检查: $(date -d "@$lastcheck" "+%Y-%m-%d %H:%M:%S" 2>/dev/null || date -r "$lastcheck" "+%Y-%m-%d %H:%M:%S")"
                    else
                        echo "  最后检查: 尚未执行"
                    fi
                    
                    echo
                    echo "正在获取实例当前状态..."
                    activate_account "$account"
                    local current_status=$(gcloud compute instances describe "$inst" \
                        --zone="$zone" --project="$proj" \
                        --format='get(status)' 2>/dev/null || echo "无法获取")
                    echo "  当前状态: $current_status"
                    
                    echo
                    read -p "按回车继续..."
                fi
                ;;
                
            0)
                return 0
                ;;
                
            *)
                echo "无效选择"
                ;;
        esac
    done
}

check_all_instances() {
    jq -c '.accounts[]?' "$CONFIG_FILE" 2>/dev/null | while read -r account_json; do
        [ -z "$account_json" ] && continue
        local account
        account=$(echo "$account_json" | jq -r '.account')

        if ! activate_account "$account"; then
            continue
        fi

        echo "$account_json" | jq -c '.projects[]?' | while read -r project_json; do
            [ -z "$project_json" ] && continue
            local project
            project=$(echo "$project_json" | jq -r '.id')

            echo "$project_json" | jq -c '.zones[]?' | while read -r zone_json; do
                [ -z "$zone_json" ] && continue
                local zone
                zone=$(echo "$zone_json" | jq -r '.name')

                echo "$zone_json" | jq -c '.instances[]?' | while read -r instance_json; do
                    [ -z "$instance_json" ] && continue
                    local instance
                    instance=$(echo "$instance_json" | jq -r '.name')
                    local interval
                    interval=$(echo "$instance_json" | jq -r '.interval // 10')
                    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -le 0 ]; then
                        interval=10
                    fi

                    local interval_seconds=$((interval * 60))
                    local lastcheck_file="$LASTCHECK_DIR/${account//[@.]/_}_${project}_${zone}_${instance}"
                    local lastcheck=0
                    [ -f "$lastcheck_file" ] && lastcheck=$(cat "$lastcheck_file")

                    local current_time
                    current_time=$(date +%s)
                    if [ $((current_time - lastcheck)) -lt "$interval_seconds" ]; then
                        continue
                    fi

                    local status
                    status=$(gcloud compute instances describe "$instance" \
                        --zone="$zone" --project="$project" \
                        --format='get(status)' 2>/dev/null || echo "ERROR")

                    log INFO "[$account/$project/$zone/$instance] 状态: $status"

                    if [ "$status" != "RUNNING" ] && [ "$status" != "ERROR" ]; then
                        log WARN "[$account/$project/$zone/$instance] 不在运行状态，正在启动..."
                        if gcloud compute instances start "$instance" \
                            --zone="$zone" --project="$project" --quiet --async 2>/dev/null; then
                            log INFO "[$account/$project/$zone/$instance] 已异步发送启动命令"
                        else
                            log ERROR "[$account/$project/$zone/$instance] 启动失败"
                        fi
                    fi

                    echo "$current_time" > "$lastcheck_file"
                done
            done
        done
    done
}

show_statistics() {
    echo
    echo "===== 监控统计 ====="
    echo "版本: $VERSION ($VERSION_DATE)"
    echo
    
    local total_accounts=$(jq '.accounts | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local total_projects=$(jq '[.accounts[].projects[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local total_instances=$(jq '[.accounts[].projects[].zones[].instances[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    echo "账号总数: $total_accounts"
    echo "项目总数: $total_projects"
    echo "实例总数: $total_instances"
    echo
    
    if [ "$total_instances" -gt 0 ]; then
        echo "按账号分组："
        local accounts=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
        while IFS= read -r acc; do
            local count=$(jq -r --arg acc "$acc" \
                '[.accounts[] | select(.account == $acc) | .projects[].zones[].instances[]] | length' \
                "$CONFIG_FILE" 2>/dev/null)
            echo "  $acc: $count 个实例"
        done <<< "$accounts"
        
        echo
        echo "实例检查状态："
        local running_count=0
        local checked_count=0
        local now=$(date +%s)
        
        for lastcheck_file in "$LASTCHECK_DIR"/*; do
            [ -f "$lastcheck_file" ] || continue
            checked_count=$((checked_count + 1))
            local lastcheck=$(cat "$lastcheck_file")
            if [ $((now - lastcheck)) -lt 600 ]; then
                running_count=$((running_count + 1))
            fi
        done
        
        echo "  已检查过的实例: $checked_count"
        echo "  最近10分钟活跃: $running_count"
    fi
    
    echo
    read -p "按回车继续..."
}

show_about() {
    echo
    echo "$LOGO"
    echo
    echo "关于本程序："
    echo "  名称: Google Cloud Spot Instance 保活服务"
    echo "  版本: $VERSION"
    echo "  发布日期: $VERSION_DATE"
    echo "  作者: crazy0x70"
    echo "  GitHub: https://github.com/crazy0x70/"
    echo
    echo "功能特性："
    echo "  • 自动监控 GCP Spot 实例状态"
    echo "  • 实例停止时自动重启"
    echo "  • 支持多账号、多项目管理"
    echo "  • 自动发现并导入实例"
    echo "  • 灵活的检查间隔设置"
    echo "  • 完整的操作日志记录"
    echo
    echo "系统信息："
    echo "  配置目录: $CONFIG_DIR"
    echo "  日志文件: $LOG_FILE"
    echo "  主程序: $GCPSC_SCRIPT"
    echo
    read -p "按回车继续..."
}

main_menu() {
    while true; do
        clear
        echo "$LOGO"
        
        local instances_count=$(jq '[.accounts[].projects[].zones[].instances[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        local accounts_count=$(jq '.accounts | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        
        echo "当前状态: $accounts_count 个账号，$instances_count 个实例"
        echo "日志文件: $LOG_FILE"
        echo
        
        echo "========== 主菜单 =========="
        echo "1) 账号管理"
        echo "2) 快速发现所有资源"
        echo "3) 查看监控统计"
        echo "4) 查看运行日志"
        echo "5) 手动执行一次检查"
        echo "6) 关于"
        echo "0) 退出"
        echo "============================"
        echo
        read -p "请选择 [0-6]: " choice
        
        case $choice in
            1)
                show_accounts_menu
                ;;
            2)
                echo
                echo "===== 快速发现所有资源 ====="
                local accounts=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
                if [ -z "$accounts" ]; then
                    echo "请先添加账号"
                    read -p "按回车继续..."
                else
                    read -p "请输入默认检查间隔（分钟，默认10）: " default_interval
                    default_interval=${default_interval:-10}
                    
                    local total_new=0
                    while IFS= read -r account; do
                        echo
                        echo "处理账号: $account"
                        activate_account "$account"
                        
                        local projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
                        local imported=0
                        
                        while IFS= read -r project_id; do
                            [ -z "$project_id" ] && continue
                            
                            local instances_info=$(gcloud compute instances list --project="$project_id" \
                                --format="csv[no-heading](name,zone)" 2>/dev/null)
                            
                            [ -z "$instances_info" ] && continue
                            
                            local project_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" \
                                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .id' \
                                "$CONFIG_FILE" 2>/dev/null)
                            
                            if [ -z "$project_exists" ]; then
                                jq --arg acc "$account" --arg proj "$project_id" \
                                    '(.accounts[] | select(.account == $acc) | .projects) += [{"id": $proj, "zones": []}]' \
                                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                            fi
                            
                            while IFS=',' read -r instance_name zone_full; do
                                [ -z "$instance_name" ] && continue
                                zone=$(echo "$zone_full" | rev | cut -d'/' -f1 | rev)
                                
                                local instance_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" \
                                    '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[] | select(.name == $inst) | .name' \
                                    "$CONFIG_FILE" 2>/dev/null)
                                
                                if [ -z "$instance_exists" ]; then
                                    local zone_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                                        '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .name' \
                                        "$CONFIG_FILE" 2>/dev/null)
                                    
                                    if [ -z "$zone_exists" ]; then
                                        jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                                            '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones) += [{"name": $z, "instances": []}]' \
                                            "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                                    fi
                                    
                                    jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" --argjson int "$default_interval" \
                                        '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) += [{"name": $inst, "interval": $int}]' \
                                        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                                    
                                    imported=$((imported + 1))
                                    echo "  + $project_id/$zone/$instance_name"
                                    
                                    check_single_instance "$account" "$project_id" "$zone" "$instance_name"
                                fi
                            done <<< "$instances_info"
                        done <<< "$projects"
                        
                        echo "  账号 $account 导入 $imported 个新实例"
                        total_new=$((total_new + imported))
                    done <<< "$accounts"
                    
                    echo
                    echo "批量发现完成！共导入 $total_new 个新实例"
                    log INFO "批量发现完成，共导入 $total_new 个新实例"
                    read -p "按回车继续..."
                fi
                ;;
            3)
                show_statistics
                ;;
            4)
                echo
                echo "===== 最近的日志（最新50条）====="
                tail -n 50 "$LOG_FILE" 2>/dev/null || echo "暂无日志"
                echo
                read -p "按回车继续..."
                ;;
            5)
                echo "正在执行全量检查..."
                check_all_instances
                echo "检查完成！"
                read -p "按回车继续..."
                ;;
            6)
                show_about
                ;;
            0)
                echo
                echo "感谢使用 GCP Spot Check 服务！"
                echo "再见！"
                exit 0
                ;;
            *)
                echo "无效选择"
                sleep 1
                ;;
        esac
    done
}

main() {
    if [ "$1" = "install" ]; then
        perform_install
        exit 0
    elif [ "$1" = "remove" ] || [ "$1" = "uninstall" ]; then
        perform_uninstall
        exit 0
    fi
    
    if [ "$1" = "check" ]; then
        check_all_instances
        exit 0
    fi
    
    if [ "$1" = "version" ] || [ "$1" = "-v" ] || [ "$1" = "--version" ]; then
        echo "GCP Spot Check Version: $VERSION ($VERSION_DATE)"
        exit 0
    fi
    
    if [ ! -f "$GCPSC_SCRIPT" ] && [ "$1" != "__installed__" ]; then
        perform_install
        exit 0
    fi
    
    check_root
    init_dirs
    ensure_jq
    
    local config_version=$(jq -r '.version // "0.0.0"' "$CONFIG_FILE" 2>/dev/null)
    if [ "$config_version" != "$VERSION" ]; then
        jq --arg ver "$VERSION" '.version = $ver' "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        log INFO "配置文件版本已更新至 $VERSION"
    fi
    
    main_menu
}

main "$@"
