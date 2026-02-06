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
# UI 颜色库
# ==============================================================================
RED='\033[31m'
GREEN='\033[32m'
YELLOW='\033[33m'
BLUE='\033[34m'
CYAN='\033[36m'
PLAIN='\033[0m'
BOLD='\033[1m'

icon_success="✅"
icon_error="❌"
icon_info="ℹ️"
icon_warn="⚠️"
icon_rocket="🚀"
icon_docker="🐳"
icon_fix="🔧"

log_info() { echo -e "${BLUE}${icon_info} [INFO] ${PLAIN}$1"; }
log_success() { echo -e "${GREEN}${icon_success} [SUCCESS] ${PLAIN}$1"; }
log_error() { echo -e "${RED}${icon_error} [ERROR] ${PLAIN}$1"; }
log_warn() { echo -e "${YELLOW}${icon_warn} [WARN] ${PLAIN}$1"; }
log_fix() { echo -e "${CYAN}${icon_fix} [AUTO-FIX] ${PLAIN}$1"; }
log_header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${PLAIN}"; }

# ==============================================================================
# 智能依赖安装系统 (核心修改)
# ==============================================================================

# 1. 检查是不是 root，安装软件需要 root
check_root() {
    if [[ $EUID -ne 0 ]]; then
        log_error "安装依赖需要 root 权限，请使用 'sudo -i' 切换到 root 用户后再运行脚本。"
        exit 1
    fi
}

# 2. 识别包管理器
get_pm() {
    if command -v apt-get >/dev/null 2>&1; then
        echo "apt"
    elif command -v yum >/dev/null 2>&1; then
        echo "yum"
    elif command -v dnf >/dev/null 2>&1; then
        echo "dnf"
    elif command -v apk >/dev/null 2>&1; then
        echo "apk"
    else
        echo "unknown"
    fi
}

# 3. 通用软件安装函数 (curl, grep, sed 等)
# 用法: check_install "命令名" "包名(如果不同)"
check_install() {
    local cmd="$1"
    local pkg="${2:-$1}" # 如果没传包名，默认包名=命令名

    if ! command -v "$cmd" >/dev/null 2>&1; then
        log_fix "未找到命令 '$cmd'，正在自动安装 '$pkg'..."
        local pm=$(get_pm)
        
        case "$pm" in
            apt)
                apt-get update -y >/dev/null 2>&1
                apt-get install -y "$pkg" >/dev/null 2>&1
                ;;
            yum|dnf)
                $pm install -y "$pkg" >/dev/null 2>&1
                ;;
            apk)
                apk add "$pkg" >/dev/null 2>&1
                ;;
            *)
                log_error "无法识别系统包管理器，请手动安装: $pkg"
                exit 1
                ;;
        esac

        # 安装完再查一次
        if ! command -v "$cmd" >/dev/null 2>&1; then
            log_error "$pkg 安装失败，请检查网络或源设置。"
            exit 1
        else
            log_success "$pkg 安装完成。"
        fi
    fi
}

# 4. Docker 专用安装逻辑
ensure_docker() {
    # 检查 Docker
    if ! command -v docker >/dev/null 2>&1; then
        log_fix "未检测到 Docker，正在执行官方一键安装脚本..."
        curl -fsSL https://get.docker.com | bash
        systemctl enable docker >/dev/null 2>&1
        systemctl start docker >/dev/null 2>&1
    fi

    # 检查 Docker Compose
    if ! docker compose version >/dev/null 2>&1; then
        log_fix "Docker 已安装但缺少 Compose 插件，尝试修复..."
        local pm=$(get_pm)
        if [[ "$pm" == "apt" ]]; then
            apt-get update && apt-get install -y docker-compose-plugin
        elif [[ "$pm" == "yum" || "$pm" == "dnf" ]]; then
            $pm install -y docker-compose-plugin
        else
            log_error "请手动安装 docker-compose-plugin"
            exit 1
        fi
    fi

    # 确保 Docker 守护进程在运行
    if ! docker ps >/dev/null 2>&1; then
        log_warn "Docker 未运行，正在尝试启动..."
        systemctl start docker
        sleep 2
    fi
    
    log_success "Docker 环境就绪。"
}

ensure_env() {
    check_root
    
    # 基础工具检查与安装
    check_install curl
    check_install grep
    check_install sed
    
    # Docker 检查与安装
    ensure_docker
}

