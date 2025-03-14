#!/bin/bash

# 设置变量
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/usr/local/etc/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
CONFIG_FILE="$CONFIG_DIR/realm.toml"
SCRIPT_NAME="realm-x"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"

# 设置颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 判断是否有root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请以root权限运行此脚本${NC}"
        echo "使用: sudo $SCRIPT_NAME"
        exit 1
    fi
}

# 检查realm是否已安装
check_installation() {
    if [ -f "$INSTALL_DIR/realm" ] && [ -f "$CONFIG_FILE" ]; then
        return 0 # 已安装
    else
        return 1 # 未安装
    fi
}

# 添加新的转发规则
add_new_forwarding() {
    check_root
    # 获取用户输入的端口和目标
    read -p "请输入本地监听端口: " LOCAL_PORT
    read -p "请输入远程目标地址(IP或域名): " REMOTE_TARGET
    read -p "请输入远程目标端口: " REMOTE_PORT

    # 处理IPv6地址
    if [[ "$REMOTE_TARGET" =~ : ]]; then
        # 检查是否已经有方括号
        if [[ ! "$REMOTE_TARGET" =~ ^\[.*\]$ ]]; then
            REMOTE_TARGET="[$REMOTE_TARGET]"
        fi
    fi

    # 询问是否配置加密隧道
    read -p "是否配置加密隧道? (y/n): " USE_ENCRYPTION
    ENCRYPTION_CONFIG=""
    
    if [[ "$USE_ENCRYPTION" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}请选择加密隧道类型:${NC}"
        echo "1. TLS"
        echo "2. WebSocket (WS)"
        echo "3. WebSocket + TLS (WSS)"
        read -p "请选择 [1-3]: " ENCRYPTION_TYPE
        
        case $ENCRYPTION_TYPE in
            1) # TLS
                read -p "请输入 SNI 域名: " SNI_DOMAIN
                read -p "是否开启 insecure 选项? (y/n): " USE_INSECURE
                
                if [[ "$USE_INSECURE" =~ ^[Yy]$ ]]; then
                    ENCRYPTION_CONFIG="tls;sni=$SNI_DOMAIN;insecure"
                else
                    ENCRYPTION_CONFIG="tls;servername=$SNI_DOMAIN"
                fi
                ;;
            2) # WS
                read -p "请输入 Host 域名: " WS_HOST
                read -p "请输入 Path (默认为/wechat): " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/wechat"
                fi
                ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH"
                ;;
            3) # WSS
                read -p "是否开启 insecure 选项? (y/n): " USE_INSECURE
                read -p "请输入 Host 域名: " WS_HOST
                read -p "请输入 Path (默认为/wechat): " WS_PATH
                read -p "请输入 SNI 域名: " SNI_DOMAIN
                
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/wechat"
                fi
                
                if [[ "$USE_INSECURE" =~ ^[Yy]$ ]]; then
                    ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH;tls;sni=$SNI_DOMAIN;insecure"
                else
                    ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH;tls;servername=$SNI_DOMAIN"
                fi
                ;;
            *)
                echo -e "${RED}无效的选择，将不使用加密隧道${NC}"
                ;;
        esac
    fi

    # 添加新的endpoint配置
    if [ -n "$ENCRYPTION_CONFIG" ]; then
        echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${LOCAL_PORT}\"\nremote = \"${REMOTE_TARGET}:${REMOTE_PORT}\"\nremote_transport = \"${ENCRYPTION_CONFIG}\"" >> "$CONFIG_FILE"
        echo -e "${GREEN}已添加新的加密转发规则: 0.0.0.0:${LOCAL_PORT} -> ${REMOTE_TARGET}:${REMOTE_PORT} (加密类型: ${ENCRYPTION_CONFIG})${NC}"
    else
        echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${LOCAL_PORT}\"\nremote = \"${REMOTE_TARGET}:${REMOTE_PORT}\"" >> "$CONFIG_FILE"
        echo -e "${GREEN}已添加新的转发规则: 0.0.0.0:${LOCAL_PORT} -> ${REMOTE_TARGET}:${REMOTE_PORT}${NC}"
    fi
    
    # 重启服务
    if systemctl is-active --quiet realm; then
        echo "重启realm服务..."
        systemctl restart realm
        echo -e "${GREEN}服务已重启${NC}"
    else
        echo "realm服务未运行，正在启动..."
        systemctl start realm
        echo -e "${GREEN}服务已启动${NC}"
    fi
}

