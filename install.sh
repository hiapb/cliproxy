#!/usr/bin/env bash
set -euo pipefail


APP_DIR="${HOME}/cliproxyapi"
IMAGE="router-for-me/cliproxyapi:latest"
CONFIG_URL="https://raw.githubusercontent.com/router-for-me/CLIProxyAPI/main/config.example.yaml"
DEFAULT_PORT="8317"

need_cmd() { command -v "$1" >/dev/null 2>&1 || { echo "缺少命令：$1"; exit 1; }; }
need_docker() {
  need_cmd docker
  if ! docker compose version >/dev/null 2>&1; then
    echo "未检测到 docker compose（compose plugin）。请先安装 docker-compose-plugin。"
    exit 1
  fi
  need_cmd curl
  need_cmd python3
}

prompt_default() {
  local prompt="$1" def="$2" val
  read -r -p "${prompt}（回车默认: ${def}）：" val
  [[ -z "${val}" ]] && val="$def"
  echo "$val"
}

prompt_required() {
  local prompt="$1" val
  while true; do
    read -r -p "${prompt}（必填）：" val
    [[ -n "${val}" ]] && { echo "$val"; return 0; }
    echo "不能为空，请重新输入。"
  done
}

is_number() { [[ "${1:-}" =~ ^[0-9]+$ ]]; }

ensure_dir() { mkdir -p "$APP_DIR"/{logs,auths}; }

write_compose() {
  local host_port="$1"
  cat > "${APP_DIR}/docker-compose.yml" <<EOF
services:
  cliproxyapi:
    image: ${IMAGE}
    container_name: cliproxyapi
    ports:
      - "127.0.0.1:${host_port}:8317"
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
import re, pathlib
p = pathlib.Path("${APP_DIR}/config.yaml")
s = p.read_text(encoding="utf-8").replace("\r\n","\n").replace("\r","\n")

def replace_or_prepend_block(s: str, key: str, block: str) -> str:
    pat = rf'(?ms)^(?:{re.escape(key)}):\s*\n(?:(?:[ \t].*)\n)*'
    if re.search(pat, s):
        s = re.sub(pat, block, s, count=1)
    else:
        s = block + "\n" + s
    return s

s = replace_or_prepend_block(s, "server", "server:\\n  port: 8317\\n")

if not re.search(r'(?m)^auth-dir:\s*', s):
    s = "auth-dir: /root/.cli-proxy-api\\n" + s

secret = ${secret!r}
rm_block = f'remote-management:\\n  allow-remote: false\\n  secret-key: "{secret}"\\n'
s = replace_or_prepend_block(s, "remote-management", rm_block)

p.write_text(s, encoding="utf-8")
PY
}

install_app() {
  need_docker
  echo "=== 安装 CLIProxyAPI（Docker）==="
  local port secret

  port="$(prompt_default "请输入要监听的端口（仅本机访问）" "$DEFAULT_PORT")"
  if ! is_number "$port" || (( port < 1 || port > 65535 )); then
    echo "端口不合法：$port"
    exit 1
  fi
  secret="$(prompt_required "请输入后台管理密码"

  ensure_dir

  echo "[1/5] 写入 docker-compose.yml（127.0.0.1:${port} -> 容器 8317）"
  write_compose "$port"

  if [[ ! -f "${APP_DIR}/config.yaml" ]]; then
    echo "[2/5] 下载示例配置 -> config.yaml（首次安装）"
    curl -fsSL "$CONFIG_URL" -o "${APP_DIR}/config.yaml"
  else
    echo "[2/5] 已存在 config.yaml，跳过下载"
  fi

  echo "[3/5] 注入必要配置"
  inject_required_config "$secret"

  echo "[4/5] 拉取镜像并启动"
  cd "$APP_DIR"
  docker compose pull
  docker compose up -d

  echo "[5/5] 完成"
  echo "目录：$APP_DIR"
  echo "本机访问： http://127.0.0.1:${port}/management.html"
  echo "查看日志： docker logs -f cliproxyapi"
}

update_app() {
  need_docker
  echo "=== 更新 CLIProxyAPI（Docker）==="
  if [[ ! -d "$APP_DIR" || ! -f "${APP_DIR}/docker-compose.yml" ]]; then
    echo "未找到安装目录或 docker-compose.yml：$APP_DIR"
    echo "请先选择 1) 安装"
    exit 1
  fi
  cd "$APP_DIR"
  echo "[1/3] 拉取最新镜像：$IMAGE"
  docker compose pull
  echo "[2/3] 重建并重启"
  docker compose up -d --force-recreate
  echo "[3/3] 完成"
  echo "当前容器："
  docker ps --filter "name=cliproxyapi"
}

uninstall_app() {
  need_docker
  echo "=== 卸载 CLIProxyAPI（Docker）==="
  if [[ -d "$APP_DIR" && -f "${APP_DIR}/docker-compose.yml" ]]; then
    cd "$APP_DIR"
    echo "[1/2] 停止并删除容器"
    docker compose down --remove-orphans || true
  else
    echo "[1/2] 未找到 docker-compose.yml，跳过 down"
  fi

  echo "[2/2] 删除目录：$APP_DIR"
  read -r -p "是否删除数据目录（含 auths/logs/config）？(y/N)：" ans
  if [[ "${ans:-}" =~ ^[Yy]$ ]]; then
    rm -rf "$APP_DIR"
    echo "已删除：$APP_DIR"
  else
    echo "保留目录：$APP_DIR"
  fi
}

main_menu() {
  echo "=============================="
  echo " CLIProxyAPI Docker 一键菜单"
  echo " 镜像：$IMAGE"
  echo " 1) 安装"
  echo " 2) 更新"
  echo " 3) 卸载"
  echo " 0) 退出"
  echo "=============================="
  read -r -p "请选择 [0-3]：" choice
  case "${choice:-}" in
    1) install_app ;;
    2) update_app ;;
    3) uninstall_app ;;
    0) exit 0 ;;
    *) echo "无效选择"; exit 1 ;;
  esac
}

main_menu