# ==============================================================================
# 交互输入
# ==============================================================================
prompt_default() {
    local prompt="$1" def="$2" val
    echo -e -n "${CYAN}${prompt} ${PLAIN}(默认: ${GREEN}${def}${PLAIN}): "
    read -r val
    [[ -z "${val}" ]] && val="$def"
    echo "$val"
}

prompt_required() {
    local prompt="$1" val
    while true; do
        echo -e -n "${YELLOW}${prompt} ${PLAIN}(${RED}必填${PLAIN}): "
        read -r val
        [[ -n "${val}" ]] && { echo "$val"; return 0; }
        log_warn "输入不能为空。"
    done
}

prompt_yn_default_yes() {
    local prompt="$1" val
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
# 核心逻辑 (业务)
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

    if grep -q "port:" "$conf"; then
        sed -i 's/^[[:space:]]*port: [0-9]*/  port: 8317/' "$conf"
    else
        echo -e "\nserver:\n  port: 8317" >> "$conf"
    fi

    if grep -q "auth-dir:" "$conf"; then
         sed -i 's|^[[:space:]]*auth-dir: .*|auth-dir: /root/.cli-proxy-api|' "$conf"
    else
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
    log_header "环境自检与准备"
    ensure_env  # 这里会自动安装 Docker 和 curl

    log_header "安装 CLIProxyAPI"
    
    local port secret local_only
    port="$(prompt_default "请输入监听端口" "$DEFAULT_PORT")"
    if ! is_number "$port" || (( port < 1 || port > 65535 )); then
        log_error "端口不合法"
        return
    fi
    local_only="$(prompt_yn_default_yes "是否仅本机访问")"
    secret="$(prompt_required "请设置后台管理密码")"

    ensure_dir
    log_info "生成 docker-compose.yml..."
    write_compose "$port" "$local_only"

    if [[ ! -f "${APP_DIR}/config.yaml" ]]; then
        log_info "下载默认配置..."
        curl -fsSL "$CONFIG_URL" -o "${APP_DIR}/config.yaml"
    else
        log_warn "已存在配置，保留原文件。"
    fi

    log_info "应用配置参数..."
    inject_required_config "$secret"

    log_info "${icon_docker} 启动容器..."
    cd "$APP_DIR" || return
    if docker compose pull && docker compose up -d; then
        log_success "安装成功！"
        echo "----------------------------------------------------"
        echo -e " 📂 目录: ${GREEN}${APP_DIR}${PLAIN}"
        if [[ "$local_only" == "y" ]]; then
            echo -e " 🔗 面板: ${GREEN}http://127.0.0.1:${port}/management.html${PLAIN}"
        else
            echo -e " 🔗 面板: ${GREEN}http://IP:${port}/management.html${PLAIN}"
        fi
        echo -e " 🔑 密码: ${YELLOW}${secret}${PLAIN}"
        echo "----------------------------------------------------"
    else
        log_error "启动失败"
    fi
    read -r -p "按回车返回..."
}

update_app() {
    # 更新也需要环境正常
    log_header "检查环境"
    ensure_env 
    
    log_header "更新 CLIProxyAPI"
    if [[ ! -d "$APP_DIR" ]]; then log_error "未安装"; return; fi
    cd "$APP_DIR" || return
    docker compose pull && docker compose up -d --force-recreate
    log_success "更新完成"
    read -r -p "按回车返回..."
}

uninstall_app() {
    log_header "卸载 CLIProxyAPI"
    if [[ -d "$APP_DIR" ]]; then
        cd "$APP_DIR" || return
        # 即使没有 docker 命令，也要尝试删目录
        if command -v docker >/dev/null 2>&1; then
             docker compose down --remove-orphans || true
        fi
    fi
    local ans="$(prompt_yn_default_yes "删除所有数据（含配置）？")"
    if [[ "$ans" == "y" ]]; then rm -rf "$APP_DIR"; log_success "已清理"; else log_info "保留数据"; fi
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
    echo -e "   ${BOLD}${CYAN}CLIProxyAPI${PLAIN} 管理脚本 (自动装机版)"
    echo -e "================================================================"
    echo -e " 状态: $(get_status)"
    echo -e " 1. 安装 / 重置 (自动补全环境)"
    echo -e " 2. 更新"
    echo -e " 3. 卸载"
    echo -e " 0. 退出"
    echo -e "================================================================"
    echo -n " 选择: "
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