# 删除转发规则
delete_forwarding() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    # 显示当前规则
    echo -e "${BLUE}当前转发规则:${NC}"
    echo "------------------------------------"
    
    # 简化规则解析并显示
    RULES=$(awk '
    BEGIN { count = 0; endpoint_start = 0; }
    /\[\[endpoints\]\]/ { 
      endpoint_start = NR;
      endpoints[count] = endpoint_start;
      count++;
    }
    /listen =/ { 
      gsub(/"/, "", $3);
      listen[count-1] = $3;
    }
    /remote =/ { 
      gsub(/"/, "", $3);
      remote[count-1] = $3;
    }
    /remote_transport =/ { 
      gsub(/"/, "", $3);
      transport[count-1] = $3;
    }
    END {
      for (i = 0; i < count; i++) {
        if (transport[i]) {
          print i " : " listen[i] " -> " remote[i] " (加密: " transport[i] ")";
        } else {
          print i " : " listen[i] " -> " remote[i];
        }
        print endpoints[i];  # 打印行号信息用于后续处理
      }
    }' "$CONFIG_FILE")
    
    # 检查是否有规则
    if [ -z "$RULES" ]; then
        echo "没有找到转发规则"
        return
    fi
    
    # 解析规则和行号信息
    RULE_COUNT=$(echo "$RULES" | awk 'NR % 2 == 1 {count++} END {print count}')
    
    if [ "$RULE_COUNT" -eq 0 ]; then
        echo "没有找到转发规则"
        return
    fi
    
    # 将规则和行号信息分开
    DISPLAY_RULES=$(echo "$RULES" | awk 'NR % 2 == 1 {print}')
    RULE_LINES=$(echo "$RULES" | awk 'NR % 2 == 0 {print}')
    
    # 显示规则供用户选择
    echo "$DISPLAY_RULES"
    echo "------------------------------------"
    
    # 用户选择
    read -p "请输入要删除的规则序号 [0-$((RULE_COUNT-1))]: " RULE_NUM
    
    # 验证输入
    if ! [[ "$RULE_NUM" =~ ^[0-9]+$ ]] || [ "$RULE_NUM" -ge "$RULE_COUNT" ]; then
        echo -e "${RED}无效的规则序号${NC}"
        return
    fi
    
    # 获取所选规则的行号
    LINE_NUM=$(echo "$RULE_LINES" | sed -n "$((RULE_NUM+1))p")
    
    # 找到规则的开始和结束位置
    START_LINE=$LINE_NUM
    
    # 找到下一个规则的开始行或文件结束
    if [ "$RULE_NUM" -lt "$((RULE_COUNT-1))" ]; then
        NEXT_LINE=$(echo "$RULE_LINES" | sed -n "$((RULE_NUM+2))p")
        END_LINE=$((NEXT_LINE-1))
    else
        # 如果是最后一条规则，则到文件末尾
        END_LINE=$(wc -l < "$CONFIG_FILE")
    fi
    
    # 创建新的配置文件，排除要删除的规则
    TEMP_CONFIG=$(mktemp)
    
    # 写入删除行之前的内容
    if [ "$START_LINE" -gt 1 ]; then
        head -n $((START_LINE-1)) "$CONFIG_FILE" > "$TEMP_CONFIG"
    else
        # 如果删除的是第一个规则，创建空文件
        > "$TEMP_CONFIG"
    fi
    
    # 写入删除行之后的内容
    if [ "$END_LINE" -lt "$(wc -l < "$CONFIG_FILE")" ]; then
        tail -n $(($(wc -l < "$CONFIG_FILE") - END_LINE)) "$CONFIG_FILE" >> "$TEMP_CONFIG"
    fi
    
    # 备份原配置
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 使用新配置替换旧配置
    mv "$TEMP_CONFIG" "$CONFIG_FILE"
    
    echo -e "${GREEN}已删除规则序号 $RULE_NUM${NC}"
    
    # 重启服务
    if systemctl is-active --quiet realm; then
        echo "重启realm服务..."
        systemctl restart realm
        echo -e "${GREEN}服务已重启${NC}"
    else
        echo "realm服务未运行，正在启动..."
        systemctl start realm
        echo -e "${GREEN}服务已启动${NC}"
    fi
}

# 卸载realm
uninstall_realm() {
    check_root
    echo -e "${YELLOW}正在卸载Realm...${NC}"
    
    # 停止并禁用服务
    if systemctl is-active --quiet realm; then
        echo "停止realm服务..."
        systemctl stop realm
    fi
    
    if systemctl is-enabled --quiet realm; then
        echo "禁用realm服务..."
        systemctl disable realm
    fi
    
    # 删除服务文件
    if [ -f "$SERVICE_FILE" ]; then
        echo "删除服务文件..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    
    # 删除二进制文件
    if [ -f "$INSTALL_DIR/realm" ]; then
        echo "删除二进制文件..."
        rm -f "$INSTALL_DIR/realm"
    fi
    
    # 询问是否删除配置文件
    read -p "是否删除配置文件? (y/n): " REMOVE_CONFIG
    if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
        echo "删除配置目录..."
        rm -rf "$CONFIG_DIR"
    else
        echo "保留配置文件，位置: $CONFIG_DIR"
    fi
    
    # 删除realm-x脚本
    echo "删除realm-x命令..."
    
    # 创建临时脚本用于删除自己
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash
# 等待原脚本退出
sleep 1
# 删除realm-x脚本
rm -f "/usr/local/bin/realm-x"
# 删除自己
rm -f "$0"
EOF
    
    chmod +x "$TEMP_SCRIPT"
    
    echo -e "${GREEN}Realm 已成功卸载${NC}"
    echo "realm-x命令将在退出后删除"
    
    # 在后台执行临时脚本
    nohup "$TEMP_SCRIPT" > /dev/null 2>&1 &
    
    exit 0
}

# 执行完整安装
perform_installation() {
    check_root
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || exit 1

    # 获取最新版本
    echo "获取最新版本..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep "tag_name" | cut -d '"' -f 4)

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}无法获取最新版本，使用默认版本 v2.7.0${NC}"
        LATEST_VERSION="v2.7.0"
    fi

    echo -e "${GREEN}最新版本: $LATEST_VERSION${NC}"
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}"

    # 获取系统架构
    get_arch() {
        ARCH=$(uname -m)
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        
        case "$ARCH" in
            x86_64)
                case "$OS" in
                    linux)
                        if [ -f "/etc/alpine-release" ]; then
                            echo "x86_64-unknown-linux-musl"
                        else
                            echo "x86_64-unknown-linux-gnu"
                        fi
                        ;;
                    darwin)
                        echo "x86_64-apple-darwin"
                        ;;
                    msys*|mingw*|cygwin*)
                        echo "x86_64-pc-windows-msvc"
                        ;;
                    *)
                        echo "unsupported"
                        ;;
                esac
                ;;
            aarch64|arm64)
                case "$OS" in
                    linux)
                        if [ -f "/etc/alpine-release" ]; then
                            echo "aarch64-unknown-linux-musl"
                        else
                            echo "aarch64-unknown-linux-gnu"
                        fi
                        ;;
                    darwin)
                        echo "aarch64-apple-darwin"
                        ;;
                    android)
                        echo "aarch64-linux-android"
                        ;;
                    *)
                        echo "unsupported"
                        ;;
                esac
                ;;
            armv7*)
                if [ -f "/etc/alpine-release" ]; then
                    echo "armv7-unknown-linux-musleabihf"
                else
                    echo "armv7-unknown-linux-gnueabihf"
                fi
                ;;
            arm*)
                if [ -f "/etc/alpine-release" ]; then
                    echo "arm-unknown-linux-musleabihf"
                else
                    echo "arm-unknown-linux-gnueabihf"
                fi
                ;;
            *)
                echo "unsupported"
                ;;
        esac
    }

    # 获取当前架构
    CURRENT_ARCH=$(get_arch)

    if [ "$CURRENT_ARCH" = "unsupported" ]; then
        echo -e "${RED}不支持的系统架构${NC}"
        exit 1
    fi

    echo "检测到系统架构: $CURRENT_ARCH"
    FILENAME="realm-${CURRENT_ARCH}.tar.gz"
    DOWNLOAD_LINK="${DOWNLOAD_URL}/${FILENAME}"

    echo "开始下载 $DOWNLOAD_LINK"
    if command -v curl &>/dev/null; then
        curl -L -o "$FILENAME" "$DOWNLOAD_LINK"
    elif command -v wget &>/dev/null; then
        wget -O "$FILENAME" "$DOWNLOAD_LINK"
    else
        echo -e "${RED}需要安装curl或wget${NC}"
        exit 1
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败${NC}"
        exit 1
    fi

    echo "下载完成，开始解压"
    tar -xzf "$FILENAME"

    # 判断安装路径是否存在
    if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
        echo "将realm二进制文件安装到 $INSTALL_DIR"
        cp realm "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/realm"
        REALM_PATH="$INSTALL_DIR/realm"
    else
        echo -e "${YELLOW}目录 $INSTALL_DIR 不存在或没有写入权限，将文件保存在当前目录${NC}"
        chmod +x realm
        REALM_PATH="$PWD/realm"
        INSTALL_DIR="$PWD"
        CONFIG_DIR="$PWD/realm_config"
        SERVICE_FILE="$PWD/realm.service"
        CONFIG_FILE="$CONFIG_DIR/realm.toml"
    fi

    # 检查配置文件是否已存在
    if [ ! -f "$CONFIG_FILE" ]; then
        # 如果不存在配置文件，创建一个基本的配置
        echo "配置文件不存在，将创建基本配置..."
        
        # 创建配置目录
        if [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"; then
            echo "创建配置文件 $CONFIG_FILE"
            cat > "$CONFIG_FILE" << EOF
[network]
no_tcp = false
use_udp = true

# 请使用 'realm-x -a' 添加转发规则
EOF
        else
            echo -e "${YELLOW}无法创建配置目录 $CONFIG_DIR${NC}"
            CONFIG_DIR="$PWD"
            CONFIG_FILE="$CONFIG_DIR/realm.toml"
            cat > "$CONFIG_FILE" << EOF
[network]
no_tcp = false
use_udp = true

# 请使用 'realm-x -a' 添加转发规则
EOF
        fi
        
        echo -e "${YELLOW}请在安装完成后使用 'realm-x -a' 命令添加转发规则${NC}"
    else
        echo "检测到已存在配置文件，保留现有配置"
    fi

    # 创建systemd服务文件
    if [ -d "/etc/systemd/system" ] && [ -w "/etc/systemd/system" ]; then
        echo "创建systemd服务文件 $SERVICE_FILE"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
 
[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
DynamicUser=true
ExecStart=$REALM_PATH -c $CONFIG_FILE
 
[Install]
WantedBy=multi-user.target
EOF

        echo "启用并启动服务"
        systemctl daemon-reload
        systemctl enable realm
        systemctl start realm
        
        echo -e "${GREEN}realm服务已安装并启动${NC}"
        echo "配置文件位置: $CONFIG_FILE"
        echo "服务状态: $(systemctl status realm | grep Active)"
    else
        echo -e "${YELLOW}无法创建systemd服务文件，请手动配置启动项${NC}"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
 
[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
DynamicUser=true
ExecStart=$REALM_PATH -c $CONFIG_FILE
 
[Install]
WantedBy=multi-user.target
EOF
        echo "服务文件已保存到 $SERVICE_FILE"
    fi

    # 在系统中安装realm-x命令
    install_command

    # 清理
    echo "清理临时文件"
    rm -f "$FILENAME"
    cd - > /dev/null
    rm -rf "$TMP_DIR"

    echo -e "${GREEN}Realm 安装完成${NC}"
    echo "二进制文件位置: $REALM_PATH"
    echo "配置文件位置: $CONFIG_FILE"
    echo -e "${GREEN}您现在可以使用 'realm-x -a' 命令添加转发规则${NC}"
}

# 安装realm-x命令
install_command() {
    check_root
    echo "安装realm-x命令..."
    
    # 获取脚本内容并直接写入目标文件
    cat > "$SCRIPT_PATH" << 'REALMX_SCRIPT'
#!/bin/bash

# 设置变量
INSTALL_DIR="/usr/local/bin"
CONFIG_DIR="/usr/local/etc/realm"
SERVICE_FILE="/etc/systemd/system/realm.service"
CONFIG_FILE="$CONFIG_DIR/realm.toml"
SCRIPT_NAME="realm-x"
SCRIPT_PATH="$INSTALL_DIR/$SCRIPT_NAME"

# 设置颜色
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
RED='\033[0;31m'
BLUE='\033[0;34m'
NC='\033[0m' # 恢复默认颜色

# 判断是否有root权限
check_root() {
    if [ "$(id -u)" -ne 0 ]; then
        echo -e "${RED}请以root权限运行此脚本${NC}"
        echo "使用: sudo $SCRIPT_NAME"
        exit 1
    fi
}

# 检查realm是否已安装
check_installation() {
    if [ -f "$INSTALL_DIR/realm" ] && [ -f "$CONFIG_FILE" ]; then
        return 0 # 已安装
    else
        return 1 # 未安装
    fi
}

# 添加新的转发规则
add_new_forwarding() {
    check_root
    # 获取用户输入的端口和目标
    read -p "请输入本地监听端口: " LOCAL_PORT
    read -p "请输入远程目标地址(IP或域名): " REMOTE_TARGET
    read -p "请输入远程目标端口: " REMOTE_PORT

    # 处理IPv6地址
    if [[ "$REMOTE_TARGET" =~ : ]]; then
        # 检查是否已经有方括号
        if [[ ! "$REMOTE_TARGET" =~ ^\[.*\]$ ]]; then
            REMOTE_TARGET="[$REMOTE_TARGET]"
        fi
    fi

    # 询问是否配置加密隧道
    read -p "是否配置加密隧道? (y/n): " USE_ENCRYPTION
    ENCRYPTION_CONFIG=""
    
    if [[ "$USE_ENCRYPTION" =~ ^[Yy]$ ]]; then
        echo -e "${BLUE}请选择加密隧道类型:${NC}"
        echo "1. TLS"
        echo "2. WebSocket (WS)"
        echo "3. WebSocket + TLS (WSS)"
        read -p "请选择 [1-3]: " ENCRYPTION_TYPE
        
        case $ENCRYPTION_TYPE in
            1) # TLS
                read -p "请输入 SNI 域名: " SNI_DOMAIN
                read -p "是否开启 insecure 选项? (y/n): " USE_INSECURE
                
                if [[ "$USE_INSECURE" =~ ^[Yy]$ ]]; then
                    ENCRYPTION_CONFIG="tls;sni=$SNI_DOMAIN;insecure"
                else
                    ENCRYPTION_CONFIG="tls;servername=$SNI_DOMAIN"
                fi
                ;;
            2) # WS
                read -p "请输入 Host 域名: " WS_HOST
                read -p "请输入 Path (默认为/wechat): " WS_PATH
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/wechat"
                fi
                ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH"
                ;;
            3) # WSS
                read -p "是否开启 insecure 选项? (y/n): " USE_INSECURE
                read -p "请输入 Host 域名: " WS_HOST
                read -p "请输入 Path (默认为/wechat): " WS_PATH
                read -p "请输入 SNI 域名: " SNI_DOMAIN
                
                if [ -z "$WS_PATH" ]; then
                    WS_PATH="/wechat"
                fi
                
                if [[ "$USE_INSECURE" =~ ^[Yy]$ ]]; then
                    ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH;tls;sni=$SNI_DOMAIN;insecure"
                else
                    ENCRYPTION_CONFIG="ws;host=$WS_HOST;path=$WS_PATH;tls;servername=$SNI_DOMAIN"
                fi
                ;;
            *)
                echo -e "${RED}无效的选择，将不使用加密隧道${NC}"
                ;;
        esac
    fi

    # 添加新的endpoint配置
    if [ -n "$ENCRYPTION_CONFIG" ]; then
        echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${LOCAL_PORT}\"\nremote = \"${REMOTE_TARGET}:${REMOTE_PORT}\"\nremote_transport = \"${ENCRYPTION_CONFIG}\"" >> "$CONFIG_FILE"
        echo -e "${GREEN}已添加新的加密转发规则: 0.0.0.0:${LOCAL_PORT} -> ${REMOTE_TARGET}:${REMOTE_PORT} (加密类型: ${ENCRYPTION_CONFIG})${NC}"
    else
        echo -e "\n[[endpoints]]\nlisten = \"0.0.0.0:${LOCAL_PORT}\"\nremote = \"${REMOTE_TARGET}:${REMOTE_PORT}\"" >> "$CONFIG_FILE"
        echo -e "${GREEN}已添加新的转发规则: 0.0.0.0:${LOCAL_PORT} -> ${REMOTE_TARGET}:${REMOTE_PORT}${NC}"
    fi
    
    # 重启服务
    if systemctl is-active --quiet realm; then
        echo "重启realm服务..."
        systemctl restart realm
        echo -e "${GREEN}服务已重启${NC}"
    else
        echo "realm服务未运行，正在启动..."
        systemctl start realm
        echo -e "${GREEN}服务已启动${NC}"
    fi
}

