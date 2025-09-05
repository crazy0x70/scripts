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
                  Version 2.0
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
            ;;
            
        0)
            return 0
            ;;
            
        *)
            echo "无效选择"
            ;;
    esac
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
        echo "$i) $acc"
        i=$((i+1))
    done
    
    echo "a) 添加新账号"
    echo "0) 返回主菜单"
    
    read -p "请选择账号 [数字/a/0]: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    elif [ "$choice" = "a" ]; then
        add_account
        show_accounts_menu
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_account=$(echo "$accounts" | sed -n "${choice}p")
        if [ -n "$selected_account" ]; then
            show_projects_menu "$selected_account"
        else
            echo "无效选择"
        fi
    else
        echo "无效输入"
    fi
}

# 显示项目菜单
show_projects_menu() {
    local account=$1
    
    # 激活账号
    activate_account "$account"
    
    local projects=$(jq -r --arg acc "$account" '.accounts[] | select(.account == $acc) | .projects[].id' "$CONFIG_FILE" 2>/dev/null)
    
    echo
    echo "===== 账号: $account ====="
    echo "===== 已添加的项目 ====="
    
    if [ -z "$projects" ]; then
        echo "（无）"
    else
        local i=1
        echo "$projects" | while read -r proj; do
            echo "$i) $proj"
            i=$((i+1))
        done
    fi
    
    echo "a) 添加新项目"
    echo "d) 显示此账号的所有定时任务"
    echo "0) 返回上级"
    
    read -p "请选择 [数字/a/d/0]: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    elif [ "$choice" = "a" ]; then
        add_project "$account"
        show_projects_menu "$account"
    elif [ "$choice" = "d" ]; then
        show_account_tasks "$account"
        show_projects_menu "$account"
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_project=$(echo "$projects" | sed -n "${choice}p")
        if [ -n "$selected_project" ]; then
            show_zones_menu "$account" "$selected_project"
        else
            echo "无效选择"
        fi
    fi
}

# 显示区域菜单
show_zones_menu() {
    local account=$1
    local project=$2
    
    local zones=$(jq -r --arg acc "$account" --arg proj "$project" \
        '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[].name' \
        "$CONFIG_FILE" 2>/dev/null)
    
    echo
    echo "===== 项目: $project ====="
    echo "===== 已添加的可用区 ====="
    
    if [ -z "$zones" ]; then
        echo "（无）"
    else
        local i=1
        echo "$zones" | while read -r zone; do
            echo "$i) $zone"
            i=$((i+1))
        done
    fi
    
    echo "a) 添加新可用区"
    echo "0) 返回上级"
    
    read -p "请选择 [数字/a/0]: " choice
    
    if [ "$choice" = "0" ]; then
        return 0
    elif [ "$choice" = "a" ]; then
        add_zone "$account" "$project"
        show_zones_menu "$account" "$project"
    elif [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_zone=$(echo "$zones" | sed -n "${choice}p")
        if [ -n "$selected_zone" ]; then
            show_instances_menu "$account" "$project" "$selected_zone"
        else
            echo "无效选择"
        fi
    fi
}

# 显示实例菜单
show_instances_menu() {
    local account=$1
    local project=$2
    local zone=$3
    
    local instances=$(jq -r --arg acc "$account" --arg proj "$project" --arg z "$zone" \
        '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[]' \
        "$CONFIG_FILE" 2>/dev/null | jq -r '"\(.name) (每\(.interval)分钟检查)"')
    
    echo
    echo "===== 可用区: $zone ====="
    echo "===== 已添加的实例监控 ====="
    
    if [ -z "$instances" ]; then
        echo "（无）"
    else
        local i=1
        echo "$instances" | while read -r inst; do
            echo "$i) $inst"
            i=$((i+1))
        done
    fi
    
    echo "a) 添加新实例监控"
    echo "r) 删除实例监控"
    echo "0) 返回上级"
    
    read -p "请选择 [a/r/0]: " choice
    
    case $choice in
        0)
            return 0
            ;;
        a)
            add_instance "$account" "$project" "$zone"
            show_instances_menu "$account" "$project" "$zone"
            ;;
        r)
            remove_instance "$account" "$project" "$zone"
            show_instances_menu "$account" "$project" "$zone"
            ;;
        *)
            echo "无效选择"
            ;;
    esac
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

# 添加项目
add_project() {
    local account=$1
    
    echo
    read -p "请输入项目 ID: " project_id
    
    if [ -z "$project_id" ]; then
        echo "项目 ID 不能为空"
        return 1
    fi
    
    # 验证项目是否存在
    if ! gcloud projects describe "$project_id" >/dev/null 2>&1; then
        echo "项目不存在或无权访问"
        echo "可用的项目："
        gcloud projects list --format="value(projectId)"
        return 1
    fi
    
    # 添加到配置
    jq --arg acc "$account" --arg proj "$project_id" \
        '(.accounts[] | select(.account == $acc) | .projects) += [{"id": $proj, "zones": []}]' \
        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    log INFO "账号 $account 添加项目: $project_id"
    echo "项目添加成功！"
}

