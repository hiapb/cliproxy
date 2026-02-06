#!/usr/bin/env bash
set -u

# ==============================================================================
# 全局配置
# ==============================================================================
APP_DIR="${HOME}/cliproxyapi"
IMAGE="router-for-me/cliproxyapi:latest"
CONFIG_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/config.example.yaml"
DEFAULT_PORT="8317"
CONTAINER_NAME="cliproxyapi"

# ==============================================================================
# UI 视觉库 (增强版)
# ==============================================================================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
PURPLE='\033[35m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'
DIM='\033[2m'

icon_success="✅"
icon_error="❌"
icon_info="ℹ️"
icon_warn="⚠️"
icon_rocket="🚀"
icon_docker="🐳"
icon_fix="🔧"
icon_wait="⏳"

log_info() { echo -e "${BLUE}${icon_info} [INFO] ${PLAIN}$1"; }
log_success() { echo -e "${GREEN}${icon_success} [SUCCESS] ${PLAIN}$1"; }
log_error() { echo -e "${RED}${icon_error} [ERROR] ${PLAIN}$1"; }
log_warn() { echo -e "${YELLOW}${icon_warn} [WARN] ${PLAIN}$1"; }
log_step() { echo -e "${PURPLE}➤ $1${PLAIN}"; } # 新增：步骤提示
log_header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${PLAIN}"; }

# --- 核心优化：转圈圈动画函数 ---
# 用法: run_with_spinner "正在做某事..." 命令 参数...
run_with_spinner() {
    local msg="$1"
    shift
    # 打印消息，不换行
    echo -ne "${CYAN}${icon_wait} ${msg}... ${PLAIN}"
    
    # 后台执行命令，错误日志重定向到临时文件以便调试，标准输出丢弃
    local err_log=$(mktemp)
    "$@" >/dev/null 2>"$err_log" &
    local pid=$!
    
    local delay=0.1
    local spinstr='|/-\'
    
    # 只要进程还在，就转圈
    while kill -0 "$pid" 2>/dev/null; do
        local temp=${spinstr#?}
        printf " [%c]  " "$spinstr"
        local spinstr=$temp${spinstr%"$temp"}
        sleep $delay
        printf "\b\b\b\b\b\b"
    done
    
    # 等待命令真正结束获取退出码
    wait "$pid"
    local exit_code=$?
    
    # 清除转圈字符
    printf "    \b\b\b\b"
    
    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}完成${PLAIN}"
        rm -f "$err_log"
    else
        echo -e "${RED}失败${PLAIN}"
        echo -e "${RED}错误详情:${PLAIN}"
        cat "$err_log"
        rm -f "$err_log"
        exit 1
    fi
}

# ==============================================================================
# 智能依赖系统 (拒绝静默卡死)
# ==============================================================================

check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "请使用 root 权限运行 (sudo -i)"
        exit 1
    fi
}

get_pm() {
    if command -v apt-get >/dev/null 2>&1; then echo "apt";
    elif command -v yum >/dev/null 2>&1; then echo "yum";
    elif command -v dnf >/dev/null 2>&1; then echo "dnf";
    elif command -v apk >/dev/null 2>&1; then echo "apk";
    else echo "unknown"; fi
}

check_install() {
    local cmd="$1"
    local pkg="${2:-$1}"

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_step "检测到缺少命令: ${YELLOW}$cmd${PLAIN}"
        local pm=$(get_pm)
        
        # ⚠️ 关键修改：不再静默 (>dev/null)，让用户看到安装过程，避免以为死机
        echo -e "${DIM}--- 开始安装 $pkg (系统日志) ---${PLAIN}"
        case "$pm" in
            apt)
                apt-get update -y && apt-get install -y "$pkg"
                ;;
            yum|dnf)
                $pm install -y "$pkg"
                ;;
            apk)
                apk add "$pkg"
                ;;
            *)
                log_error "无法自动安装，请手动执行: install $pkg"
                exit 1
                ;;
        esac
        echo -e "${DIM}--- 安装结束 ---${PLAIN}"

        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "$pkg 安装失败"
            exit 1
        else
            log_success "$pkg 就绪"
        fi
    fi
}