# 删除转发规则
delete_forwarding() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    # 显示当前规则
    echo -e "${BLUE}当前转发规则:${NC}"
    echo "------------------------------------"
    
    # 简化规则解析并显示
    RULES=$(awk '
    BEGIN { count = 0; endpoint_start = 0; }
    /\[\[endpoints\]\]/ { 
      endpoint_start = NR;
      endpoints[count] = endpoint_start;
      count++;
    }
    /listen =/ { 
      gsub(/"/, "", $3);
      listen[count-1] = $3;
    }
    /remote =/ { 
      gsub(/"/, "", $3);
      remote[count-1] = $3;
    }
    /remote_transport =/ { 
      gsub(/"/, "", $3);
      transport[count-1] = $3;
    }
    END {
      for (i = 0; i < count; i++) {
        if (transport[i]) {
          print i " : " listen[i] " -> " remote[i] " (加密: " transport[i] ")";
        } else {
          print i " : " listen[i] " -> " remote[i];
        }
        print endpoints[i];  # 打印行号信息用于后续处理
      }
    }' "$CONFIG_FILE")
    
    # 检查是否有规则
    if [ -z "$RULES" ]; then
        echo "没有找到转发规则"
        return
    fi
    
    # 解析规则和行号信息
    RULE_COUNT=$(echo "$RULES" | awk 'NR % 2 == 1 {count++} END {print count}')
    
    if [ "$RULE_COUNT" -eq 0 ]; then
        echo "没有找到转发规则"
        return
    fi
    
    # 将规则和行号信息分开
    DISPLAY_RULES=$(echo "$RULES" | awk 'NR % 2 == 1 {print}')
    RULE_LINES=$(echo "$RULES" | awk 'NR % 2 == 0 {print}')
    
    # 显示规则供用户选择
    echo "$DISPLAY_RULES"
    echo "------------------------------------"
    
    # 用户选择
    read -p "请输入要删除的规则序号 [0-$((RULE_COUNT-1))]: " RULE_NUM
    
    # 验证输入
    if ! [[ "$RULE_NUM" =~ ^[0-9]+$ ]] || [ "$RULE_NUM" -ge "$RULE_COUNT" ]; then
        echo -e "${RED}无效的规则序号${NC}"
        return
    fi
    
    # 获取所选规则的行号
    LINE_NUM=$(echo "$RULE_LINES" | sed -n "$((RULE_NUM+1))p")
    
    # 找到规则的开始和结束位置
    START_LINE=$LINE_NUM
    
    # 找到下一个规则的开始行或文件结束
    if [ "$RULE_NUM" -lt "$((RULE_COUNT-1))" ]; then
        NEXT_LINE=$(echo "$RULE_LINES" | sed -n "$((RULE_NUM+2))p")
        END_LINE=$((NEXT_LINE-1))
    else
        # 如果是最后一条规则，则到文件末尾
        END_LINE=$(wc -l < "$CONFIG_FILE")
    fi
    
    # 创建新的配置文件，排除要删除的规则
    TEMP_CONFIG=$(mktemp)
    
    # 写入删除行之前的内容
    if [ "$START_LINE" -gt 1 ]; then
        head -n $((START_LINE-1)) "$CONFIG_FILE" > "$TEMP_CONFIG"
    else
        # 如果删除的是第一个规则，创建空文件
        > "$TEMP_CONFIG"
    fi
    
    # 写入删除行之后的内容
    if [ "$END_LINE" -lt "$(wc -l < "$CONFIG_FILE")" ]; then
        tail -n $(($(wc -l < "$CONFIG_FILE") - END_LINE)) "$CONFIG_FILE" >> "$TEMP_CONFIG"
    fi
    
    # 备份原配置
    cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
    
    # 使用新配置替换旧配置
    mv "$TEMP_CONFIG" "$CONFIG_FILE"
    
    echo -e "${GREEN}已删除规则序号 $RULE_NUM${NC}"
    
    # 重启服务
    if systemctl is-active --quiet realm; then
        echo "重启realm服务..."
        systemctl restart realm
        echo -e "${GREEN}服务已重启${NC}"
    else
        echo "realm服务未运行，正在启动..."
        systemctl start realm
        echo -e "${GREEN}服务已启动${NC}"
    fi
}

# 卸载realm
uninstall_realm() {
    check_root
    echo -e "${YELLOW}正在卸载Realm...${NC}"
    
    # 停止并禁用服务
    if systemctl is-active --quiet realm; then
        echo "停止realm服务..."
        systemctl stop realm
    fi
    
    if systemctl is-enabled --quiet realm; then
        echo "禁用realm服务..."
        systemctl disable realm
    fi
    
    # 删除服务文件
    if [ -f "$SERVICE_FILE" ]; then
        echo "删除服务文件..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi
    
    # 删除二进制文件
    if [ -f "$INSTALL_DIR/realm" ]; then
        echo "删除二进制文件..."
        rm -f "$INSTALL_DIR/realm"
    fi
    
    # 询问是否删除配置文件
    read -p "是否删除配置文件? (y/n): " REMOVE_CONFIG
    if [[ "$REMOVE_CONFIG" =~ ^[Yy]$ ]]; then
        echo "删除配置目录..."
        rm -rf "$CONFIG_DIR"
    else
        echo "保留配置文件，位置: $CONFIG_DIR"
    fi
    
    # 删除realm-x脚本
    echo "删除realm-x命令..."
    
    # 创建临时脚本用于删除自己
    TEMP_SCRIPT=$(mktemp)
    cat > "$TEMP_SCRIPT" << 'EOF'
#!/bin/bash
# 等待原脚本退出
sleep 1
# 删除realm-x脚本
rm -f "/usr/local/bin/realm-x"
# 删除自己
rm -f "$0"
EOF
    
    chmod +x "$TEMP_SCRIPT"
    
    echo -e "${GREEN}Realm 已成功卸载${NC}"
    echo "realm-x命令将在退出后删除"
    
    # 在后台执行临时脚本
    nohup "$TEMP_SCRIPT" > /dev/null 2>&1 &
    
    exit 0
}

# 执行完整安装
perform_installation() {
    check_root
    # 创建临时目录
    TMP_DIR=$(mktemp -d)
    cd "$TMP_DIR" || exit 1

    # 获取最新版本
    echo "获取最新版本..."
    LATEST_VERSION=$(curl -s https://api.github.com/repos/zhboner/realm/releases/latest | grep "tag_name" | cut -d '"' -f 4)

    if [ -z "$LATEST_VERSION" ]; then
        echo -e "${YELLOW}无法获取最新版本，使用默认版本 v2.7.0${NC}"
        LATEST_VERSION="v2.7.0"
    fi

    echo -e "${GREEN}最新版本: $LATEST_VERSION${NC}"
    DOWNLOAD_URL="https://github.com/zhboner/realm/releases/download/${LATEST_VERSION}"

    # 获取系统架构
    get_arch() {
        ARCH=$(uname -m)
        OS=$(uname -s | tr '[:upper:]' '[:lower:]')
        
        case "$ARCH" in
            x86_64)
                case "$OS" in
                    linux)
                        if [ -f "/etc/alpine-release" ]; then
                            echo "x86_64-unknown-linux-musl"
                        else
                            echo "x86_64-unknown-linux-gnu"
                        fi
                        ;;
                    darwin)
                        echo "x86_64-apple-darwin"
                        ;;
                    msys*|mingw*|cygwin*)
                        echo "x86_64-pc-windows-msvc"
                        ;;
                    *)
                        echo "unsupported"
                        ;;
                esac
                ;;
            aarch64|arm64)
                case "$OS" in
                    linux)
                        if [ -f "/etc/alpine-release" ]; then
                            echo "aarch64-unknown-linux-musl"
                        else
                            echo "aarch64-unknown-linux-gnu"
                        fi
                        ;;
                    darwin)
                        echo "aarch64-apple-darwin"
                        ;;
                    android)
                        echo "aarch64-linux-android"
                        ;;
                    *)
                        echo "unsupported"
                        ;;
                esac
                ;;
            armv7*)
                if [ -f "/etc/alpine-release" ]; then
                    echo "armv7-unknown-linux-musleabihf"
                else
                    echo "armv7-unknown-linux-gnueabihf"
                fi
                ;;
            arm*)
                if [ -f "/etc/alpine-release" ]; then
                    echo "arm-unknown-linux-musleabihf"
                else
                    echo "arm-unknown-linux-gnueabihf"
                fi
                ;;
            *)
                echo "unsupported"
                ;;
        esac
    }

    # 获取当前架构
    CURRENT_ARCH=$(get_arch)

    if [ "$CURRENT_ARCH" = "unsupported" ]; then
        echo -e "${RED}不支持的系统架构${NC}"
        exit 1
    fi

    echo "检测到系统架构: $CURRENT_ARCH"
    FILENAME="realm-${CURRENT_ARCH}.tar.gz"
    DOWNLOAD_LINK="${DOWNLOAD_URL}/${FILENAME}"

    echo "开始下载 $DOWNLOAD_LINK"
    if command -v curl &>/dev/null; then
        curl -L -o "$FILENAME" "$DOWNLOAD_LINK"
    elif command -v wget &>/dev/null; then
        wget -O "$FILENAME" "$DOWNLOAD_LINK"
    else
        echo -e "${RED}需要安装curl或wget${NC}"
        exit 1
    fi

    if [ $? -ne 0 ]; then
        echo -e "${RED}下载失败${NC}"
        exit 1
    fi

    echo "下载完成，开始解压"
    tar -xzf "$FILENAME"

    # 判断安装路径是否存在
    if [ -d "$INSTALL_DIR" ] && [ -w "$INSTALL_DIR" ]; then
        echo "将realm二进制文件安装到 $INSTALL_DIR"
        cp realm "$INSTALL_DIR/"
        chmod +x "$INSTALL_DIR/realm"
        REALM_PATH="$INSTALL_DIR/realm"
    else
        echo -e "${YELLOW}目录 $INSTALL_DIR 不存在或没有写入权限，将文件保存在当前目录${NC}"
        chmod +x realm
        REALM_PATH="$PWD/realm"
        INSTALL_DIR="$PWD"
        CONFIG_DIR="$PWD/realm_config"
        SERVICE_FILE="$PWD/realm.service"
        CONFIG_FILE="$CONFIG_DIR/realm.toml"
    fi

    # 检查配置文件是否已存在
    if [ ! -f "$CONFIG_FILE" ]; then
        # 如果不存在配置文件，创建一个基本的配置
        echo "配置文件不存在，将创建基本配置..."
        
        # 创建配置目录
        if [ -d "$CONFIG_DIR" ] || mkdir -p "$CONFIG_DIR"; then
            echo "创建配置文件 $CONFIG_FILE"
            cat > "$CONFIG_FILE" << EOF