# 添加可用区
add_zone() {
    local account=$1
    local project=$2
    
    echo
    echo "常用可用区示例: us-central1-a, asia-east1-b, europe-west1-c"
    read -p "请输入可用区: " zone
    
    if [ -z "$zone" ]; then
        echo "可用区不能为空"
        return 1
    fi
    
    # 添加到配置
    jq --arg acc "$account" --arg proj "$project" --arg z "$zone" \
        '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones) += [{"name": $z, "instances": []}]' \
        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    log INFO "项目 $project 添加可用区: $zone"
    echo "可用区添加成功！"
}

# 添加实例
add_instance() {
    local account=$1
    local project=$2
    local zone=$3
    
    echo
    read -p "请输入实例名称: " instance_name
    
    if [ -z "$instance_name" ]; then
        echo "实例名称不能为空"
        return 1
    fi
    
    # 验证实例是否存在
    activate_account "$account"
    if ! gcloud compute instances describe "$instance_name" --zone="$zone" --project="$project" >/dev/null 2>&1; then
        echo "实例不存在，可用的实例："
        gcloud compute instances list --project="$project" --filter="zone:($zone)" --format="value(name)"
        return 1
    fi
    
    read -p "请输入检查间隔（分钟，1-1440）: " interval
    
    if ! [[ "$interval" =~ ^[0-9]+$ ]] || [ "$interval" -lt 1 ] || [ "$interval" -gt 1440 ]; then
        echo "请输入 1-1440 之间的数字"
        return 1
    fi
    
    # 添加到配置
    jq --arg acc "$account" --arg proj "$project" --arg z "$zone" --arg inst "$instance_name" --argjson int "$interval" \
        '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) += [{"name": $inst, "interval": $int}]' \
        "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
    
    log INFO "添加实例监控: $account/$project/$zone/$instance_name 每${interval}分钟检查"
    echo "实例监控添加成功！"
}

# 删除实例
remove_instance() {
    local account=$1
    local project=$2
    local zone=$3
    
    local instances=$(jq -r --arg acc "$account" --arg proj "$project" --arg z "$zone" \
        '.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances[].name' \
        "$CONFIG_FILE" 2>/dev/null)
    
    if [ -z "$instances" ]; then
        echo "没有可删除的实例"
        return 1
    fi
    
    echo
    echo "选择要删除的实例："
    local i=1
    echo "$instances" | while read -r inst; do
        echo "$i) $inst"
        i=$((i+1))
    done
    
    read -p "请选择 [数字]: " choice
    
    if [[ "$choice" =~ ^[0-9]+$ ]]; then
        local selected_instance=$(echo "$instances" | sed -n "${choice}p")
        if [ -n "$selected_instance" ]; then
            # 从配置中删除
            jq --arg acc "$account" --arg proj "$project" --arg z "$zone" --arg inst "$selected_instance" \
                '(.accounts[] | select(.account == $acc) | .projects[] | select(.id == $proj) | .zones[] | select(.name == $z) | .instances) -= [.instances[] | select(.name == $inst)]' \
                "$CONFIG_FILE" > "$CONFIG_FILE.tmp" && mv "$CONFIG_FILE.tmp" "$CONFIG_FILE"
            
            log INFO "删除实例监控: $account/$project/$zone/$selected_instance"
            echo "实例监控已删除"
        fi
    fi
}

# 显示账号的所有任务
show_account_tasks() {
    local account=$1
    
    echo
    echo "===== $account 的所有监控任务 ====="
    
    jq -r --arg acc "$account" '
        .accounts[] | select(.account == $acc) | 
        .projects[] as $p | 
        $p.zones[] as $z | 
        $z.instances[] | 
        "\($p.id)/\($z.name)/\(.name) - 每\(.interval)分钟检查"
    ' "$CONFIG_FILE" 2>/dev/null || echo "（无）"
    
    echo
    read -p "按回车继续..."
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

# 主菜单
main_menu() {
    while true; do
        clear
        echo "$LOGO"
        echo "1) 添加新账号"
        echo "2) 查看已添加的账号"
        echo "3) 查看运行日志"
        echo "4) 退出"
        echo
        read -p "请选择 [1-4]: " choice
        
        case $choice in
            1)
                add_account
                ;;
            2)
                show_accounts_menu
                ;;
            3)
                echo
                echo "===== 最近的日志 ====="
                tail -n 50 "$LOG_FILE"
                echo
                read -p "按回车继续..."
                ;;
            4)
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
