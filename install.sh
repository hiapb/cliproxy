#!/usr/bin/env bash
set -u
# set -e 在交互式菜单中建议慎用，因为 grep 找不到内容返回非0会导致脚本直接退出，这里改为手动处理错误

# ==============================================================================
# 全局配置 & 变量
# ==============================================================================
APP_DIR="${HOME}/cliproxyapi"
IMAGE="router-for-me/cliproxyapi:latest"
CONFIG_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/config.example.yaml"
DEFAULT_PORT="8317"
CONTAINER_NAME="cliproxyapi"

# ==============================================================================
# UI & 颜色定义 (增强美观度)
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

log_info() { echo -e "${BLUE}${icon_info} [INFO] ${PLAIN}$1"; }
log_success() { echo -e "${GREEN}${icon_success} [SUCCESS] ${PLAIN}$1"; }
log_error() { echo -e "${RED}${icon_error} [ERROR] ${PLAIN}$1"; }
log_warn() { echo -e "${YELLOW}${icon_warn} [WARN] ${PLAIN}$1"; }
log_header() { echo -e "\n${BOLD}${CYAN}=== $1 ===${PLAIN}"; }

# ==============================================================================
# 基础检查函数
# ==============================================================================
need_cmd() {
    command -v "$1" >/dev/null 2>&1 || { log_error "缺少必要命令：$1"; exit 1; }
}

check_docker() {
    if ! command -v docker >/dev/null 2>&1; then
        echo "not_installed"
        return
    fi
    if ! docker compose version >/dev/null 2>&1; then
        echo "no_compose"
        return
    fi
    echo "ok"
}

ensure_env() {
    need_cmd curl
    need_cmd python3
    local d_status
    d_status=$(check_docker)
    
    if [[ "$d_status" == "not_installed" ]]; then
        log_error "未检测到 Docker。请先安装 Docker。"
        exit 1
    elif [[ "$d_status" == "no_compose" ]]; then
        log_error "未检测到 Docker Compose (Plugin)。"
        exit 1
    fi
}

# ==============================================================================
# 用户输入封装
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
        log_warn "输入不能为空，请重新输入。"
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
    python3 - <<PY
import re, pathlib, sys
try:
    p = pathlib.Path("${APP_DIR}/config.yaml")
    if not p.exists(): sys.exit(0)
    s = p.read_text(encoding="utf-8").replace("\r\n","\n").replace("\r","\n")

    def replace_or_prepend_block(s: str, key: str, block: str) -> str:
        pat = rf'(?ms)^(?:{re.escape(key)}):\s*\n(?:(?:[ \t].*)\n)*'
        if re.search(pat, s):
            s = re.sub(pat, block, s, count=1)
        else:
            s = block + "\n" + s
        return s

    s = replace_or_prepend_block(s, "server", "server:\n  port: 8317\n")

    if not re.search(r'(?m)^auth-dir:\s*', s):
        s = "auth-dir: /root/.cli-proxy-api\n" + s

    secret = ${secret!r}
    rm_block = f'remote-management:\n  allow-remote: false\n  secret-key: "{secret}"\n'
    s = replace_or_prepend_block(s, "remote-management", rm_block)

    p.write_text(s, encoding="utf-8")
except Exception as e:
    print(f"Config injection failed: {e}")
PY
}

install_app() {
    ensure_env
    log_header "安装 CLIProxyAPI"
    
    local port secret local_only

    port="$(prompt_default "请输入监听端口" "$DEFAULT_PORT")"
    if ! is_number "$port" || (( port < 1 || port > 65535 )); then
        log_error "端口不合法：$port"
        return
    fi

    local_only="$(prompt_yn_default_yes "是否仅允许本机(127.0.0.1)访问")"
    secret="$(prompt_required "请设置后台管理密码")"

    ensure_dir

    log_info "正在生成 docker-compose.yml..."
    write_compose "$port" "$local_only"

    if [[ ! -f "${APP_DIR}/config.yaml" ]]; then
        log_info "下载默认配置文件..."
        curl -fsSL "$CONFIG_URL" -o "${APP_DIR}/config.yaml"
    else
        log_warn "检测到已有配置文件，跳过下载（保留原配置）。"
    fi

    log_info "注入核心配置（端口/路径/密钥）..."
    inject_required_config "$secret"

    log_info "${icon_docker} 拉取镜像并启动容器..."
    cd "$APP_DIR" || return
    if docker compose pull && docker compose up -d; then
        log_success "安装并启动完成！"
        echo "----------------------------------------------------"
        echo -e " 📂 安装目录: ${GREEN}${APP_DIR}${PLAIN}"
        if [[ "$local_only" == "y" ]]; then
            echo -e " 🔗 管理面板: ${GREEN}http://127.0.0.1:${port}/management.html${PLAIN} (仅本机)"
        else
            echo -e " 🔗 管理面板: ${GREEN}http://服务器IP:${port}/management.html${PLAIN}"
        fi
        echo -e " 🔑 管理密码: ${YELLOW}${secret}${PLAIN}"
        echo -e " 📜 查看日志: ${CYAN}docker logs -f ${CONTAINER_NAME}${PLAIN}"
        echo "----------------------------------------------------"
    else
        log_error "启动失败，请检查上方报错信息。"
    fi
    read -r -p "按回车键返回菜单..."
}