[network]
no_tcp = false
use_udp = true

# 请使用 'realm-x -a' 添加转发规则
EOF
        else
            echo -e "${YELLOW}无法创建配置目录 $CONFIG_DIR${NC}"
            CONFIG_DIR="$PWD"
            CONFIG_FILE="$CONFIG_DIR/realm.toml"
            cat > "$CONFIG_FILE" << EOF
[network]
no_tcp = false
use_udp = true

# 请使用 'realm-x -a' 添加转发规则
EOF
        fi
        
        echo -e "${YELLOW}请在安装完成后使用 'realm-x -a' 命令添加转发规则${NC}"
    else
        echo "检测到已存在配置文件，保留现有配置"
    fi

    # 创建systemd服务文件
    if [ -d "/etc/systemd/system" ] && [ -w "/etc/systemd/system" ]; then
        echo "创建systemd服务文件 $SERVICE_FILE"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
 
[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
DynamicUser=true
ExecStart=$REALM_PATH -c $CONFIG_FILE
 
[Install]
WantedBy=multi-user.target
EOF

        echo "启用并启动服务"
        systemctl daemon-reload
        systemctl enable realm
        systemctl start realm
        
        echo -e "${GREEN}realm服务已安装并启动${NC}"
        echo "配置文件位置: $CONFIG_FILE"
        echo "服务状态: $(systemctl status realm | grep Active)"
    else
        echo -e "${YELLOW}无法创建systemd服务文件，请手动配置启动项${NC}"
        cat > "$SERVICE_FILE" << EOF
[Unit]
Description=realm
After=network-online.target
Wants=network-online.target systemd-networkd-wait-online.service
 
[Service]
Type=simple
User=root
Restart=always
RestartSec=5s
DynamicUser=true
ExecStart=$REALM_PATH -c $CONFIG_FILE
 
[Install]
WantedBy=multi-user.target
EOF
        echo "服务文件已保存到 $SERVICE_FILE"
    fi

    # 清理
    echo "清理临时文件"
    rm -f "$FILENAME"
    cd - > /dev/null
    rm -rf "$TMP_DIR"

    echo -e "${GREEN}Realm 安装完成${NC}"
    echo "二进制文件位置: $REALM_PATH"
    echo "配置文件位置: $CONFIG_FILE"
    echo -e "${GREEN}您现在可以使用 'realm-x -a' 命令添加转发规则${NC}"
}

