#!/bin/bash

set -e

INSTALL_PATH="/usr/local/bin"
GCPSC_SCRIPT="$INSTALL_PATH/gcpsc"
LOGO="
========================================================
       Google Cloud Spot Instance 保活服务安装
                 (by crazy0x70)
========================================================
"

crontab_check_and_install() {
    echo ">>> 正在检测 crontab ..."
    if command -v crontab >/dev/null 2>&1; then
        echo "crontab 已安装"
        return 0
    fi
    echo "crontab 未安装，正在尝试安装..."
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        CASE_OS="$ID"
    else
        CASE_OS="$(uname -s)"
    fi
    case "$CASE_OS" in
        ubuntu|debian)
            apt-get update && apt-get install -y cron
            systemctl enable cron || true
            systemctl start cron || true
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum install -y cronie || yum install -y vixie-cron
            systemctl enable crond || true
            systemctl start crond || true
            ;;
        *)
            echo "暂未支持此系统自动安装，请手动安装crontab后再运行本脚本。"
            exit 1
            ;;
    esac
}

gcloud_check_and_install() {
    echo ">>> 正在检查 gcloud ..."
    if command -v gcloud >/dev/null 2>&1; then
        echo "gcloud 已安装"
        return 0
    fi
    # 检查OS和架构
    if [ -f /etc/os-release ]; then
        . /etc/os-release
        SYS="$ID"
    else
        SYS="$(uname -s)"
    fi
    ARCH="$(uname -m)"
    echo "未检测到gcloud，自动安装中..."
    case "$SYS" in
        ubuntu|debian)
            apt-get update && apt-get install -y apt-transport-https ca-certificates gnupg curl
            echo "deb [signed-by=/usr/share/keyrings/cloud.google.gpg] https://packages.cloud.google.com/apt cloud-sdk main" | tee /etc/apt/sources.list.d/google-cloud-sdk.list
            curl https://packages.cloud.google.com/apt/doc/apt-key.gpg |  gpg --dearmor -o /usr/share/keyrings/cloud.google.gpg
            apt-get update && apt-get install -y google-cloud-sdk
            ;;
        centos|rhel|rocky|almalinux|fedora)
            yum install -y epel-release || true
            cat > /etc/yum.repos.d/google-cloud-sdk.repo <<EOM
[google-cloud-sdk]
name=Google Cloud SDK
baseurl=https://packages.cloud.google.com/yum/repos/cloud-sdk-el8-$(uname -m)
enabled=1
gpgcheck=1
repo_gpgcheck=1
gpgkey=https://packages.cloud.google.com/yum/doc/yum-key.gpg https://packages.cloud.google.com/yum/doc/rpm-package-key.gpg
EOM
            yum install -y google-cloud-sdk
            ;;
        *)
            # 通用架构
            TMPD=/tmp/gcloud_install
            mkdir -p $TMPD
            cd $TMPD
            LATEST_URL="https://dl.google.com/dl/cloudsdk/channels/rapid/downloads/google-cloud-sdk-$(curl -s 'https://dl.google.com/dl/cloudsdk/channels/rapid/components-2.json'|grep version|head -1|cut -d'"' -f4)-linux-x86_64.tar.gz"
            [ "$ARCH" = "aarch64" ] && LATEST_URL="${LATEST_URL/x86_64/arm.tar.gz}"
            curl -O $LATEST_URL
            tar -xzf google-cloud-sdk-*.tar.gz
            ./google-cloud-sdk/install.sh --quiet
            export PATH="$PWD/google-cloud-sdk/bin:$PATH"
            ;;
    esac
    [ -f /etc/profile.d/gcloud.sh ] || echo 'export PATH=$PATH:/usr/lib/google-cloud-sdk/bin:/usr/local/google-cloud-sdk/bin:/opt/google-cloud-sdk/bin:$HOME/google-cloud-sdk/bin' > /etc/profile.d/gcloud.sh
    source /etc/profile.d/gcloud.sh || true
    if ! command -v gcloud >/dev/null 2>&1; then
        echo "gcloud未成功安装，请手动处理!"
        exit 1
    fi
}

install_wrapper() {
    echo "$LOGO"
    [ "$(id -u)" -ne 0 ] && { echo "请用root或sudo运行本脚本！"; exit 1; }
    GCPSC_URL="https://raw.githubusercontent.com/crazy0x70/scripts/refs/heads/main/gcp-spot-check/gcp-spot-check.sh"
    curl -fsSL "$GCPSC_URL" -o "$GCPSC_SCRIPT"
    chmod +x "$GCPSC_SCRIPT"
    ln -sf "$GCPSC_SCRIPT" /usr/bin/gcpsc
    echo
    echo "已完成安装，后续只需输入 gcpsc 即可进入交互界面。"
    echo
    exec "$GCPSC_SCRIPT" __entry__
}


