#!/bin/bash

set -e

# 全局配置
INSTALL_PATH="/usr/local/bin"
GCPSC_SCRIPT="$INSTALL_PATH/gcpsc"
CONFIG_DIR="/etc/gcpsc"
CONFIG_FILE="$CONFIG_DIR/config.json"
LOG_FILE="/var/log/gcpsc.log"
LASTCHECK_DIR="$CONFIG_DIR/lastcheck"
SCRIPT_URL="https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh"

LOGO="
========================================================
       Google Cloud Spot Instance 保活服务
                  Version 3.0
                 (by crazy0x70)
========================================================
"

# 确保以root权限运行
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo "请使用 root 或 sudo 运行此脚本！"
        exit 1
    fi
}

# 日志函数
log() {
    local level=$1
    shift
    local msg="$@"
    echo "[$(date +"%Y-%m-%d %H:%M:%S")] [$level] $msg" | tee -a "$LOG_FILE"
}

# 初始化目录和文件
init_dirs() {
    mkdir -p "$CONFIG_DIR" "$LASTCHECK_DIR"
    touch "$LOG_FILE"
    [ -f "$CONFIG_FILE" ] || echo '{"accounts":[]}' > "$CONFIG_FILE"
    chmod 600 "$CONFIG_FILE"  # 保护配置文件
}

# 检查并安装 jq
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

# 检查并安装 gcloud
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

# 检查并安装 crontab
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
    
    # 确保定时任务存在
    if ! crontab -l 2>/dev/null | grep -q "$GCPSC_SCRIPT check"; then
        (crontab -l 2>/dev/null ; echo "* * * * * $GCPSC_SCRIPT check >/dev/null 2>&1") | crontab -
        log INFO "已添加定时任务"
    fi
}

# 安装脚本到系统
install_script() {
    log INFO "正在安装 gcpsc 命令..."
    
    # 下载最新版本到目标位置
    curl -fsSL "$SCRIPT_URL" -o "$GCPSC_SCRIPT"
    chmod +x "$GCPSC_SCRIPT"
    
    # 创建软链接
    ln -sf "$GCPSC_SCRIPT" /usr/bin/gcpsc
    
    log INFO "安装完成！使用 'gcpsc' 命令进入管理界面"
}

# 激活账号
activate_account() {
    local account=$1
    local acc_info=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc)' "$CONFIG_FILE")
    local acc_type=$(echo "$acc_info" | jq -r '.type')
    
    if [ "$acc_type" = "service" ]; then
        local key_file=$(echo "$acc_info" | jq -r '.key_file')
        gcloud auth activate-service-account --key-file="$key_file" >/dev/null 2>&1
    else
        gcloud config set account "$account" >/dev/null 2>&1
    fi
}

# 添加新账号
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
            if [ ! -f "$json_path" ]; then
                echo "文件不存在！"
                return 1
            fi
            
            gcloud auth activate-service-account --key-file="$json_path" 2>/dev/null || {
                echo "认证失败，请检查密钥文件"
                return 1
            }
            
            account=$(gcloud config get-value account)
            
            # 保存到配置
            jq --arg acc "$account" --arg file "$json_path" \
                '.accounts += [{"account": $acc, "type": "service", "key_file": $file, "projects": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            
            log INFO "成功添加服务账号: $account"
            
            # 询问是否自动发现资源
            read -p "是否自动发现并导入该账号下的所有实例？[y/N]: " auto_discover
            if [[ "$auto_discover" =~ ^[Yy]$ ]]; then
                auto_discover_resources "$account"
            fi
            ;;
            
        2)
            echo "请粘贴 JSON 密钥内容，按 Ctrl+D 结束："
            json_file="/tmp/gcpsc_key_$(date +%s).json"
            cat > "$json_file"
            
            gcloud auth activate-service-account --key-file="$json_file" 2>/dev/null || {
                echo "认证失败，请检查密钥内容"
                rm -f "$json_file"
                return 1
            }
            
            account=$(gcloud config get-value account)
            
            # 移动密钥文件到配置目录
            key_file="$CONFIG_DIR/keys/${account}.json"
            mkdir -p "$CONFIG_DIR/keys"
            mv "$json_file" "$key_file"
            chmod 600 "$key_file"
            
            # 保存到配置
            jq --arg acc "$account" --arg file "$key_file" \
                '.accounts += [{"account": $acc, "type": "service", "key_file": $file, "projects": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            
            log INFO "成功添加服务账号: $account"
            
            # 询问是否自动发现资源
            read -p "是否自动发现并导入该账号下的所有实例？[y/N]: " auto_discover
            if [[ "$auto_discover" =~ ^[Yy]$ ]]; then
                auto_discover_resources "$account"
            fi
            ;;
            
        3)
            echo "即将打开浏览器认证链接..."
            gcloud auth login --no-launch-browser
            
            account=$(gcloud config get-value account)
            
            # 保存到配置
            jq --arg acc "$account" \
                '.accounts += [{"account": $acc, "type": "user", "projects": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            
            log INFO "成功添加个人账号: $account"
            
            # 询问是否自动发现资源
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