# 显示已有转发规则
show_current_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    echo -e "${GREEN}当前转发规则:${NC}"
    echo "------------------------------------"
    
    # 提取并显示每个转发规则
    RULES=$(awk '
    BEGIN { count = 0; }
    /\[\[endpoints\]\]/ { 
      count++;
    }
    /listen =/ { 
      gsub(/"/, "", $3);
      listen[count-1] = $3;
    }
    /remote =/ { 
      gsub(/"/, "", $3);
      remote[count-1] = $3;
    }
    /remote_transport =/ { 
      gsub(/"/, "", $3);
      transport[count-1] = $3;
    }
    END {
      if (count == 0) {
        print "没有找到转发规则，使用 \"realm-x -a\" 添加规则";
      } else {
        for (i = 0; i < count; i++) {
          if (transport[i]) {
            print i " : " listen[i] " -> " remote[i] " (加密: " transport[i] ")";
          } else {
            print i " : " listen[i] " -> " remote[i];
          }
        }
      }
    }' "$CONFIG_FILE")
    
    echo "$RULES"
    echo "------------------------------------"
}

# 编辑配置文件
edit_config() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    # 检查是否有可用的编辑器
    if command -v nano &>/dev/null; then
        nano "$CONFIG_FILE"
    elif command -v vim &>/dev/null; then
        vim "$CONFIG_FILE"
    elif command -v vi &>/dev/null; then
        vi "$CONFIG_FILE"
    else
        echo -e "${YELLOW}未找到可用的文本编辑器(nano, vim, vi)${NC}"
        return
    fi
    
    # 编辑完成后重启服务
    echo "配置文件已编辑，是否重启服务? (y/n): "
    read restart
    if [[ "$restart" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet realm; then
            systemctl restart realm
            echo -e "${GREEN}服务已重启${NC}"
        else
            systemctl start realm
            echo -e "${GREEN}服务已启动${NC}"
        fi
    fi
}

# 显示帮助信息
show_help() {
    echo -e "${BLUE}Realm 管理工具 (realm-x)${NC}"
    echo "使用方法: $SCRIPT_NAME [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -i, --install    安装或更新Realm"
    echo "  -s, --status     查看Realm状态"
    echo "  -r, --restart    重启Realm服务"
    echo "  -l, --list       列出当前转发规则"
    echo "  -a, --add        添加新的转发规则"
    echo "  -d, --delete     删除转发规则"
    echo "  -e, --edit       编辑配置文件"
    echo "  -u, --uninstall  卸载Realm"
    echo ""
    echo "不带参数运行将显示交互式菜单"
}

# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}====== Realm 管理脚本 ======${NC}"
    echo "1. 安装或更新 Realm"
    echo "2. 显示当前转发规则"
    echo "3. 添加新的转发规则"
    echo "4. 删除转发规则"
    echo "5. 编辑配置文件"
    echo "6. 重启 Realm 服务"
    echo "7. 查看 Realm 状态"
    echo "8. 卸载 Realm"
    echo "9. 退出"
    echo -e "${BLUE}===========================${NC}"
    read -p "请选择操作 [1-9]: " choice
    
    case $choice in
        1)
            perform_installation
            ;;
        2)
            show_current_rules
            ;;
        3)
            if check_installation; then
                add_new_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        4)
            if check_installation; then
                delete_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        5)
            if check_installation; then
                edit_config
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        6)
            check_root
            if systemctl list-unit-files | grep -q realm.service; then
                echo "重启 Realm 服务..."
                systemctl restart realm
                echo -e "${GREEN}服务已重启${NC}"
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            ;;
        7)
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl status realm
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            ;;
        8)
            if check_installation; then
                read -p "确定要卸载 Realm 吗? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_realm
                else
                    echo "已取消卸载"
                fi
            else
                echo -e "${YELLOW}Realm 尚未安装${NC}"
            fi
            ;;
        9)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请重新选择${NC}"
            ;;
    esac
    
    # 按任意键返回主菜单
    read -p "按任意键返回主菜单..." key
    main_menu
}