interactive_auth() {
    echo
    echo "请选择认证方式："
    echo "1) 使用服务账号json密钥（推荐，适合生产，无图形界面)"
    echo "2) 粘贴json内容到本地"
    echo "3) 个人Google账号登录（会输出网址，需用本地PC浏览器登录，推荐测试环境）"
    read -p "请输入序号[1-3]，回车默认1: " SEL
    SEL=${SEL:-1}
    if [ "$SEL" = "1" ]; then
        while true; do
            read -p "请输入json密钥文件路径: " SA_JSON
            [ -f "$SA_JSON" ] && break || echo "文件不存在，请重新输入！"
        done
    elif [ "$SEL" = "2" ]; then
        echo "请粘贴json内容，Ctrl+D结束："
        cat > /tmp/sa.json
        SA_JSON="/tmp/sa.json"
    elif [ "$SEL" = "3" ]; then
        echo "即将执行：gcloud auth login --no-launch-browser"
        sleep 1
        gcloud auth login --no-launch-browser
        return
    else
        echo "未知选项，重来"
        interactive_auth
        return
    fi
    gcloud auth activate-service-account --key-file="$SA_JSON"
}


main_menu() {
    echo "$LOGO"
    gcloud config list account --format="value(core.account)" | grep . || {
        echo "Google 账号未认证"
        interactive_auth
    }
    echo "当前活跃账号: $(gcloud config get-value account)"
    echo

    # 项目ID
    while true; do
        read -p "请输入项目ID: " PROJECT_ID
        [ -z "$PROJECT_ID" ] && { echo "项目ID不能为空"; continue; }
        PRJ_OK=$(gcloud projects list --filter="projectId=$PROJECT_ID" --format="value(projectId)" 2>/dev/null)
        [ "$PRJ_OK" = "$PROJECT_ID" ] && break
        echo "不存在此项目！可用如下："
        gcloud projects list --format="value(projectId)"
    done
    gcloud config set project "$PROJECT_ID"

    # 实例名
    while true; do
        read -p "请输入实例名称: " INST_NAME
        [ -z "$INST_NAME" ] && { echo "实例名称不能为空"; continue; }
        break
    done

    # 区域
    while true; do
        read -p "请输入可用区(如 asia-east1-b): " ZONE
        [ -z "$ZONE" ] && { echo "可用区不能为空"; continue; }
        EXIST=$(gcloud compute instances list --project "$PROJECT_ID" --filter="name=$INST_NAME zone:($ZONE)" --format="value(name)")
        [ "$EXIST" = "$INST_NAME" ] && break
        echo "实例或可用区错误，目前可用："
        gcloud compute instances list --project "$PROJECT_ID" --format="table(name,zone,status)"
    done

    # 检查间隔
    while true; do
        read -p "请输入检查间隔(分钟, 1-60): " INTERVAL
        [[ ! "$INTERVAL" =~ ^[0-9]+$ ]] && echo "必须是整数" && continue
        [ "$INTERVAL" -ge 1 ] && [ "$INTERVAL" -le 60 ] && break
        echo "请输入1-60之间的正整数"
    done

    # 生成定时脚本
    CKSCRIPT="$HOME/gce_check_${PROJECT_ID}_${INST_NAME}_${ZONE}.sh"
    cat > "$CKSCRIPT" <<EOF
#!/bin/bash
export CLOUDSDK_CORE_PROJECT="$PROJECT_ID"
export PATH=\$PATH:/usr/lib/google-cloud-sdk/bin:/usr/local/google-cloud-sdk/bin:/opt/google-cloud-sdk/bin:\$HOME/google-cloud-sdk/bin
gcloud config set account "$(gcloud config get-value account 2>/dev/null)" >/dev/null
STATUS=\$(gcloud compute instances describe "$INST_NAME" --zone="$ZONE" --project="$PROJECT_ID" --format='get(status)')
echo "[\$(date)] $INST_NAME status: \$STATUS"
if [[ "\$STATUS" != "RUNNING" ]]; then
    echo "[\$(date)] $INST_NAME not RUNNING, starting it..."
    gcloud compute instances start "$INST_NAME" --zone="$ZONE" --project="$PROJECT_ID"
fi
EOF
    chmod +x "$CKSCRIPT"

    # 设置crontab
    echo "正在设置定时任务..."
    CRON_LINE="*/$INTERVAL * * * * $CKSCRIPT >> $HOME/gce_${INST_NAME}_monitor.log 2>&1"
    (crontab -l 2>/dev/null | grep -v "$CKSCRIPT" ; echo "$CRON_LINE") | crontab -

    echo
    echo "定时检测已设置，每$INTERVAL分钟，运行脚本$CKSCRIPT。日志记录在 $HOME/gce_${INST_NAME}_monitor.log"
    echo "如需再次设置只需输入 gcpsc 即可！"
    bash "$CKSCRIPT"
}

# =========== 一键安装入口 ===========
if [[ "$1" != "__entry__" ]]; then
    crontab_check_and_install
    gcloud_check_and_install
    install_wrapper
    exit 0
fi

main_menu