# 自动发现并导入资源
auto_discover_resources() {
    local account=$1
    
    echo
    echo "正在扫描账号下的所有资源，请稍候..."
    
    # 激活账号
    activate_account "$account"
    
    # 获取所有可访问的项目
    local projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
    
    if [ -z "$projects" ]; then
        echo "未发现任何项目"
        return 1
    fi
    
    local total_instances=0
    local default_interval=10  # 默认检查间隔
    
    echo "发现的项目："
    echo "$projects"
    echo
    
    read -p "请输入默认检查间隔（分钟，默认10）: " user_interval
    [ -n "$user_interval" ] && default_interval=$user_interval
    
    echo
    echo "开始导入实例..."
    
    # 遍历每个项目
    echo "$projects" | while read -r project_id; do
        echo "正在扫描项目: $project_id"
        
        # 获取该项目下的所有实例
        local instances_info=$(gcloud compute instances list --project="$project_id" \
            --format="csv[no-heading](name,zone,status,machineType.scope(machineTypes))" 2>/dev/null)
        
        if [ -z "$instances_info" ]; then
            echo "  项目 $project_id 中没有实例"
            continue
        fi
        
        # 先确保项目存在于配置中
        local project_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" \
            '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .id' \
            "$CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$project_exists" ]; then
            # 添加项目
            jq --arg acc "$account" --arg proj "$project_id" \
                '(.accounts[] | select(.account == $acc) | .projects) += [{"id": $proj, "zones": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
        
        # 处理每个实例
        echo "$instances_info" | while IFS=',' read -r instance_name zone_full status machine_type; do
            # 提取zone名称（去掉项目前缀）
            zone=$(echo "$zone_full" | rev | cut -d'/' -f1 | rev)
            
            echo "  发现实例: $instance_name (区域: $zone, 状态: $status)"
            
            # 检查是否是Spot实例（通过机器类型或其他标识判断）
            # 这里可以加入更多判断逻辑
            
            # 检查区域是否存在
            local zone_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$zone_exists" ]; then
                # 添加区域
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones) += [{"name": $z, "instances": []}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            fi
            
            # 检查实例是否已存在
            local instance_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[] | select(.name == $inst) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$instance_exists" ]; then
                # 添加实例
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" --argjson int "$default_interval" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) += [{"name": $inst, "interval": $int}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                
                total_instances=$((total_instances + 1))
                log INFO "导入实例: $account/$project_id/$zone/$instance_name"
            else
                echo "    实例已存在，跳过"
            fi
        done
    done
    
    echo
    echo "自动发现完成！共导入 $total_instances 个新实例"
    log INFO "账号 $account 自动发现完成，导入 $total_instances 个实例"
    
    read -p "按回车继续..."
}