ensure_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        log_step "未找到 Docker，正在启动官方安装脚本..."
        echo -e "${YELLOW}这可能需要几分钟，请耐心等待刷屏...${PLAIN}"
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker >/dev/null 2>&1
        systemctl start docker >/dev/null 2>&1
    fi

    if ! docker compose version >/dev/null 2>&1; then
        log_step "安装 Docker Compose 插件..."
        local pm=$(get_pm)
        # 这里使用显式安装，不隐藏输出
        if [[ "$pm" == "apt" ]]; then
            apt-get update && apt-get install -y docker-compose-plugin
        elif [[ "$pm" == "yum" || "$pm" == "dnf" ]]; then
            $pm install -y docker-compose-plugin
        fi
    fi
    
    # 快速检查 Docker 是否活著
    run_with_spinner "检查 Docker 守护进程状态" docker ps
}

ensure_env() {
    check_root
    # 使用 Spinner 处理快速检查，如果需要安装则会显式输出
    log_info "检查基础环境..."
    check_install curl
    check_install grep
    check_install sed
    ensure_docker
}

# ==============================================================================
# 交互输入
# ==============================================================================
prompt_default() {
    local prompt="$1" def="$2" val
    # 增加空行，避免视觉拥挤
    echo "" 
    echo -e -n "${CYAN}${prompt} ${PLAIN}(默认: ${GREEN}${def}${PLAIN}): "
    read -r val
    [[ -z "${val}" ]] && val="$def"
    echo "$val"
}

prompt_required() {
    local prompt="$1" val
    echo ""
    while true; do
        echo -e -n "${YELLOW}${prompt} ${PLAIN}(${RED}必填${PLAIN}): "
        read -r val
        [[ -n "${val}" ]] && { echo "$val"; return 0; }
        log_warn "输入不能为空"
    done
}

prompt_yn_default_yes() {
    local prompt="$1" val
    echo ""
    echo -e -n "${CYAN}${prompt} ${PLAIN}(Y/n, 默认: ${GREEN}Y${PLAIN}): "
    read -r val
    if [[ -z "${val}" ]]; then echo "y"; return 0; fi
    case "$val" in
        y|Y|yes|YES) echo "y" ;;
        n|N|no|NO)   echo "n" ;;
        *) echo "y" ;;
    esac
}

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }
ensure_dir() { mkdir -p "$APP_DIR"/{logs,auths}; }

# ==============================================================================
# 核心逻辑
# ==============================================================================
write_compose() {
    local host_port="$1"
    local bind_local="$2"
    local ports_line

    if [[ "$bind_local" == "y" ]]; then
        ports_line="      - \"127.0.0.1:${host_port}:8317\""
    else
        ports_line="      - \"${host_port}:8317\""
    fi

    cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
  cliproxyapi:
    image: ${IMAGE}
    container_name: ${CONTAINER_NAME}
    ports:
${ports_line}
    volumes:
      - ./config.yaml:/CLIProxyAPI/config.yaml
      - ./auths:/root/.cli-proxy-api
      - ./logs:/CLIProxyAPI/logs
    restart: unless-stopped
EOF
}

inject_required_config() {
    local secret="$1"
    local conf="${APP_DIR}/config.yaml"
    local safe_secret=$(echo "$secret" | sed 's/#/\\#/g')

    # 使用 run_with_spinner 包裹这些瞬间完成的操作，增加仪式感
    run_with_spinner "配置端口绑定 (Port $DEFAULT_PORT)" grep -q "port:" "$conf"
    
    if grep -q "port:" "$conf"; then
        sed -i 's/^[[:space:]]*port: [0-9]*/  port: 8317/' "$conf"
    else
        echo -e "\nserver:\n  port: 8317" >> "$conf"
    fi

    sed -i 's|^[[:space:]]*auth-dir: .*|auth-dir: /root/.cli-proxy-api|' "$conf"
    
    if ! grep -q "auth-dir:" "$conf"; then
         echo "auth-dir: /root/.cli-proxy-api" >> "$conf"
    fi

    if grep -q "secret-key:" "$conf"; then
        sed -i "s|^[[:space:]]*secret-key: .*|  secret-key: \"$safe_secret\"|" "$conf"
    else
        echo -e "remote-management:\n  allow-remote: false\n  secret-key: \"$secret\"" >> "$conf"
    fi

    sed -i "s|^[[:space:]]*allow-remote: .*|  allow-remote: false|" "$conf"
}