# 解析命令行参数
parse_args() {
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--install)
            perform_installation
            exit 0
            ;;
        -s|--status)
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl status realm
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            exit 0
            ;;
        -r|--restart)
            check_root
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl restart realm
                echo -e "${GREEN}Realm 服务已重启${NC}"
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            exit 0
            ;;
        -l|--list)
            show_current_rules
            exit 0
            ;;
        -a|--add)
            if check_installation; then
                add_new_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -d|--delete)
            if check_installation; then
                delete_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -e|--edit)
            if check_installation; then
                edit_config
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -u|--uninstall)
            if check_installation; then
                read -p "确定要卸载 Realm 吗? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_realm
                else
                    echo "已取消卸载"
                fi
            else
                echo -e "${YELLOW}Realm 尚未安装${NC}"
            fi
            exit 0
            ;;
        "")
            # 无参数，显示主菜单
            main_menu
            ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# 直接解析参数并执行相应操作
parse_args "$1"
REALMX_SCRIPT

    # 添加执行权限
    chmod +x "$SCRIPT_PATH"
    
    echo -e "${GREEN}realm-x命令已安装到系统${NC}"
}

# 显示已有转发规则
show_current_rules() {
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    echo -e "${GREEN}当前转发规则:${NC}"
    echo "------------------------------------"
    
    # 提取并显示每个转发规则
    RULES=$(awk '
    BEGIN { count = 0; }
    /\[\[endpoints\]\]/ { 
      count++;
    }
    /listen =/ { 
      gsub(/"/, "", $3);
      listen[count-1] = $3;
    }
    /remote =/ { 
      gsub(/"/, "", $3);
      remote[count-1] = $3;
    }
    /remote_transport =/ { 
      gsub(/"/, "", $3);
      transport[count-1] = $3;
    }
    END {
      if (count == 0) {
        print "没有找到转发规则，使用 \"realm-x -a\" 添加规则";
      } else {
        for (i = 0; i < count; i++) {
          if (transport[i]) {
            print i " : " listen[i] " -> " remote[i] " (加密: " transport[i] ")";
          } else {
            print i " : " listen[i] " -> " remote[i];
          }
        }
      }
    }' "$CONFIG_FILE")
    
    echo "$RULES"
    echo "------------------------------------"
}

# 编辑配置文件
edit_config() {
    check_root
    if [ ! -f "$CONFIG_FILE" ]; then
        echo -e "${YELLOW}配置文件不存在: $CONFIG_FILE${NC}"
        return
    fi
    
    # 检查是否有可用的编辑器
    if command -v nano &>/dev/null; then
        nano "$CONFIG_FILE"
    elif command -v vim &>/dev/null; then
        vim "$CONFIG_FILE"
    elif command -v vi &>/dev/null; then
        vi "$CONFIG_FILE"
    else
        echo -e "${YELLOW}未找到可用的文本编辑器(nano, vim, vi)${NC}"
        return
    fi
    
    # 编辑完成后重启服务
    echo "配置文件已编辑，是否重启服务? (y/n): "
    read restart
    if [[ "$restart" =~ ^[Yy]$ ]]; then
        if systemctl is-active --quiet realm; then
            systemctl restart realm
            echo -e "${GREEN}服务已重启${NC}"
        else
            systemctl start realm
            echo -e "${GREEN}服务已启动${NC}"
        fi
    fi
}

# 显示帮助信息
show_help() {
    echo -e "${BLUE}Realm 管理工具 (realm-x)${NC}"
    echo "使用方法: $SCRIPT_NAME [选项]"
    echo ""
    echo "选项:"
    echo "  -h, --help       显示此帮助信息"
    echo "  -i, --install    安装或更新Realm"
    echo "  -s, --status     查看Realm状态"
    echo "  -r, --restart    重启Realm服务"
    echo "  -l, --list       列出当前转发规则"
    echo "  -a, --add        添加新的转发规则"
    echo "  -d, --delete     删除转发规则"
    echo "  -e, --edit       编辑配置文件"
    echo "  -u, --uninstall  卸载Realm"
    echo ""
    echo "不带参数运行将显示交互式菜单"
}

# 主菜单
main_menu() {
    clear
    echo -e "${BLUE}====== Realm 管理脚本 ======${NC}"
    echo "1. 安装或更新 Realm"
    echo "2. 显示当前转发规则"
    echo "3. 添加新的转发规则"
    echo "4. 删除转发规则"
    echo "5. 编辑配置文件"
    echo "6. 重启 Realm 服务"
    echo "7. 查看 Realm 状态"
    echo "8. 卸载 Realm"
    echo "9. 退出"
    echo -e "${BLUE}===========================${NC}"
    read -p "请选择操作 [1-9]: " choice
    
    case $choice in
        1)
            perform_installation
            ;;
        2)
            show_current_rules
            ;;
        3)
            if check_installation; then
                add_new_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        4)
            if check_installation; then
                delete_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        5)
            if check_installation; then
                edit_config
            else
                echo -e "${YELLOW}Realm 尚未安装，请先选择选项 1 进行安装${NC}"
            fi
            ;;
        6)
            check_root
            if systemctl list-unit-files | grep -q realm.service; then
                echo "重启 Realm 服务..."
                systemctl restart realm
                echo -e "${GREEN}服务已重启${NC}"
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            ;;
        7)
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl status realm
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            ;;
        8)
            if check_installation; then
                read -p "确定要卸载 Realm 吗? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_realm
                else
                    echo "已取消卸载"
                fi
            else
                echo -e "${YELLOW}Realm 尚未安装${NC}"
            fi
            ;;
        9)
            echo "退出脚本"
            exit 0
            ;;
        *)
            echo -e "${RED}无效的选择，请重新选择${NC}"
            ;;
    esac
    
    # 按任意键返回主菜单
    read -p "按任意键返回主菜单..." key
    main_menu
}