# 批量发现所有账号的资源
batch_discover_all() {
    echo
    echo "===== 批量发现所有账号的资源 ====="
    
    local accounts=$(jq -r '.accounts[].account' "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$accounts" ]; then
        echo "还没有添加任何账号"
        return 1
    fi
    
    read -p "请输入默认检查间隔（分钟，默认10）: " default_interval
    default_interval=${default_interval:-10}
    
    echo "$accounts" | while read -r account; do
        echo
        echo "处理账号: $account"
        auto_discover_resources_batch "$account" "$default_interval"
    done
    
    echo
    echo "批量发现完成！"
    read -p "按回车继续..."
}

# 批量自动发现（无交互）
auto_discover_resources_batch() {
    local account=$1
    local default_interval=${2:-10}
    
    # 激活账号
    activate_account "$account"
    
    # 获取所有可访问的项目
    local projects=$(gcloud projects list --format="value(projectId)" 2>/dev/null)
    
    if [ -z "$projects" ]; then
        echo "  账号 $account 未发现任何项目"
        return 1
    fi
    
    local total_instances=0
    
    # 遍历每个项目
    echo "$projects" | while read -r project_id; do
        echo "  扫描项目: $project_id"
        
        # 获取该项目下的所有实例
        local instances_info=$(gcloud compute instances list --project="$project_id" \
            --format="csv[no-heading](name,zone)" 2>/dev/null)
        
        if [ -z "$instances_info" ]; then
            continue
        fi
        
        # 确保项目存在
        local project_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" \
            '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .id' \
            "$CONFIG_FILE" 2>/dev/null)
        
        if [ -z "$project_exists" ]; then
            jq --arg acc "$account" --arg proj "$project_id" \
                '(.accounts[] | select(.account == $acc) | .projects) += [{"id": $proj, "zones": []}]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
        fi
        
        # 处理每个实例
        echo "$instances_info" | while IFS=',' read -r instance_name zone_full; do
            zone=$(echo "$zone_full" | rev | cut -d'/' -f1 | rev)
            
            # 添加区域（如果不存在）
            local zone_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$zone_exists" ]; then
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones) += [{"name": $z, "instances": []}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            fi
            
            # 添加实例（如果不存在）
            local instance_exists=$(jq -r --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" \
                '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[] | select(.name == $inst) | .name' \
                "$CONFIG_FILE" 2>/dev/null)
            
            if [ -z "$instance_exists" ]; then
                jq --arg acc "$account" --arg proj "$project_id" --arg z "$zone" --arg inst "$instance_name" --argjson int "$default_interval" \
                    '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) += [{"name": $inst, "interval": $int}]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                
                total_instances=$((total_instances + 1))
                echo "    + $instance_name"
            fi
        done
    done
    
    echo "  账号 $account 导入 $total_instances 个新实例"
}

# 显示账号菜单
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
    echo "$accounts" | while read -r acc; do
        local count=$(jq -r --arg acc "$acc" \
            '[.accounts[] | select(.account == $acc) | .projects[].zones[].instances[]] | length' \
            "$CONFIG_FILE" 2>/dev/null)
        echo "$i) $acc (监控 $count 个实例)"
        i=$((i+1))
    done
    
    echo
    echo "a) 添加新账号"
    echo "d) 自动发现当前账号的所有资源"
    echo "b) 批量发现所有账号的资源"
    echo "0) 返回主菜单"
    
    read -p "请选择 [数字/a/d/b/0]: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    elif [ "$choice" = "a" ]; then
        add_account
        show_accounts_menu
    elif [ "$choice" = "d" ]; then
        read -p "请输入账号序号: " acc_num
        local selected_account=$(echo "$accounts" | sed -n "${acc_num}p")
        if [ -n "$selected_account" ]; then
            auto_discover_resources "$selected_account"
        fi
        show_accounts_menu
    elif [ "$choice" = "b" ]; then
        batch_discover_all
        show_accounts_menu
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_account=$(echo "$accounts" | sed -n "${choice}p")
        if [ -n "$selected_account" ]; then
            show_account_details "$selected_account"
        else
            echo "无效选择"
        fi
    else
        echo "无效输入"
    fi
}