update_app() {
    ensure_env
    log_header "更新 CLIProxyAPI"
    if [[ ! -d "$APP_DIR" || ! -f "${APP_DIR}/docker-compose.yml" ]]; then
        log_error "未找到安装目录或配置文件：$APP_DIR"
        read -r -p "按回车键返回..."
        return
    fi
    
    cd "$APP_DIR" || return
    log_info "${icon_docker} 正在拉取最新镜像..."
    docker compose pull
    log_info "重建容器..."
    docker compose up -d --force-recreate
    log_success "更新完成！"
    docker ps --filter "name=${CONTAINER_NAME}"
    read -r -p "按回车键返回菜单..."
}

uninstall_app() {
    ensure_env
    log_header "卸载 CLIProxyAPI"
    
    if [[ -d "$APP_DIR" && -f "${APP_DIR}/docker-compose.yml" ]]; then
        cd "$APP_DIR" || return
        log_info "停止并删除容器..."
        docker compose down --remove-orphans || true
    else
        log_warn "未检测到正在运行的 Compose 项目，尝试直接清理目录。"
    fi

    local ans
    ans="$(prompt_yn_default_yes "是否 ${RED}彻底删除${PLAIN} 数据目录（含配置/日志/Auth数据）？")"
    if [[ "$ans" == "y" ]]; then
        rm -rf "$APP_DIR"
        log_success "已彻底删除目录：$APP_DIR"
    else
        log_info "保留数据目录：$APP_DIR"
    fi
    read -r -p "按回车键返回菜单..."
}

# ==============================================================================
# 菜单系统
# ==============================================================================
get_status() {
    if ! command -v docker >/dev/null 2>&1; then
        echo -e "${RED}Docker 未安装${PLAIN}"
        return
    fi
    if docker ps --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${GREEN}运行中 ${icon_rocket}${PLAIN}"
    elif docker ps -a --format '{{.Names}}' | grep -q "^${CONTAINER_NAME}$"; then
        echo -e "${YELLOW}已停止${PLAIN}"
    else
        echo -e "${RED}未安装/未运行${PLAIN}"
    fi
}

show_menu() {
    clear
    echo -e "================================================================"
    echo -e "   ${BOLD}${CYAN}CLIProxyAPI${PLAIN} Docker 管理脚本 ${YELLOW}[v1.1]${PLAIN}"
    echo -e "   Code by Router-for-me | Use with ${icon_success}"
    echo -e "================================================================"
    echo -e " 运行状态: $(get_status)"
    echo -e " 镜像地址: ${CYAN}${IMAGE}${PLAIN}"
    echo -e " 安装路径: ${CYAN}${APP_DIR}${PLAIN}"
    echo -e "================================================================"
    echo -e "  ${GREEN}1.${PLAIN}  ${BOLD}安装 / 重置${PLAIN} (Install)"
    echo -e "  ${GREEN}2.${PLAIN}  ${BOLD}更新镜像${PLAIN}    (Update)"
    echo -e "  ${RED}3.${PLAIN}  ${BOLD}卸载程序${PLAIN}    (Uninstall)"
    echo -e "----------------------------------------------------------------"
    echo -e "  ${GREEN}0.${PLAIN}  退出脚本"
    echo -e "================================================================"
    echo -n " 请输入选项 [0-3]: "
}

main() {
    while true; do
        show_menu
        read -r choice
        case "${choice}" in
            1) install_app ;;
            2) update_app ;;
            3) uninstall_app ;;
            0) echo -e "\n${GREEN}感谢使用，再见！${PLAIN}"; exit 0 ;;
            *) log_error "无效选择，请重试"; sleep 1 ;;
        esac
    done
}

# 启动入口
main