install_app() {
    log_header "阶段 1/4: 环境检查"
    ensure_env 

    log_header "阶段 2/4: 参数配置"
    
    local port secret local_only
    port="$(prompt_default "请输入监听端口" "$DEFAULT_PORT")"
    if ! is_number "$port" || (( port < 1 || port > 65535 )); then
        log_error "端口不合法"
        return
    fi
    local_only="$(prompt_yn_default_yes "是否仅本机访问")"
    secret="$(prompt_required "请设置后台管理密码")"

    log_header "阶段 3/4: 生成配置"
    ensure_dir
    
    run_with_spinner "写入 docker-compose.yml" write_compose "$port" "$local_only"

    if [[ ! -f "${APP_DIR}/config.yaml" ]]; then
        run_with_spinner "下载远程配置文件" curl -fsSL "$CONFIG_URL" -o "${APP_DIR}/config.yaml"
    else
        log_info "保留现有配置文件"
    fi

    run_with_spinner "注入安全密钥与路径" inject_required_config "$secret"

    log_header "阶段 4/4: 容器部署"
    cd "$APP_DIR" || return
    
    echo -e "${CYAN}${icon_docker} 正在拉取镜像 (CLIProxyAPI)...${PLAIN}"
    # ⚠️ 关键修改：不隐藏输出，让用户看到下载进度条
    docker compose pull
    
    echo -e "${CYAN}${icon_rocket} 正在创建并启动容器...${PLAIN}"
    docker compose up -d

    if [ $? -eq 0 ]; then
        log_success "部署流程结束！"
        echo "----------------------------------------------------"
        echo -e " 📂 目录: ${GREEN}${APP_DIR}${PLAIN}"
        if [[ "$local_only" == "y" ]]; then
            echo -e " 🔗 面板: ${GREEN}http://127.0.0.1:${port}/management.html${PLAIN}"
        else
            echo -e " 🔗 面板: ${GREEN}http://服务器IP:${port}/management.html${PLAIN}"
        fi
        echo -e " 🔑 密码: ${YELLOW}${secret}${PLAIN}"
        echo "----------------------------------------------------"
    else
        log_error "启动失败，请检查上方报错。"
    fi
    read -r -p "按回车返回菜单..."
}

update_app() {
    log_header "更新流程"
    ensure_env 
    if [[ ! -d "$APP_DIR" ]]; then log_error "未安装"; return; fi
    cd "$APP_DIR" || return
    
    echo -e "${CYAN}${icon_docker} 拉取最新镜像...${PLAIN}"
    docker compose pull
    
    echo -e "${CYAN}${icon_fix} 重建容器...${PLAIN}"
    docker compose up -d --force-recreate
    
    log_success "更新完成"
    read -r -p "按回车返回..."
}

uninstall_app() {
    log_header "卸载流程"
    if [[ -d "$APP_DIR" ]]; then
        cd "$APP_DIR" || return
        if command -v docker >/dev/null 2>&1; then
             run_with_spinner "停止并移除容器" docker compose down --remove-orphans
        fi
    fi
    local ans="$(prompt_yn_default_yes "删除所有数据（含配置）？")"
    if [[ "$ans" == "y" ]]; then 
        rm -rf "$APP_DIR"
        log_success "已清理目录"
    else 
        log_info "目录已保留" 
    fi
    read -r -p "按回车返回..."
}

# ==============================================================================
# 菜单
# ==============================================================================
get_status() {
    if ! command -v docker >/dev/null 2>&1; then echo -e "${RED}无 Docker${PLAIN}"; return; fi
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${GREEN}运行中 ${icon_rocket}${PLAIN}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}已停止${PLAIN}"
    else
        echo -e "${RED}未运行${PLAIN}"
    fi
}

show_menu() {
    clear
    echo -e "================================================================"
    echo -e "   ${BOLD}${CYAN}CLIProxyAPI${PLAIN} 自动化部署脚本 ${YELLOW}[交互增强版]${PLAIN}"
    echo -e "================================================================"
    echo -e " 状态: $(get_status)"
    echo -e " 1. 安装 (Install)"
    echo -e " 2. 更新 (Update)"
    echo -e " 3. 卸载 (Uninstall)"
    echo -e " 0. 退出 (Exit)"
    echo -e "================================================================"
    echo -n " 请选择: "
}

while true; do
    show_menu
    read -r choice
    case "${choice}" in
        1) install_app ;;
        2) update_app ;;
        3) uninstall_app ;;
        0) exit 0 ;;
        *) ;;
    esac
done