# 显示账号详情
show_account_details() {
    local account=$1
    
    echo
    echo "===== 账号: $account ====="
    echo
    echo "监控统计："
    
    # 统计信息
    local projects_count=$(jq -r --arg acc "$account" \
        '.accounts[] | select(.account == $acc) | .projects | length' \
        "$CONFIG_FILE" 2>/dev/null)
    
    local instances_count=$(jq -r --arg acc "$account" \
        '[.accounts[] | select(.account == $acc) | .projects[].zones[].instances[]] | length' \
        "$CONFIG_FILE" 2>/dev/null)
    
    echo "  项目数量: $projects_count"
    echo "  实例数量: $instances_count"
    echo
    
    # 显示详细列表
    echo "监控列表："
    jq -r --arg acc "$account" '
        .accounts[] | select(.account == $acc) | 
        .projects[] as $p | 
        $p.zones[] as $z | 
        $z.instances[] | 
        "  \($p.id)/\($z.name)/\(.name) - 每\(.interval)分钟检查"
    ' "$CONFIG_FILE" 2>/dev/null || echo "  （无）"
    
    echo
    echo "操作选项："
    echo "1) 重新发现所有资源"
    echo "2) 修改所有实例的检查间隔"
    echo "3) 删除该账号及所有监控"
    echo "0) 返回"
    
    read -p "请选择 [0-3]: " choice
    
    case $choice in
        1)
            auto_discover_resources "$account"
            ;;
        2)
            read -p "请输入新的检查间隔（分钟）: " new_interval
            if [[ "$new_interval" =~ ^[0-9]+$ ]]; then
                # 更新所有实例的间隔
                jq --arg acc "$account" --argjson int "$new_interval" \
                    '(.accounts[] | select(.account == $acc) | .projects[].zones[].instances[].interval) = $int' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                echo "已更新所有实例的检查间隔为 $new_interval 分钟"
                log INFO "账号 $account 所有实例检查间隔更新为 $new_interval 分钟"
            fi
            ;;
        3)
            read -p "确认删除账号 $account 及其所有监控？[y/N]: " confirm
            if [[ "$confirm" =~ ^[Yy]$ ]]; then
                jq --arg acc "$account" \
                    '.accounts = [.accounts[] | select(.account != $acc)]' \
                    "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
                echo "已删除账号及所有相关监控"
                log INFO "删除账号: $account"
                return 0
            fi
            ;;
        0)
            return 0
            ;;
    esac
    
    show_account_details "$account"
}

# 检查所有实例（定时任务调用）
check_all_instances() {
    local now=$(date +%s)
    
    # 遍历所有配置的实例
    jq -c '.accounts[]' "$CONFIG_FILE" 2>/dev/null | while read -r account_json; do
        local account=$(echo "$account_json" | jq -r '.account')
        local acc_type=$(echo "$account_json" | jq -r '.type')
        
        # 激活账号
        if [ "$acc_type" = "service" ]; then
            local key_file=$(echo "$account_json" | jq -r '.key_file')
            gcloud auth activate-service-account --key-file="$key_file" >/dev/null 2>&1
        else
            gcloud config set account "$account" >/dev/null 2>&1
        fi
        
        echo "$account_json" | jq -c '.projects[]' | while read -r project_json; do
            local project=$(echo "$project_json" | jq -r '.id')
            
            echo "$project_json" | jq -c '.zones[]' | while read -r zone_json; do
                local zone=$(echo "$zone_json" | jq -r '.name')
                
                echo "$zone_json" | jq -c '.instances[]' | while read -r instance_json; do
                    local instance=$(echo "$instance_json" | jq -r '.name')
                    local interval=$(echo "$instance_json" | jq -r '.interval')
                    
                    # 计算检查间隔（秒）
                    local interval_seconds
                    if [ "$interval" -le 60 ]; then
                        interval_seconds=$((interval * 60))
                    else
                        # 大于60分钟，转换为小时
                        local hours=$((interval / 60))
                        interval_seconds=$((hours * 3600))
                    fi
                    
                    # 检查是否需要执行
                    local lastcheck_file="$LASTCHECK_DIR/${account//[@.]/_}_${project}_${zone}_${instance}"
                    local lastcheck=0
                    [ -f "$lastcheck_file" ] && lastcheck=$(cat "$lastcheck_file")
                    
                    if [ $((now - lastcheck)) -ge "$interval_seconds" ]; then
                        # 执行检查
                        local status=$(gcloud compute instances describe "$instance" \
                            --zone="$zone" --project="$project" \
                            --format='get(status)' 2>/dev/null || echo "ERROR")
                        
                        log INFO "[$account/$project/$zone/$instance] 状态: $status"
                        
                        if [ "$status" != "RUNNING" ] && [ "$status" != "ERROR" ]; then
                            log WARN "[$account/$project/$zone/$instance] 不在运行状态，正在启动..."
                            if gcloud compute instances start "$instance" \
                                --zone="$zone" --project="$project" 2>/dev/null; then
                                log INFO "[$account/$project/$zone/$instance] 启动命令已发送"
                            else
                                log ERROR "[$account/$project/$zone/$instance] 启动失败"
                            fi
                        fi
                        
                        # 更新最后检查时间
                        echo "$now" > "$lastcheck_file"
                    fi
                done
            done
        done
    done
}