# 解析命令行参数
parse_args() {
    case "$1" in
        -h|--help)
            show_help
            exit 0
            ;;
        -i|--install)
            perform_installation
            exit 0
            ;;
        -s|--status)
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl status realm
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            exit 0
            ;;
        -r|--restart)
            check_root
            if systemctl list-unit-files | grep -q realm.service; then
                systemctl restart realm
                echo -e "${GREEN}Realm 服务已重启${NC}"
            else
                echo -e "${YELLOW}Realm 服务未安装${NC}"
            fi
            exit 0
            ;;
        -l|--list)
            show_current_rules
            exit 0
            ;;
        -a|--add)
            if check_installation; then
                add_new_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -d|--delete)
            if check_installation; then
                delete_forwarding
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -e|--edit)
            if check_installation; then
                edit_config
            else
                echo -e "${YELLOW}Realm 尚未安装，请先安装${NC}"
            fi
            exit 0
            ;;
        -u|--uninstall)
            if check_installation; then
                read -p "确定要卸载 Realm 吗? (y/n): " confirm
                if [[ "$confirm" =~ ^[Yy]$ ]]; then
                    uninstall_realm
                else
                    echo "已取消卸载"
                fi
            else
                echo -e "${YELLOW}Realm 尚未安装${NC}"
            fi
            exit 0
            ;;
        "")
            # 无参数，显示主菜单
            main_menu
            ;;
        *)
            echo -e "${RED}未知选项: $1${NC}"
            show_help
            exit 1
            ;;
    esac
}

# 检查脚本运行方式
if [[ "$0" != "$SCRIPT_PATH" && "$1" != "--self-install" ]]; then
    # 是首次安装，通过curl|bash方式运行的脚本
    echo "首次运行，安装realm-x命令..."
    
    # 确保有root权限
    check_root
    
    # 安装realm-x命令
    install_command
    
    echo -e "${GREEN}您现在可以运行 'realm-x' 命令来管理Realm${NC}"
    echo "正在启动主菜单..."
    
    # 现在使用安装好的realm-x命令来运行主菜单
    "$SCRIPT_PATH"
else
    # 脚本已经安装为realm-x命令，解析参数并执行相应操作
    parse_args "$1"
fi