# 显示统计信息
show_statistics() {
    echo
    echo "===== 监控统计 ====="
    
    local total_accounts=$(jq '.accounts | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local total_projects=$(jq '[.accounts[].projects[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    local total_instances=$(jq '[.accounts[].projects[].zones[].instances[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
    
    echo "账号总数: $total_accounts"
    echo "项目总数: $total_projects"
    echo "实例总数: $total_instances"
    echo
    
    if [ "$total_instances" -gt 0 ]; then
        echo "按项目分组："
        jq -r '.accounts[] as $a | $a.projects[] | 
            "\($a.account)/\(.id): \([.zones[].instances[]] | length) 个实例"' \
            "$CONFIG_FILE" 2>/dev/null
    fi
    
    echo
    read -p "按回车继续..."
}

# 主菜单
main_menu() {
    while true; do
        clear
        echo "$LOGO"
        
        # 显示简要统计
        local instances_count=$(jq '[.accounts[].projects[].zones[].instances[]] | length' "$CONFIG_FILE" 2>/dev/null || echo 0)
        echo "当前监控: $instances_count 个实例"
        echo
        
        echo "1) 账号管理"
        echo "2) 快速发现所有资源"
        echo "3) 查看监控统计"
        echo "4) 查看运行日志"
        echo "5) 手动执行一次检查"
        echo "6) 退出"
        echo
        read -p "请选择 [1-6]: " choice
        
        case $choice in
            1)
                show_accounts_menu
                ;;
            2)
                batch_discover_all
                ;;
            3)
                show_statistics
                ;;
            4)
                echo
                echo "===== 最近的日志 ====="
                tail -n 50 "$LOG_FILE"
                echo
                read -p "按回车继续..."
                ;;
            5)
                echo "正在执行检查..."
                check_all_instances
                echo "检查完成！"
                read -p "按回车继续..."
                ;;
            6)
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

# 主程序入口
main() {
    # 如果是首次安装
    if [ "$1" != "__installed__" ] && [ "$1" != "check" ]; then
        check_root
        echo "$LOGO"
        echo "正在进行首次安装..."
        
        init_dirs
        ensure_jq
        ensure_gcloud
        ensure_crontab
        install_script
        
        echo
        echo "安装完成！现在启动管理界面..."
        sleep 2
        exec "$GCPSC_SCRIPT" __installed__
    fi
    
    # 如果是定时任务调用
    if [ "$1" = "check" ]; then
        check_all_instances
        exit 0
    fi
    
    # 正常运行
    check_root
    init_dirs
    ensure_jq
    main_menu
}

# 执行主程序
main "$@"
