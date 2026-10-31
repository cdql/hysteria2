#!/usr/bin/env bash
# cdql/hysteria2 三协议一键安装：面板 + Hysteria2 + VLESS+REALITY + VLESS+WS(待套 Cloudflare Tunnel)
# 目标：全新 Ubuntu / Debian VPS，直接安装（不使用 Docker）。
# 流程：输入面板域名、HY2 节点域名、VLESS+REALITY 域名（VLESS WS 域名此时不问），
# 脚本自动部署面板与三个本地协议节点；HY2 / VLESS+REALITY 装完即用（自动写入面板数据库），
# VLESS WS 只部署本地 Xray（127.0.0.1），不套 CF，安装结束打印全部信息（含 VLESS WS 参数），
# 人工到 Cloudflare 建好 Tunnel 域名后，再到面板手动添加 VLESS WS 节点即可使用。
set -Eeuo pipefail
umask 077
export DEBIAN_FRONTEND=noninteractive

APP_DIR=/opt/hysteria2-control-plane
APP_USER=hysteria2
STATE_DIR=/etc/hysteria2
STATE_FILE=$STATE_DIR/installer-state.sh
STAGES_FILE=$STATE_DIR/installer-stages
INFO_FILE=$STATE_DIR/info.env
CREDENTIALS_FILE=/root/hysteria2-admin-credentials.txt
WEBROOT=/var/www/letsencrypt
BACKUP_DIR=/var/backups/hysteria2
LOG_FILE=/var/log/hysteria2-installer.log
REPOSITORY=https://github.com/cdql/hysteria2.git

rand_hex() { head -c "$1" /dev/urandom | od -An -tx1 -v | tr -d ' \n'; }
log()  { printf '\n[INFO] %s\n' "$*"; }
warn() { printf '\n[WARN] %s\n' "$*" >&2; }
die()  { printf '\n[ERROR] %s\n' "$*" >&2; exit 1; }
failed() {
  local code="$1" line="$2"
  printf '\n[FAILED] 第 %s 行失败，退出码 %s。\n' "$line" "$code" >&2
  printf '日志：%s\n' "$LOG_FILE" >&2
  printf '服务日志：journalctl -u hysteria2-api -u hysteria2-web -u hysteria2-node -u hysteria2-worker -u xray -u xray-ws -n 100 --no-pager\n' >&2
  printf '可以用同一份脚本再次运行以从已完成的阶段继续；请勿删除数据库或配置。\n' >&2
  if [[ -f "$CREDENTIALS_FILE" ]]; then
    printf '管理员账号与密码已保存在 root 专用文件：%s\n' "$CREDENTIALS_FILE" >&2
  fi
}
trap 'failed "$?" "$LINENO"' ERR

[[ $EUID -eq 0 ]] || die '必须以 root 身份运行。'
[[ -t 0 && -t 1 ]] || die '请在交互式 SSH/控制台中运行，不要通过无终端的 curl | bash 执行。'
[[ -r /etc/os-release ]] || die '未找到 /etc/os-release。'
# shellcheck disable=SC1091
source /etc/os-release
[[ $ID == debian || $ID == ubuntu ]] || die "仅支持 Debian / Ubuntu，当前：${PRETTY_NAME:-unknown}。"
[[ $(uname -m) == x86_64 || $(uname -m) == aarch64 ]] || die '仅支持 x86_64 / aarch64。'

install -d -m 0700 "$STATE_DIR"
touch "$STAGES_FILE" "$LOG_FILE"
chmod 0600 "$STAGES_FILE" "$LOG_FILE"
# No secret is printed into this log; final credential display goes directly to /dev/tty.
exec > >(tee -a "$LOG_FILE") 2>&1

stage_done() { grep -Fxq -- "$1" "$STAGES_FILE"; }
run_stage() {
  local id="$1" label="$2" function="$3"
  if stage_done "$id"; then
    log "已完成，跳过：$label"
  else
    log "阶段开始：$label"
    "$function"
    printf '%s\n' "$id" >> "$STAGES_FILE"
    log "阶段完成：$label"
  fi
}

valid_domain() {
  local d="$1"
  [[ ${#d} -le 253 && "$d" =~ ^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$ && "$d" != *.local ]]
}
ask_domain() {
  local prompt="$1" var="$2" value
  while :; do
    IFS= read -r -p "$prompt" value
    value="${value,,}"; value="${value%.}"
    if valid_domain "$value"; then printf -v "$var" '%s' "$value"; break; fi
    warn '域名格式不正确，请重新输入。'
  done
}

save_state() {
  local tmp
  tmp="$(mktemp "$STATE_DIR/.state.XXXXXXXX")"
  {
    printf '# Installer-owned, root-only; do not edit or disclose.\n'
    local v
    for v in PANEL_DOMAIN HY2_DOMAIN REALITY_DOMAIN ADMIN_EMAIL ADMIN_PASS HY2_PORT REALITY_PORT WS_PORT WS_PATH REALITY_SNI REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY REALITY_SHORT_ID XRAY_AGENT_SECRET XRAY_WS_AGENT_SECRET CERT_EMAIL DB_PASS JWT_SECRET SETTINGS_KEY STATS_SECRET; do
      printf '%s=%q\n' "$v" "${!v}"
    done
  } > "$tmp"
  chmod 0600 "$tmp"
  mv -f "$tmp" "$STATE_FILE"
}

pick_free_port() {
  local port="$1" i
  for ((i=0; i<50; i++)); do
    if ! ss -lnt "( sport = :$port )" 2>/dev/null | grep -q ":$port " \
      && ! ss -lnu "( sport = :$port )" 2>/dev/null | grep -q ":$port "; then
      printf '%s' "$port"
      return 0
    fi
    port=$((RANDOM % 10001 + 10000))
  done
  die "无法找到可用端口（起始 $1）。"
}

if [[ -f "$STATE_FILE" ]]; then
  [[ -r "$STATE_FILE" ]] || die "无法读取状态文件 $STATE_FILE。"
  # File was only ever written by save_state under root-only /etc/hysteria2.
  # shellcheck disable=SC1090
  source "$STATE_FILE"
  log "发现上次安装记录，继续执行。面板域名：$PANEL_DOMAIN；管理员：$ADMIN_EMAIL。"
else
  [[ ! -e "$APP_DIR" && ! -e "$STATE_DIR/node.yaml" ]] || die '检测到已有部署但没有本安装器状态文件。为保护数据拒绝覆盖。'
  # 本安装器最后会接管防火墙（nftables 默认 DROP），因此先停掉系统自带的防火墙。
  # 很多云厂商的 Debian/Ubuntu 镜像默认启用了 UFW（通常是全放行），直接报错会让一键安装卡住。
  if command -v ufw >/dev/null 2>&1 && ufw status 2>/dev/null | grep -q '^Status: active'; then
    warn '检测到 UFW 正在运行；本安装器将接管防火墙（nftables），现在停用 UFW。'
    ufw disable >/dev/null 2>&1 || true
    systemctl disable --now ufw >/dev/null 2>&1 || true
  fi
  if systemctl is-active --quiet firewalld 2>/dev/null; then
    warn '检测到 firewalld 正在运行；本安装器将接管防火墙（nftables），现在停用 firewalld。'
    systemctl disable --now firewalld >/dev/null 2>&1 || true
  fi
  printf '\n==================================================\n'
  printf 'cdql/hysteria2 · Ubuntu/Debian 三协议一键安装\n'
  printf '==================================================\n'
  printf '安装 面板(API/Web/Worker) / PostgreSQL / Redis / Nginx / HTTPS /\n'
  printf 'HY2 节点 / VLESS+REALITY 节点 / VLESS+WS 本地节点（待套 Cloudflare Tunnel）。\n'
  printf 'HY2 与 VLESS+REALITY 装完即用（自动写入面板数据库，无需手动添加节点）。\n'
  printf 'VLESS WS 只部署本地 Xray，不套 CF；安装结束会打印全部参数，\n'
  printf '人工到 Cloudflare 建好 Tunnel 后，再到面板手动添加该节点即可。\n'
  printf '防火墙最终默认 DROP，仅开放 SSH、TCP 80/443、REALITY TCP 与 Hysteria UDP。\n'
  printf '请先设置域名 DNS 和云平台安全组。\n\n'
  ask_domain '面板 WEB 域名（例如 panel.example.com）：' PANEL_DOMAIN
  ask_domain 'HY2 节点域名（例如 hy2.example.com）：' HY2_DOMAIN
  ask_domain 'VLESS + REALITY 节点域名（例如 vless.example.com）：' REALITY_DOMAIN
  printf 'VLESS WS 域名现在不需要填写，稍后人工到 Cloudflare 添加 Tunnel 时再设置。\n\n'
  while :; do
    IFS= read -r -p '管理员邮箱（登录账号）：' ADMIN_EMAIL
    ADMIN_EMAIL="${ADMIN_EMAIL,,}"
    [[ "$ADMIN_EMAIL" =~ ^[a-z0-9._%+-]+@[a-z0-9.-]+\.[a-z]{2,}$ ]] && break
    warn '邮箱格式不正确。'
  done
  IFS= read -r -p '系统随机生成管理员密码？[Y/n]：' CHOOSE_RANDOM
  if [[ "${CHOOSE_RANDOM,,}" == n ]]; then
    while :; do
      IFS= read -r -s -p '请输入管理员密码（至少 12 字符）：' ADMIN_PASS; printf '\n'
      [[ ${#ADMIN_PASS} -ge 12 && "$ADMIN_PASS" != *$'\n'* && "$ADMIN_PASS" != *$'\r'* ]] || { warn '至少 12 字符，不允许换行。'; continue; }
      IFS= read -r -s -p '再输入一遍密码：' CONFIRM; printf '\n'
      [[ "$ADMIN_PASS" == "$CONFIRM" ]] && { unset CONFIRM; break; }
      warn '两次输入不一致。'
    done
  else
    ADMIN_PASS="$(rand_hex 24)"
  fi
  IFS= read -r -p 'Hysteria2 UDP 端口 [443]：' HY2_PORT
  HY2_PORT="${HY2_PORT:-443}"
  [[ "$HY2_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$HY2_PORT >= 1 && 10#$HY2_PORT <= 65535 )) || die '端口必须为 1-65535。'
  HY2_PORT="$((10#$HY2_PORT))"
  while :; do
    IFS= read -r -p 'VLESS + REALITY TCP 端口 [8443]：' REALITY_PORT
    REALITY_PORT="${REALITY_PORT:-8443}"
    [[ "$REALITY_PORT" =~ ^[0-9]{1,5}$ ]] && (( 10#$REALITY_PORT >= 1 && 10#$REALITY_PORT <= 65535 )) || { warn '端口必须为 1-65535。'; continue; }
    REALITY_PORT="$((10#$REALITY_PORT))"
    case "$REALITY_PORT" in 22|80|443|3001|4000|5432|6379|9010|9011|9999|10085|10086|13333) warn '该端口为本安装器的服务或保留端口，请选择其他端口。';; *) break;; esac
  done
  while :; do
    IFS= read -r -p 'REALITY 伪装目标 SNI [www.microsoft.com]：' REALITY_SNI
    REALITY_SNI="${REALITY_SNI:-www.microsoft.com}"
    REALITY_SNI="${REALITY_SNI,,}"; REALITY_SNI="${REALITY_SNI%.}"
    valid_domain "$REALITY_SNI" && break
    warn 'REALITY SNI 格式错误。'
  done
  IFS= read -r -p '证书到期提醒邮箱（可留空）：' CERT_EMAIL
  [[ -z "$CERT_EMAIL" || "$CERT_EMAIL" =~ ^[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die '证书邮箱无效。'
  DB_PASS="$(rand_hex 24)"
  JWT_SECRET="$(rand_hex 32)"
  SETTINGS_KEY="$(head -c 32 /dev/urandom | base64 -w0)"
  STATS_SECRET="$(rand_hex 32)"
  XRAY_AGENT_SECRET="$(rand_hex 32)"
  XRAY_WS_AGENT_SECRET="$(rand_hex 32)"
  WS_PATH="/$(rand_hex 8)"
  WS_PORT=13333
  REALITY_PRIVATE_KEY=""
  REALITY_PUBLIC_KEY=""
  REALITY_SHORT_ID="$(rand_hex 8)"
  save_state
fi

# Root-only credentials survive interruptions and can be removed after saving elsewhere.
if [[ ! -f "$CREDENTIALS_FILE" ]]; then
  {
    printf '后台地址：https://%s/login\n' "$PANEL_DOMAIN"
    printf '管理员邮箱：%s\n' "$ADMIN_EMAIL"
    printf '管理员密码：%s\n' "$ADMIN_PASS"
    printf 'HY2：%s:%s/udp\n' "$HY2_DOMAIN" "$HY2_PORT"
    printf 'REALITY：%s:%s/tcp (SNI %s)\n' "$REALITY_DOMAIN" "$REALITY_PORT" "$REALITY_SNI"
    printf 'VLESS WS 本地：127.0.0.1:%s  路径：%s  （待套 Cloudflare Tunnel 后再到面板添加节点）\n' "$WS_PORT" "$WS_PATH"
    printf '请尽快转存密码，必要时可删除此文件。\n'
  } > "$CREDENTIALS_FILE"
  chmod 0600 "$CREDENTIALS_FILE"
fi

DB_URL="postgresql://hysteria2:${DB_PASS}@127.0.0.1:5432/hysteria2"
for d in "$PANEL_DOMAIN" "$HY2_DOMAIN" "$REALITY_DOMAIN"; do
  getent ahosts "$d" >/dev/null || die "域名 $d 尚未解析，请先设置 DNS。"
done
log "DNS 已解析：$PANEL_DOMAIN / $HY2_DOMAIN / $REALITY_DOMAIN"

SSH_PORTS=(22)
if [[ -x /usr/sbin/sshd ]]; then
  while read -r port; do
    [[ "$port" =~ ^[0-9]+$ ]] && (( port >= 1 && port <= 65535 )) && SSH_PORTS+=("$port")
  done < <(/usr/sbin/sshd -T 2>/dev/null | awk '$1=="port" {print $2}' || true)
fi
if [[ -n "${SSH_CONNECTION:-}" ]]; then
  read -r _ _ _ ACTIVE_SSH_PORT <<< "$SSH_CONNECTION"
  [[ "${ACTIVE_SSH_PORT:-}" =~ ^[0-9]+$ ]] && (( ACTIVE_SSH_PORT >= 1 && ACTIVE_SSH_PORT <= 65535 )) && SSH_PORTS+=("$ACTIVE_SSH_PORT")
fi
mapfile -t SSH_PORTS < <(printf '%s\n' "${SSH_PORTS[@]}" | sort -nu)
log "SSH 将放行 TCP 端口：${SSH_PORTS[*]}"
for p in "${SSH_PORTS[@]}"; do [[ "$REALITY_PORT" != "$p" ]] || die "REALITY TCP 端口 $REALITY_PORT 与 SSH 端口冲突。"; done

stage_packages() {
  apt-get update -y
  apt-get install -y ca-certificates curl gnupg git nginx certbot redis-server postgresql postgresql-client \
    nftables openssl python3 build-essential libatomic1 iproute2 unzip tar
  install -d -m 0755 /usr/share/keyrings
  curl --retry 4 --connect-timeout 15 -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
    | gpg --dearmor --yes -o /usr/share/keyrings/nodesource.gpg
  chmod 0644 /usr/share/keyrings/nodesource.gpg
  printf '%s\n' 'deb [signed-by=/usr/share/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main' \
    > /etc/apt/sources.list.d/nodesource.list
  apt-get update -y
  apt-get install -y nodejs
  ( umask 022; npm install -g pnpm@9.14.2 )
  local root
  root="$(npm root -g)"
  [[ -d "$root/pnpm" ]] || die '未找到 pnpm 全局目录。'
  chmod a+rx "$root"
  chmod -R a+rX "$root/pnpm"
  /usr/bin/pnpm --version
  node --version
}

stage_swap() {
  local mem avail
  mem="$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
  if (( mem < 3145728 )) && ! swapon --noheadings --show | grep -q .; then
    avail="$(df -Pk / | awk 'END{print $4}')"
    if (( avail > 6291456 )); then
      log 'RAM 小于 3GiB，创建 4GiB swap。'
      if [[ ! -e /swapfile ]]; then fallocate -l 4G /swapfile; fi
      chmod 0600 /swapfile
      mkswap /swapfile >/dev/null
      swapon /swapfile
      grep -qE '^/swapfile[[:space:]]' /etc/fstab || printf '/swapfile none swap sw 0 0\n' >> /etc/fstab
    else
      warn '可用磁盘不足以创建 swap；大型 Next.js 构建可能因 RAM 不足失败。'
    fi
  fi
}

stage_repository_db() {
  systemctl enable --now postgresql redis-server nginx
  pg_isready -h 127.0.0.1 -p 5432 >/dev/null || die 'PostgreSQL 未就绪。'
  [[ "$(redis-cli ping)" == PONG ]] || die 'Redis 未就绪。'
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_roles WHERE rolname='hysteria2'" | grep -qx 1; then
    runuser -u postgres -- psql -v ON_ERROR_STOP=1 -c "CREATE ROLE hysteria2 LOGIN PASSWORD '$DB_PASS'"
  fi
  if ! runuser -u postgres -- psql -tAc "SELECT 1 FROM pg_database WHERE datname='hysteria2'" | grep -qx 1; then
    runuser -u postgres -- createdb -O hysteria2 hysteria2
  fi
  if ! id "$APP_USER" >/dev/null 2>&1; then
    useradd --system --user-group --home-dir "$APP_DIR" --shell /usr/sbin/nologin "$APP_USER"
  fi
  install -d -m 0700 "$STATE_DIR"
  install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$BACKUP_DIR"
  install -d -m 0755 "$WEBROOT"
  if [[ -d "$APP_DIR/.git" ]]; then
    log '使用已存在的项目 Git 目录，不执行 git pull。'
  elif [[ ! -e "$APP_DIR" ]]; then
    local tempdir="${APP_DIR}.installing"
    [[ ! -L "$tempdir" ]] || die "可疑临时路径：$tempdir"
    if [[ -e "$tempdir" ]]; then rm -rf -- "$tempdir"; fi
    install -d -m 0750 -o "$APP_USER" -g "$APP_USER" "$tempdir"
    runuser -u "$APP_USER" -- env HOME=/tmp PATH=/usr/local/bin:/usr/bin:/bin \
      git clone --depth=1 --branch main "$REPOSITORY" "$tempdir"
    mv -- "$tempdir" "$APP_DIR"
  else
    die "$APP_DIR 已存在但没有 .git，拒绝覆盖或删除。"
  fi
  [[ -f "$APP_DIR/apps/api/prisma/schema.prisma" ]] || die 'Prisma schema 缺失，上游项目可能变更。'
  [[ -f "$APP_DIR/apps/api/prisma/migrations/migration_lock.toml" ]] || die '生产迁移目录缺失。'
  runuser -u "$APP_USER" -- git -C "$APP_DIR" rev-parse HEAD > "$STATE_DIR/source-commit"
  chmod 0600 "$STATE_DIR/source-commit"
}

stage_config() {
  cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=4000
DATABASE_URL=$DB_URL
BACKUP_MAINTENANCE_DATABASE_URL=postgresql://hysteria2:${DB_PASS}@127.0.0.1:5432/postgres
BACKUP_DIR=$BACKUP_DIR
BACKUP_RETENTION_COUNT=14
BACKUP_DAILY_HOUR=3
REDIS_URL=redis://127.0.0.1:6379
JWT_SECRET=$JWT_SECRET
SETTINGS_ENCRYPTION_KEY=$SETTINGS_KEY
SECRET_MIGRATION_ENABLED=false
API_PUBLIC_URL=https://$PANEL_DOMAIN
WEB_PUBLIC_URL=https://$PANEL_DOMAIN
CORS_ORIGINS=https://$PANEL_DOMAIN
SMTP_REQUIRED=false
NODE_SYNC_ENABLED=false
HYSTERIA_SYNC_ENABLED=false
NODE_OPERATIONS_ENABLED=true
NODE_RUNTIME_CONTROL_ENABLED=true
EPAY_RECONCILIATION_ENABLED=false
NEXT_PUBLIC_API_BASE_URL=https://$PANEL_DOMAIN
API_INTERNAL_URL=http://127.0.0.1:4000
SEO_IMAGE_DIR=$APP_DIR/storage/seo-images
EOF
  cp "$APP_DIR/.env" "$APP_DIR/apps/api/.env"
  cat > "$APP_DIR/apps/web/.env.production.local" <<EOF
NEXT_PUBLIC_API_BASE_URL=https://$PANEL_DOMAIN
API_INTERNAL_URL=http://127.0.0.1:4000
WEB_PUBLIC_URL=https://$PANEL_DOMAIN
EOF
  cp "$APP_DIR/apps/web/.env.production.local" "$APP_DIR/apps/web/.env.local"
  chown "$APP_USER:$APP_USER" "$APP_DIR/.env" "$APP_DIR/apps/api/.env" \
    "$APP_DIR/apps/web/.env.production.local" "$APP_DIR/apps/web/.env.local"
  chmod 0600 "$APP_DIR/.env" "$APP_DIR/apps/api/.env" \
    "$APP_DIR/apps/web/.env.production.local" "$APP_DIR/apps/web/.env.local"
  cat > "$INFO_FILE" <<EOF
PANEL_DOMAIN=$PANEL_DOMAIN
HY2_DOMAIN=$HY2_DOMAIN
REALITY_DOMAIN=$REALITY_DOMAIN
HY2_PORT=$HY2_PORT
STATS_SECRET=$STATS_SECRET
APP_DIR=$APP_DIR
EOF
  chmod 0600 "$INFO_FILE"
}

as_app() {
  local dir="$1"; shift
  runuser -u "$APP_USER" -- env HOME="$APP_DIR" PATH=/usr/local/bin:/usr/bin:/bin \
    /bin/bash -c 'cd "$1" && shift && exec "$@"' _ "$dir" "$@"
}

stage_dependencies() {
  as_app "$APP_DIR" /usr/bin/pnpm --version
  as_app "$APP_DIR" /usr/bin/pnpm install --frozen-lockfile
  as_app "$APP_DIR" /usr/bin/pnpm --dir apps/api exec prisma generate
  as_app "$APP_DIR" /usr/bin/pnpm --dir apps/api exec prisma migrate deploy
}

stage_xray_core() {
  local asset zip bin metadata sha url output
  case "$(uname -m)" in
    x86_64) asset=Xray-linux-64.zip;;
    aarch64) asset=Xray-linux-arm64-v8a.zip;;
  esac
  install -d -m 0700 /etc/xray /etc/xray-ws
  zip="$(mktemp /tmp/xray-release.XXXXXXXX.zip)"
  metadata="$(mktemp /tmp/xray-release.XXXXXXXX.json)"
  url="https://github.com/XTLS/Xray-core/releases/latest/download/$asset"
  sha=''
  if curl -fsSL --retry 2 --connect-timeout 15 https://api.github.com/repos/XTLS/Xray-core/releases/latest -o "$metadata"; then
    read -r url sha < <(python3 - "$metadata" "$asset" <<'PYX'
import json,sys
try:
    j=json.load(open(sys.argv[1]))
    a=next(x for x in j.get('assets',[]) if x['name']==sys.argv[2])
    print(a['browser_download_url'],a.get('digest','').removeprefix('sha256:') or '-')
except Exception:
    print('-', '-')
PYX
    )
    [[ "$url" != '-' ]] || url="https://github.com/XTLS/Xray-core/releases/latest/download/$asset"
  fi
  curl -fL --retry 4 --retry-delay 3 --connect-timeout 20 "$url" -o "$zip"
  if [[ -n "$sha" && "$sha" != '-' ]]; then
    printf '%s  %s\n' "$sha" "$zip" | sha256sum -c -
  else
    warn '该 GitHub 发行版未提供可用 SHA256 digest；请确认下载来源可信。'
  fi
  bin="$(mktemp /tmp/xray-bin.XXXXXXXX)"
  unzip -p "$zip" xray > "$bin"
  install -m 0755 "$bin" /usr/local/bin/xray
  rm -f "$bin" "$zip" "$metadata"
  /usr/local/bin/xray version
  if [[ -z "${REALITY_PRIVATE_KEY:-}" || -z "${REALITY_PUBLIC_KEY:-}" ]]; then
    output="$(/usr/local/bin/xray x25519)"
    local parsed
    if ! parsed="$(printf '%s\n' "$output" | python3 -c '
import re, sys
values = {}
for line in sys.stdin:
    if ":" not in line:
        continue
    label, value = line.split(":", 1)
    label = re.sub(r"[^a-z]", "", label.lower())
    value = value.strip()
    if label in ("privatekey", "password", "passwordpublickey", "publickey") and value:
        values[label] = value.split()[0]
private = values.get("privatekey")
public = values.get("passwordpublickey") or values.get("password") or values.get("publickey")
if not private or not public:
    sys.exit(2)
print(private, public)
')"; then
      die '无法解析 Xray x25519 密钥输出。检查当前 Xray 版本格式。'
    fi
    read -r REALITY_PRIVATE_KEY REALITY_PUBLIC_KEY <<< "$parsed"
    [[ -n "$REALITY_PRIVATE_KEY" && -n "$REALITY_PUBLIC_KEY" ]] || die 'REALITY 密钥解析结果为空。'
    save_state
  fi
  {
    printf 'REALITY_PORT=%s\n' "$REALITY_PORT"
    printf 'REALITY_SNI=%s\n' "$REALITY_SNI"
    printf 'REALITY_PUBLIC_KEY=%s\n' "$REALITY_PUBLIC_KEY"
    printf 'REALITY_SHORT_ID=%s\n' "$REALITY_SHORT_ID"
    printf 'XRAY_AGENT_SECRET=%s\n' "$XRAY_AGENT_SECRET"
  } >> "$INFO_FILE"
  chmod 0600 "$INFO_FILE"
  if ! grep -q '^REALITY 公钥：' "$CREDENTIALS_FILE"; then
    {
      printf 'REALITY 公钥：%s\n' "$REALITY_PUBLIC_KEY"
      printf 'REALITY Short ID：%s\n' "$REALITY_SHORT_ID"
    } >> "$CREDENTIALS_FILE"
    chmod 0600 "$CREDENTIALS_FILE"
  fi
  export REALITY_PRIVATE_KEY REALITY_SHORT_ID REALITY_PORT REALITY_SNI
  python3 - "$APP_DIR/ops/xray/vless-reality-server.json" > /etc/xray/config.json <<'PYX'
import json,os,sys
with open(sys.argv[1],encoding='utf-8') as f:
    obj=json.load(f)
obj['log']={'loglevel':'warning'}
obj['inbounds'][0]['port']=int(os.environ['REALITY_PORT'])
reality=obj['inbounds'][0]['streamSettings']['realitySettings']
reality['target']=os.environ['REALITY_SNI']+':443'
reality['serverNames']=[os.environ['REALITY_SNI']]
reality['privateKey']=os.environ['REALITY_PRIVATE_KEY']
reality['shortIds']=[os.environ['REALITY_SHORT_ID']]
assert obj['api']['listen'].startswith('127.0.0.1:')
assert obj['inbounds'][0]['settings']['users']==[]
print(json.dumps(obj,ensure_ascii=False,indent=2))
PYX
  chmod 0600 /etc/xray/config.json
  /usr/local/bin/xray run -test -config /etc/xray/config.json
  cat > /etc/systemd/system/xray.service <<'EOFSVC'
[Unit]
Description=Xray VLESS + REALITY Node
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray/config.json
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOFSVC
  systemctl daemon-reload
  # 配置每次都会重写，用 restart 确保生效（enable --now 对已运行服务是空操作）。
  systemctl enable xray
  systemctl restart xray
  local i
  for ((i=1; i<=30; i++)); do
    if ss -lnt "( sport = :$REALITY_PORT )" | grep -q ":$REALITY_PORT "; then break; fi
    sleep 2
  done
  systemctl is-active --quiet xray || { journalctl -u xray -n 40 --no-pager; die 'Xray 服务未运行。'; }
  ss -lnt "( sport = :$REALITY_PORT )" | grep -q ":$REALITY_PORT " || die 'VLESS REALITY TCP 监听端口未就绪。'
}

stage_xray_ws() {
  # VLESS + WS 本地节点：只监听 127.0.0.1，明文 WS，不套 Cloudflare。
  # 人工建好 CF Tunnel 后，再到面板手动添加节点（域名填 CF 域名，端口 443）。
  WS_PORT="$(pick_free_port "$WS_PORT")"
  save_state
  # 端口可能因冲突被重选，同步更新凭据文件中的 WS 行。
  if [[ -f "$CREDENTIALS_FILE" ]]; then
    sed -i -E \
      -e "s|^VLESS WS 本地：.*|VLESS WS 本地：127.0.0.1:${WS_PORT}  路径：${WS_PATH}  （待套 Cloudflare Tunnel 后再到面板添加节点）|" \
      -e "s|^VLESS WS 本地监听：.*|VLESS WS 本地监听：127.0.0.1:${WS_PORT}|" \
      "$CREDENTIALS_FILE"
  fi
  {
    printf 'WS_PORT=%s\n' "$WS_PORT"
    printf 'WS_PATH=%s\n' "$WS_PATH"
    printf 'XRAY_WS_AGENT_SECRET=%s\n' "$XRAY_WS_AGENT_SECRET"
  } >> "$INFO_FILE"
  chmod 0600 "$INFO_FILE"
  if ! grep -q '^VLESS WS 本地监听：' "$CREDENTIALS_FILE"; then
    {
      printf 'VLESS WS 本地监听：127.0.0.1:%s\n' "$WS_PORT"
      printf 'VLESS WS 路径：%s\n' "$WS_PATH"
      printf 'VLESS WS 采集地址：http://127.0.0.1:9011\n' 
      printf 'VLESS WS 采集密钥：%s\n' "$XRAY_WS_AGENT_SECRET"
    } >> "$CREDENTIALS_FILE"
    chmod 0600 "$CREDENTIALS_FILE"
  fi
  export WS_PORT WS_PATH
  # 注意：xray-ws.service 使用 ProtectSystem=strict（只读文件系统），不能写文件日志；
  # 与主 xray 服务保持一致，只设 loglevel，日志走 journal。
  python3 - "$APP_DIR/ops/xray/vless-ws-server.json" > /etc/xray-ws/config.json <<'PYX'
import json,os,sys
with open(sys.argv[1],encoding='utf-8') as f:
    obj=json.load(f)
obj['log']={'loglevel':'warning'}
inbound=obj['inbounds'][0]
assert inbound['tag']=='vless-ws'
inbound['port']=int(os.environ['WS_PORT'])
inbound['streamSettings']['wsSettings']['path']=os.environ['WS_PATH']
assert inbound['listen']=='127.0.0.1'
assert obj['api']['listen']=='127.0.0.1:10086'
assert inbound['settings']['users']==[]
print(json.dumps(obj,ensure_ascii=False,indent=2))
PYX
  chmod 0600 /etc/xray-ws/config.json
  /usr/local/bin/xray run -test -config /etc/xray-ws/config.json
  cat > /etc/systemd/system/xray-ws.service <<'EOFSVC'
[Unit]
Description=Xray VLESS + WS Local Node (for Cloudflare Tunnel)
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/xray run -config /etc/xray-ws/config.json
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOFSVC
  systemctl daemon-reload
  # 配置每次都会重写，必须 restart 确保运行中的实例加载新配置
  #（enable --now 在服务已运行时是空操作，会导致端口与配置不一致）。
  systemctl enable xray-ws
  systemctl restart xray-ws
  local i
  for ((i=1; i<=30; i++)); do
    if ss -lnt "( sport = :$WS_PORT )" | grep -q "127.0.0.1:$WS_PORT "; then break; fi
    sleep 2
  done
  systemctl is-active --quiet xray-ws || { journalctl -u xray-ws -n 40 --no-pager; die 'xray-ws 服务未运行。'; }
  ss -lnt | grep -q "127.0.0.1:$WS_PORT " || die 'VLESS WS 本地监听端口未就绪。'
  # WS 端口绝不能监听在公网地址上。（ss 表头不含地址，需跳过，否则误判）
  if ss -lnt "( sport = :$WS_PORT )" | tail -n +2 | grep -vq "127.0.0.1:$WS_PORT "; then
    die 'VLESS WS 端口暴露在非本地地址，拒绝继续。'
  fi
  log "VLESS WS 本地节点已就绪：127.0.0.1:$WS_PORT 路径 $WS_PATH"
}

stage_bootstrap() {
  local helper="$APP_DIR/apps/api/hysteria2-bootstrap.cjs"
  cat > "$helper" <<'JS'
'use strict';
require('dotenv').config({path: require('node:path').join(__dirname, '.env')});
const fs = require('node:fs');
const { PrismaClient } = require('@prisma/client');
const { hash } = require('bcryptjs');
const { createCipheriv, randomBytes } = require('node:crypto');
const prisma = new PrismaClient();
function encrypt(value) {
  const key = Buffer.from(process.env.SETTINGS_ENCRYPTION_KEY || '', 'base64');
  if (key.length !== 32) throw new Error('Invalid settings encryption key');
  const iv = randomBytes(12);
  const cipher = createCipheriv('aes-256-gcm', key, iv);
  const encrypted = Buffer.concat([cipher.update(value, 'utf8'), cipher.final()]);
  return ['enc:v1',iv.toString('base64url'),cipher.getAuthTag().toString('base64url'),encrypted.toString('base64url')].join(':');
}
async function main() {
  const email = process.env.H2_ADMIN_EMAIL;
  const hy2Domain = process.env.H2_HY2_DOMAIN;
  const realityDomain = process.env.H2_REALITY_DOMAIN;
  const port = Number(process.env.H2_PORT);
  const secret = process.env.H2_STATS_SECRET;
  const agentSecret = process.env.H2_XRAY_AGENT_SECRET;
  const realityPort = Number(process.env.H2_REALITY_PORT);
  const realitySni = process.env.H2_REALITY_SNI;
  const realityKey = process.env.H2_REALITY_PUBLIC_KEY;
  const realityShortId = process.env.H2_REALITY_SHORT_ID;
  const pass = fs.readFileSync(0, 'utf8');
  if (!email || !hy2Domain || !realityDomain || !secret || !agentSecret || !realitySni || !realityKey || !realityShortId || pass.length < 12 || !Number.isInteger(port) || !Number.isInteger(realityPort)) throw new Error('Incomplete bootstrap parameters');
  const priorAdmin = await prisma.user.findUnique({where: {email}});
  const priorNode = await prisma.node.findUnique({where: {id:'local-hysteria2'}});
  const priorReality = await prisma.node.findUnique({where: {id:'local-vless-reality'}});
  if (priorAdmin && priorNode && priorReality) {
    if (priorAdmin.role !== 'ADMIN') throw new Error('Existing account is not an admin; manual intervention required');
    console.log('Bootstrap data already present; preserving existing admin password.');
    return;
  }
  if (priorAdmin || priorNode || priorReality) throw new Error('Incomplete existing bootstrap data; refusing to overwrite.');
  const hashed = await hash(pass, 12);
  await prisma.$transaction(async tx => {
    const admin = await tx.user.create({data: {
      email, displayName: 'Site Administrator', passwordHash: hashed, role:'ADMIN', status:'ACTIVE'
    }});
    for (const permission of ['AGENT_UPDATES_MANAGE','DESTINATION_AUDIT_READ','ADMIN_PERMISSIONS_MANAGE','SEO_CONTENT_MANAGE']) {
      await tx.adminPermissionGrant.create({data:{userId:admin.id,permission}});
    }
    const server = await tx.nodeServer.create({data: {
      slug:'local-server', name:'本机节点服务器',hostname:hy2Domain,provider:'Self-hosted'
    }});
    await tx.node.create({data: {
      id:'local-hysteria2',serverId:server.id,protocol:'HYSTERIA2',label:'Local Hysteria2',
      hostname:hy2Domain,port,sni:hy2Domain,trafficApiBaseUrl:'http://127.0.0.1:9999',
      trafficApiSecret:encrypt(secret),
      controlApiBaseUrl:'http://127.0.0.1:9010',controlApiSecret:encrypt(agentSecret),
      active:true,tags:['local','hysteria2'],
      speedUpMbps:100,speedDownMbps:100
    }});
    await tx.node.create({data: {
      id:'local-vless-reality',serverId:server.id,protocol:'VLESS_REALITY',label:'Local VLESS + REALITY',
      hostname:realityDomain,port:realityPort,sni:realitySni,realityPublicKey:realityKey,
      realityShortId,realityFingerprint:'chrome',vlessFlow:'xtls-rprx-vision',
      trafficApiBaseUrl:'http://127.0.0.1:9010',trafficApiSecret:encrypt(agentSecret),
      controlApiBaseUrl:'http://127.0.0.1:9010',controlApiSecret:encrypt(agentSecret),
      active:true,tags:['local','vless','reality'],speedUpMbps:100,speedDownMbps:100
    }});
    // 注意：VLESS WS 节点不在此自动建档。人工到 Cloudflare 建好 Tunnel 后，
    // 再到面板手动添加（协议选 VLESS + WS，域名填 CF 域名，端口 443）。
  });
  console.log('Administrator and both local protocol nodes created.');
}
main().catch(e=>{console.error(e);process.exitCode=1}).finally(()=>prisma.$disconnect());
JS
  chown "$APP_USER:$APP_USER" "$helper"
  chmod 0600 "$helper"
  printf '%s' "$ADMIN_PASS" | runuser -u "$APP_USER" -- env HOME="$APP_DIR" \
    H2_ADMIN_EMAIL="$ADMIN_EMAIL" H2_HY2_DOMAIN="$HY2_DOMAIN" H2_REALITY_DOMAIN="$REALITY_DOMAIN" \
    H2_PORT="$HY2_PORT" \
    H2_STATS_SECRET="$STATS_SECRET" H2_XRAY_AGENT_SECRET="$XRAY_AGENT_SECRET" \
    H2_REALITY_PORT="$REALITY_PORT" H2_REALITY_SNI="$REALITY_SNI" \
    H2_REALITY_PUBLIC_KEY="$REALITY_PUBLIC_KEY" H2_REALITY_SHORT_ID="$REALITY_SHORT_ID" \
    /usr/bin/node "$helper"
  rm -f "$helper"
}

stage_build() {
  as_app "$APP_DIR" /usr/bin/pnpm --filter @hysteria/api build
  as_app "$APP_DIR" /usr/bin/pnpm --filter @hysteria/web build
  [[ -s "$APP_DIR/apps/api/dist/src/main.js" ]] || die 'API dist/src/main.js 缺失。'
  [[ -s "$APP_DIR/apps/api/dist/src/sync-worker.js" ]] || die 'sync-worker 构建产物缺失，拒绝继续。'
  [[ -d "$APP_DIR/apps/web/.next" ]] || die 'Web .next 构建目录缺失。'
}

wait_http() {
  local label="$1" url="$2" tries="${3:-60}" i
  for ((i=1; i<=tries; i++)); do
    if curl --noproxy '*' --silent --fail --max-time 4 -o /dev/null "$url"; then
      log "$label 已通过健康检查。"
      return 0
    fi
    sleep 2
  done
  warn "$label 超时，最后的 HTTP 响应："
  curl --noproxy '*' -sSi --max-time 5 "$url" || true
  die "$label 健康检查失败。"
}

cert_domains() {
  # 去重后的证书域名：面板域名 + HY2 节点域名（REALITY 不需要真实证书）。
  local out=()
  local d
  for d in "$PANEL_DOMAIN" "$HY2_DOMAIN"; do
    [[ " ${out[*]} " == *" $d "* ]] || out+=("$d")
  done
  printf '%s\n' "${out[@]}"
}

stage_web_api() {
  if ! nft list table inet h2_install_guard >/dev/null 2>&1; then
    nft add table inet h2_install_guard
    nft 'add chain inet h2_install_guard input { type filter hook input priority -10; policy accept; }'
    nft 'add rule inet h2_install_guard input iifname != "lo" tcp dport {3001,4000,5432,6379,9010,9011,9999,10085,10086} drop'
  fi
  if [[ -f /etc/nftables.conf && ! -f "$STATE_DIR/nftables.initial.conf" ]]; then
    cp -a /etc/nftables.conf "$STATE_DIR/nftables.initial.conf"
  fi
  { printf '#!/usr/sbin/nft -f\nflush ruleset\n'; nft list ruleset; } > /etc/nftables.conf
  chmod 0644 /etc/nftables.conf
  nft -c -f /etc/nftables.conf
  systemctl enable nftables >/dev/null
  cat > /etc/systemd/system/hysteria2-api.service <<EOF
[Unit]
Description=Hysteria2 Control Plane API
After=network-online.target postgresql.service redis-server.service
Wants=network-online.target
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/node $APP_DIR/apps/api/dist/src/main.js
Restart=always
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  cat > /etc/systemd/system/hysteria2-web.service <<EOF
[Unit]
Description=Hysteria2 Control Plane Web
After=network-online.target hysteria2-api.service
Wants=network-online.target
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR/apps/web
Environment=NODE_ENV=production
Environment=NEXT_TELEMETRY_DISABLED=1
ExecStart=/usr/bin/node $APP_DIR/apps/web/node_modules/next/dist/bin/next start --port 3001 --hostname 127.0.0.1
Restart=always
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria2-api hysteria2-web
  wait_http 'API liveness' 'http://127.0.0.1:4000/api/health/live' 60
  wait_http 'Web 登录页' 'http://127.0.0.1:3001/login' 60
}

stage_https() {
  rm -f /etc/nginx/sites-enabled/default
  cat > /etc/nginx/sites-available/hysteria2-control-plane <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name $PANEL_DOMAIN;
  location ^~ /.well-known/acme-challenge/ {
    root $WEBROOT;
    default_type text/plain;
    try_files \$uri =404;
  }
  location / { return 200 'ACME bootstrap'; }
}
EOF
  ln -sfn /etc/nginx/sites-available/hysteria2-control-plane /etc/nginx/sites-enabled/hysteria2-control-plane
  nginx -t
  systemctl reload nginx
  if [[ ! -s "/etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem" ]]; then
    local cert_args=(certonly --webroot -w "$WEBROOT" --cert-name "$PANEL_DOMAIN" --non-interactive --agree-tos)
    local d
    while read -r d; do cert_args+=(-d "$d"); done < <(cert_domains)
    if [[ -n "$CERT_EMAIL" ]]; then
      cert_args+=(--email "$CERT_EMAIL")
    else
      cert_args+=(--register-unsafely-without-email)
    fi
    log "签发 HTTPS 证书（域名：$(cert_domains | paste -sd' ' -)），需要公网 TCP/80 可访问。"
    certbot "${cert_args[@]}"
  fi
  [[ -s "/etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem" ]] || die '证书私钥未生成。'
  cat > /etc/nginx/sites-available/hysteria2-control-plane <<EOF
server {
  listen 80;
  listen [::]:80;
  server_name $PANEL_DOMAIN;
  location ^~ /.well-known/acme-challenge/ {
    root $WEBROOT;
    default_type text/plain;
    try_files \$uri =404;
  }
  location / { return 301 https://\$host\$request_uri; }
}
server {
  listen 443 ssl;
  listen [::]:443 ssl;
  http2 on;
  server_name $PANEL_DOMAIN;
  ssl_certificate /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem;
  ssl_certificate_key /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem;
  ssl_protocols TLSv1.2 TLSv1.3;
  client_max_body_size 25m;
  server_tokens off;
  location ^~ /api/ {
    proxy_pass http://127.0.0.1:4000;
    proxy_set_header Host \$host;
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 120s;
  }
  location / {
    proxy_pass http://127.0.0.1:3001;
    proxy_http_version 1.1;
    proxy_set_header Host \$host;
    proxy_set_header Upgrade \$http_upgrade;
    proxy_set_header Connection 'upgrade';
    proxy_set_header X-Real-IP \$remote_addr;
    proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    proxy_set_header X-Forwarded-Proto https;
    proxy_read_timeout 120s;
  }
}
EOF
  nginx -t
  systemctl reload nginx
  curl --noproxy '*' -fsS --max-time 8 --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
    "https://$PANEL_DOMAIN/login" -o /dev/null || die 'HTTPS 前端代理验证失败。'
}

stage_node() {
  local arch
  case "$(uname -m)" in
    x86_64) arch=amd64;;
    aarch64) arch=arm64;;
  esac
  curl --retry 4 --connect-timeout 15 -fsSL \
    "https://download.hysteria.network/app/latest/hysteria-linux-${arch}" \
    -o /tmp/hysteria2-node-download
  install -m 0755 /tmp/hysteria2-node-download /usr/local/bin/hysteria
  rm -f /tmp/hysteria2-node-download
  cat > "$STATE_DIR/node.yaml" <<EOF
listen: :$HY2_PORT
tls:
  cert: /etc/letsencrypt/live/$PANEL_DOMAIN/fullchain.pem
  key: /etc/letsencrypt/live/$PANEL_DOMAIN/privkey.pem
bandwidth:
  up: 100 mbps
  down: 100 mbps
auth:
  type: http
  http:
    url: http://127.0.0.1:4000/integrations/hysteria/auth?nodeId=local-hysteria2
trafficStats:
  listen: 127.0.0.1:9999
  secret: $STATS_SECRET
EOF
  chmod 0600 "$STATE_DIR/node.yaml"
  cat > /etc/systemd/system/hysteria2-node.service <<EOF
[Unit]
Description=Hysteria 2 local multi-user node
Wants=network-online.target
After=network-online.target hysteria2-api.service
[Service]
Type=simple
User=root
ExecStart=/usr/local/bin/hysteria server -c $STATE_DIR/node.yaml
Restart=always
RestartSec=5
NoNewPrivileges=true
ProtectHome=true
ProtectSystem=strict
PrivateTmp=true
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria2-node
  local ok=0 i
  for ((i=1; i<=30; i++)); do
    if curl --noproxy '*' -fsS --silent --max-time 4 -H "Authorization: $STATS_SECRET" \
      http://127.0.0.1:9999/online -o /dev/null; then ok=1; break; fi
    sleep 2
  done
  if (( ok == 0 )); then journalctl -u hysteria2-node -n 60 --no-pager; die '节点流量统计 API 未就绪。'; fi
  curl --noproxy '*' -fsS --max-time 5 -H 'Content-Type: application/json' \
    -d '{"addr":"127.0.0.1:12345","auth":"invalid-bootstrap-probe","tx":0}' \
    'http://127.0.0.1:4000/integrations/hysteria/auth?nodeId=local-hysteria2' \
    -o /dev/null || die 'Hysteria HTTP 鉴权路由无响应。'
}

stage_xray_agent() {
  local gojson gofile gosum goarch gotar
  case "$(uname -m)" in x86_64) goarch=amd64;; aarch64) goarch=arm64;; esac
  gojson="$(mktemp /tmp/golang-releases.XXXXXXXX.json)"
  curl -fLsS --retry 4 --connect-timeout 15 'https://go.dev/dl/?mode=json' -o "$gojson"
  read -r gofile gosum < <(python3 - "$gojson" "$goarch" <<'PYGO'
import json,sys
versions=json.load(open(sys.argv[1]))
for ver in versions:
    for f in ver.get('files',[]):
        if f.get('os')=='linux' and f.get('arch')==sys.argv[2] and f.get('kind')=='archive' and tuple(map(int, ver['version'][2:].split('.')[:2])) >= (1,26):
            print(f['filename'],f['sha256']);raise SystemExit
raise SystemExit('No Go 1.26+ archive found in official metadata')
PYGO
  )
  [[ -n "$gofile" && "$gosum" =~ ^[0-9a-f]{64}$ ]] || die '未获取到带 SHA256 校验的 Go 1.26+ 版本。'
  gotar="$(mktemp /tmp/golang-toolchain.XXXXXXXX.tar.gz)"
  curl -fLsS --retry 4 --connect-timeout 20 "https://go.dev/dl/$gofile" -o "$gotar"
  printf '%s  %s\n' "$gosum" "$gotar" | sha256sum -c -
  rm -rf /usr/local/go
  tar -C /usr/local -xzf "$gotar"
  rm -f "$gotar" "$gojson"
  /usr/local/go/bin/go version
  [[ -s "$APP_DIR/ops/xray-agent/go.sum" ]] || die '上游缺少 xray-agent/go.sum，拒绝不受控的依赖更新。'
  as_app "$APP_DIR/ops/xray-agent" /usr/bin/env \
    GOCACHE="$APP_DIR/.cache/go-build" GOPATH="$APP_DIR/.local/go" \
    /usr/local/go/bin/go build -mod=readonly -trimpath -o "$APP_DIR/ops/xray-agent/hysteria2-xray-agent" .
  install -m 0755 "$APP_DIR/ops/xray-agent/hysteria2-xray-agent" /usr/local/bin/hysteria2-xray-agent
  cat > /etc/hysteria2-xray-agent.env <<EOF
XRAY_AGENT_SECRET=$XRAY_AGENT_SECRET
XRAY_AGENT_LISTEN=127.0.0.1:9010
XRAY_API_ADDRESS=127.0.0.1:10085
XRAY_INBOUND_TAG=vless-reality
XRAY_AGENT_STATE_FILE=/var/lib/hysteria2-xray-agent/traffic-batch.json
XRAY_AGENT_CONTROL_SERVICES=xray=xray.service,hysteria2=hysteria2-node.service
EOF
  chmod 0600 /etc/hysteria2-xray-agent.env
  install -m 0644 "$APP_DIR/ops/xray-agent/hysteria2-xray-agent.service" /etc/systemd/system/hysteria2-xray-agent.service
  systemctl daemon-reload
  systemctl enable --now hysteria2-xray-agent
  local i status
  status=0
  for ((i=1; i<=50; i++)); do
    if curl --noproxy '*' -fsS --silent --max-time 5 \
      -H "Authorization: $XRAY_AGENT_SECRET" http://127.0.0.1:9010/health -o /dev/null; then status=1;break;fi
    sleep 2
  done
  if (( status == 0 )); then
    journalctl -u hysteria2-xray-agent -u xray -n 70 --no-pager -l || true
    die 'Xray Agent 未通过 /health 验证。'
  fi
  ss -lnt | grep -q '127.0.0.1:9010' || die 'Agent 未绑定到本地 127.0.0.1:9010。'
  ss -lnt | grep -q '127.0.0.1:10085' || die 'Xray gRPC 未绑定到本地 127.0.0.1:10085。'
}

stage_xray_agent_ws() {
  # VLESS WS 专用 Agent 实例：复用同一个二进制，独立监听端口/状态文件/密钥。
  # XRAY_DEFAULT_FLOW 为空：WS 用户绝不能带 XTLS flow。
  cat > /etc/hysteria2-xray-agent-ws.env <<EOF
XRAY_AGENT_SECRET=$XRAY_WS_AGENT_SECRET
XRAY_AGENT_LISTEN=127.0.0.1:9011
XRAY_API_ADDRESS=127.0.0.1:10086
XRAY_INBOUND_TAG=vless-ws
XRAY_DEFAULT_FLOW=
XRAY_AGENT_STATE_FILE=/var/lib/hysteria2-xray-agent-ws/traffic-batch.json
XRAY_AGENT_CONTROL_SERVICES=xray-ws=xray-ws.service
EOF
  chmod 0600 /etc/hysteria2-xray-agent-ws.env
  cat > /etc/systemd/system/hysteria2-xray-agent-ws.service <<'EOFSVC'
[Unit]
Description=Hysteria2 Control Plane Node Agent (VLESS WS)
After=network-online.target xray-ws.service
Wants=network-online.target
[Service]
Type=simple
EnvironmentFile=/etc/hysteria2-xray-agent-ws.env
ExecStart=/usr/local/bin/hysteria2-xray-agent
Restart=on-failure
RestartSec=3
NoNewPrivileges=true
PrivateTmp=true
StateDirectory=hysteria2-xray-agent-ws
ProtectSystem=strict
ProtectHome=true
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
[Install]
WantedBy=multi-user.target
EOFSVC
  systemctl daemon-reload
  systemctl enable --now hysteria2-xray-agent-ws
  local i status
  status=0
  for ((i=1; i<=50; i++)); do
    if curl --noproxy '*' -fsS --silent --max-time 5 \
      -H "Authorization: $XRAY_WS_AGENT_SECRET" http://127.0.0.1:9011/health -o /dev/null; then status=1;break;fi
    sleep 2
  done
  if (( status == 0 )); then
    journalctl -u hysteria2-xray-agent-ws -u xray-ws -n 70 --no-pager -l || true
    die 'VLESS WS Agent 未通过 /health 验证。'
  fi
  ss -lnt | grep -q '127.0.0.1:9011' || die 'WS Agent 未绑定到本地 127.0.0.1:9011。'
  ss -lnt | grep -q '127.0.0.1:10086' || die 'xray-ws gRPC 未绑定到本地 127.0.0.1:10086。'
  log 'VLESS WS Agent 已就绪：127.0.0.1:9011（采集地址），Xray gRPC 127.0.0.1:10086。'
}

repair_backup_permissions() {
  [[ ! -L "$BACKUP_DIR" ]] || die "备份路径是符号链接，拒绝修改：$BACKUP_DIR"
  install -d -m 0700 -o "$APP_USER" -g "$APP_USER" "$BACKUP_DIR"
  chown -R "$APP_USER:$APP_USER" "$BACKUP_DIR"
  chmod 0700 "$BACKUP_DIR"
  if ! runuser -u "$APP_USER" -- /bin/sh -c '
    p=$(mktemp "$1/.write-check.XXXXXXXX") && rm -f "$p"
  ' _ "$BACKUP_DIR"; then
    namei -l "$BACKUP_DIR" || true
    die "Worker 用户 $APP_USER 无法写入 $BACKUP_DIR。"
  fi
}

stage_worker() {
  log "确保 Worker 可读写备份目录（含 .backup.lock）。"
  repair_backup_permissions
  cat > /etc/systemd/system/hysteria2-worker.service <<EOF
[Unit]
Description=Hysteria2 Control Plane Background Sync Worker
Wants=network-online.target
After=network-online.target postgresql.service redis-server.service hysteria2-api.service
[Service]
Type=simple
User=$APP_USER
Group=$APP_USER
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
Environment=NODE_ENV=production
ExecStart=/usr/bin/node $APP_DIR/apps/api/dist/src/sync-worker.js
Restart=always
RestartSec=5
NoNewPrivileges=true
UMask=0077
LimitNOFILE=65535
[Install]
WantedBy=multi-user.target
EOF
  sed -i 's/^NODE_SYNC_ENABLED=false$/NODE_SYNC_ENABLED=true/' "$APP_DIR/.env" "$APP_DIR/apps/api/.env"
  systemctl daemon-reload
  systemctl restart hysteria2-api
  systemctl enable hysteria2-worker
  systemctl restart hysteria2-worker
  wait_http 'API + 真实节点同步 readiness' 'http://127.0.0.1:4000/api/health/ready' 90
  systemctl is-active --quiet hysteria2-worker || die '同步 Worker 已停止。'
}

stage_backups() {
  repair_backup_permissions
  printf '127.0.0.1:5432:hysteria2:hysteria2:%s\n' "$DB_PASS" > "$STATE_DIR/pgpass"
  chmod 0600 "$STATE_DIR/pgpass"
  printf '127.0.0.1:5432:hysteria2:hysteria2:%s\n' "$DB_PASS" > "$APP_DIR/.pgpass"
  chown "$APP_USER:$APP_USER" "$APP_DIR/.pgpass"
  chmod 0600 "$APP_DIR/.pgpass"
  cat > /usr/local/sbin/hysteria2-db-backup <<EOF
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
export PGPASSFILE=$APP_DIR/.pgpass
mkdir -p $BACKUP_DIR
pg_dump -h 127.0.0.1 -p 5432 -U hysteria2 -d hysteria2 -Fc -f $BACKUP_DIR/hysteria2-\$(date -u +%Y%m%dT%H%M%SZ).dump
find $BACKUP_DIR -maxdepth 1 -type f -name 'hysteria2-*.dump' -mtime +14 -delete
EOF
  chown root:"$APP_USER" /usr/local/sbin/hysteria2-db-backup
  chmod 0750 /usr/local/sbin/hysteria2-db-backup
  cat > /etc/systemd/system/hysteria2-db-backup.service <<'EOF'
[Unit]
Description=Hysteria2 PostgreSQL daily backup
After=postgresql.service
[Service]
Type=oneshot
User=hysteria2
Group=hysteria2
UMask=0077
ExecStart=/usr/local/sbin/hysteria2-db-backup
EOF
  cat > /etc/systemd/system/hysteria2-db-backup.timer <<'EOF'
[Unit]
Description=Schedule Hysteria2 database backup
[Timer]
OnCalendar=*-*-* 03:20:00
Persistent=true
[Install]
WantedBy=timers.target
EOF
  systemctl daemon-reload
  systemctl enable --now hysteria2-db-backup.timer
  systemctl start hysteria2-db-backup.service
  find "$BACKUP_DIR" -maxdepth 1 -type f -name 'hysteria2-*.dump' -size +0c | grep -q . || die '数据库备份文件为空。'
  install -d -m 0755 /etc/letsencrypt/renewal-hooks/deploy
  cat > /etc/letsencrypt/renewal-hooks/deploy/hysteria2-reload <<'EOF'
#!/bin/sh
set -eu
systemctl reload nginx
systemctl restart hysteria2-node
EOF
  chmod 0755 /etc/letsencrypt/renewal-hooks/deploy/hysteria2-reload
  systemctl enable --now certbot.timer 2>/dev/null || warn '未发现 certbot.timer，请手动确认续期计划。'
}

stage_firewall() {
  local tcp_ports='22, 80, 443' p stamp prior backup newconf rollback unit
  for p in "${SSH_PORTS[@]}"; do [[ "$p" == 22 ]] || tcp_ports+=", $p"; done
  tcp_ports+=", $REALITY_PORT"
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  prior="$STATE_DIR/nftables.conf.before-$stamp"
  backup="$STATE_DIR/nftables.ruleset.before-$stamp.nft"
  newconf="$STATE_DIR/nftables.new-$stamp.conf"
  rollback="$STATE_DIR/firewall-rollback-$stamp.sh"
  if [[ -f /etc/nftables.conf ]]; then cp -a /etc/nftables.conf "$prior"; fi
  { printf 'flush ruleset\n'; nft list ruleset; } > "$backup"
  chmod 0600 "$backup"
  cat > "$newconf" <<EOF
#!/usr/sbin/nft -f
flush ruleset
table inet hysteria2_filter {
  chain input {
    type filter hook input priority 0; policy drop;
    iifname "lo" accept
    ct state invalid drop
    ct state established,related accept
    ip protocol icmp accept
    meta l4proto ipv6-icmp accept
    tcp dport { $tcp_ports } accept
    udp dport $HY2_PORT accept
  }
  chain forward { type filter hook forward priority 0; policy drop; }
  chain output { type filter hook output priority 0; policy accept; }
}
EOF
  nft -c -f "$newconf" || die '防火墙语法检查失败。'
  cat > "$rollback" <<EOF
#!/usr/bin/env bash
set -eu
if [[ -f "$prior" ]]; then cp -a "$prior" /etc/nftables.conf;
else printf '#!/usr/sbin/nft -f\nflush ruleset\n' > /etc/nftables.conf; fi
/usr/sbin/nft -f "$backup"
EOF
  chmod 0700 "$rollback"
  unit="hysteria2-fw-rollback-$(date +%s)"
  systemd-run --quiet --unit="$unit" --on-active=240s /bin/bash "$rollback" || die '无法启动 SSH 防火墙回滚保护。'
  install -m 0644 "$newconf" /etc/nftables.conf
  if ! nft -f /etc/nftables.conf; then
    bash "$rollback" || true
    die '防火墙启用失败，已尝试恢复原规则。'
  fi
  systemctl enable nftables >/dev/null
  if ! curl --noproxy '*' -fsS --max-time 8 --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
     "https://$PANEL_DOMAIN/api/health/ready" -o /dev/null; then
    bash "$rollback" || true
    die '防火墙启用后 HTTPS 检查失败，已恢复原规则。'
  fi
  printf '\n[安全确认] 已启用默认 DROP。建议另开一个 SSH 窗口测试新连接。\n'
  printf '请在 180 秒内按回车确认；如失联，计划约 240 秒后自动回滚。\n'
  if ! IFS= read -r -t 180 -p '确认新 SSH 连接正常后按 Enter：' _reply; then
    warn '未确认连通性；回滚定时器仍在运行。可待回滚后重新运行脚本。'
    return 1
  fi
  systemctl stop "${unit}.timer" || die '无法取消防火墙回滚定时器！请立即检查 systemctl list-timers。'
  log '防火墙确认成功，自动回滚已取消。'
}

verify_firewall_active() {
  local nft_json
  if ! nft_json="$(nft -j list chain inet hysteria2_filter input 2>&1)"; then
    warn "无法读取运行中的 hysteria2_filter/input 链：$nft_json"
    return 1
  fi
  if ! python3 -c '
import json, sys
reality_port = int(sys.argv[1])
hy2_port = int(sys.argv[2])
ssh_ports = {int(p) for p in sys.argv[3:]}
try:
    doc = json.load(sys.stdin)
except (ValueError, TypeError) as e:
    print("[ERROR] nftables JSON 解析失败：", e, file=sys.stderr)
    sys.exit(1)
entries = doc.get("nftables", [])
chains = [x["chain"] for x in entries if "chain" in x
          and x["chain"].get("family") == "inet"
          and x["chain"].get("table") == "hysteria2_filter"
          and x["chain"].get("name") == "input"]
if len(chains) != 1:
    print("[ERROR] 没有找到唯一的 inet hysteria2_filter/input 链。", file=sys.stderr)
    sys.exit(1)
chain = chains[0]
if chain.get("hook") != "input" or chain.get("policy", "").lower() != "drop":
    print("[ERROR] 当前 INPUT 链不是默认 DROP：" + str(chain), file=sys.stderr)
    sys.exit(1)
def values(v):
    if isinstance(v, int):
        return {v}
    if isinstance(v, str) and v.isdecimal():
        return {int(v)}
    if isinstance(v, list):
        result = set()
        for x in v:
            result |= values(x)
        return result
    if isinstance(v, dict) and "set" in v:
        return values(v["set"])
    return set()
allowed = {"tcp": set(), "udp": set()}
for item in entries:
    rule = item.get("rule")
    if not rule or (rule.get("family"), rule.get("table"), rule.get("chain")) != (
        "inet", "hysteria2_filter", "input"):
        continue
    expr = rule.get("expr", [])
    if not any(isinstance(e, dict) and "accept" in e for e in expr):
        continue
    for e in expr:
        match = e.get("match", {}) if isinstance(e, dict) else {}
        payload = match.get("left", {}).get("payload", {}) if isinstance(match.get("left"), dict) else {}
        proto = payload.get("protocol")
        if match.get("op") == "==" and payload.get("field") == "dport" and proto in allowed:
            allowed[proto] |= values(match.get("right"))
required_tcp = ssh_ports | {22, 80, 443, reality_port}
required_udp = {hy2_port}
missing_tcp = sorted(required_tcp - allowed["tcp"])
missing_udp = sorted(required_udp - allowed["udp"])
if missing_tcp or missing_udp:
    print("[ERROR] 防火墙缺少必要的入站放行：TCP=" + str(missing_tcp)
          + " UDP=" + str(missing_udp), file=sys.stderr)
    sys.exit(1)
print("[INFO] 已验证实时 nftables：INPUT DROP；TCP 允许 "
      + ",".join(map(str, sorted(required_tcp)))
      + "；UDP 允许 " + ",".join(map(str, sorted(required_udp))))
' "$REALITY_PORT" "$HY2_PORT" "${SSH_PORTS[@]}" <<< "$nft_json"; then
    warn 'nftables 实际生效规则：'
    nft list chain inet hysteria2_filter input >&2 || true
    return 1
  fi
  if ! systemctl is-enabled --quiet nftables; then
    warn 'nftables 未设置开机自启，重启后防火墙可能无法持久化。'
    return 1
  fi
}

final_checks() {
  local svc
  for svc in hysteria2-api hysteria2-web hysteria2-node hysteria2-worker xray xray-ws hysteria2-xray-agent hysteria2-xray-agent-ws nginx postgresql redis-server; do
    systemctl is-active --quiet "$svc" || die "$svc 未运行。"
  done
  systemctl is-active --quiet hysteria2-db-backup.timer || die '数据库备份 timer 未运行。'
  wait_http '最终节点 readiness' 'http://127.0.0.1:4000/api/health/ready' 8
  local runtime_try runtime_ok
  runtime_ok=0
  for ((runtime_try=1; runtime_try<=24; runtime_try++)); do
    if as_app "$APP_DIR/apps/api" /usr/bin/node -e '
      require("dotenv").config({path:".env"});
      const {PrismaClient}=require("@prisma/client");
      const db=new PrismaClient();
      db.node.findMany({where:{id:{in:["local-hysteria2","local-vless-reality"]}},
        select:{id:true,runtimeState:true,runtimeStateObservedAt:true}})
        .then(nodes=>{
          if(nodes.length!==2 || nodes.some(n=>n.runtimeState!=="ACTIVE" ||
             !n.runtimeStateObservedAt ||
             Date.now()-new Date(n.runtimeStateObservedAt).getTime()>90000)) process.exitCode=1;
        })
        .catch(()=>{process.exitCode=1})
        .finally(()=>db.$disconnect());
    ' >/dev/null 2>&1; then
      runtime_ok=1
      break
    fi
    sleep 5
  done
  if (( runtime_ok == 0 )); then
    journalctl -u hysteria2-worker -n 60 --no-pager -l || true
    die '双节点运行状态未在规定时间内采集到 ACTIVE（readiness 不能替代此检查）。'
  fi
  log '双节点运行状态已采集，均为 ACTIVE。'
  curl --noproxy '*' -fsS --max-time 10 --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
    "https://$PANEL_DOMAIN/api/health/ready" -o /dev/null || die 'HTTPS API 验证失败。'
  curl --noproxy '*' -fsS --max-time 10 --resolve "$PANEL_DOMAIN:443:127.0.0.1" \
    "https://$PANEL_DOMAIN/login" -o /dev/null || die 'HTTPS Web 验证失败。'
  curl --noproxy '*' -fsS --max-time 5 -H "Authorization: $STATS_SECRET" \
    http://127.0.0.1:9999/traffic -o /dev/null || die '节点流量 API 验证失败。'
  curl --noproxy '*' -fsS --max-time 5 -H "Authorization: $XRAY_AGENT_SECRET" \
    http://127.0.0.1:9010/health -o /dev/null || die 'REALITY Agent 最终验证失败。'
  curl --noproxy '*' -fsS --max-time 5 -H "Authorization: $XRAY_WS_AGENT_SECRET" \
    http://127.0.0.1:9011/health -o /dev/null || die 'VLESS WS Agent 最终验证失败。'
  ss -lnt | grep -q "127.0.0.1:$WS_PORT " || die 'VLESS WS 本地监听端口未就绪。'
  local realtime_listen
  realtime_listen="$(ss -H -lnt "( sport = :$REALITY_PORT )")" || die '无法检查 REALITY TCP 监听。'
  [[ -n "$realtime_listen" ]] || die 'REALITY TCP 监听失败。'
  verify_firewall_active || die '防火墙实际状态未通过核验（详见上面的 nftables 规则）。'
  local backup_found
  backup_found="$(find "$BACKUP_DIR" -maxdepth 1 -type f -name 'hysteria2-*.dump' -size +0c -print -quit)" || die '无法检查数据库备份目录。'
  [[ -n "$backup_found" ]] || die '没有有效数据库备份。'
}

run_stage packages     '安装系统依赖、Node.js 22 与 pnpm' stage_packages
run_stage swap         '低内存 VPS swap 检查' stage_swap
run_stage repository   'PostgreSQL / Redis / Git 项目初始化' stage_repository_db
run_stage config       '生成生产环境配置和密钥' stage_config
run_stage deps         '安装 pnpm 依赖与 Prisma 迁移' stage_dependencies
run_stage xray         '安装 Xray、生成 REALITY 密钥、启动 TCP 监听' stage_xray_core
run_stage xrayws       '部署 VLESS + WS 本地节点（127.0.0.1，不套 CF）' stage_xray_ws
run_stage bootstrap    '创建管理员、HY2 与 REALITY 节点（自动写库，不导入演示数据）' stage_bootstrap
run_stage build        '编译 API、Web 和 Worker' stage_build
run_stage apiweb       '配置 API/Web systemd 服务和内部端口防护' stage_web_api
run_stage https        'Nginx 反向代理与 Let’s Encrypt 证书' stage_https
run_stage node         '安装 Hysteria2 UDP 节点与本机统计 API' stage_node
run_stage xrayagent    '构建并启动 Xray Agent（Go 1.26+，REALITY :9010）' stage_xray_agent
run_stage xrayagentws  '启动 VLESS WS 专用 Agent 实例（:9011）' stage_xray_agent_ws
run_stage worker       '启动同步 Worker，等待节点真正就绪' stage_worker
run_stage backups      '每日数据库备份与证书续期钩子' stage_backups
run_stage firewall     '安全启用默认 DROP 防火墙（带自动回滚）' stage_firewall

log '进行最终验收。'
final_checks
printf '%s\n' "$(date -u +%FT%TZ)" > "$STATE_DIR/install-completed-at"
chmod 0600 "$STATE_DIR/install-completed-at"

# Print credentials ONLY to the interactive terminal; do not tee secrets into log.
# (/dev/tty 可能在极少数非标准终端环境下不可用，此时只提示凭据文件位置。)
CRED_TTY=/dev/tty
[[ -w $CRED_TTY ]] || CRED_TTY=/dev/null
{
  printf '\n=======================================================\n'
  printf '  cdql/hysteria2 · Ubuntu/Debian 三协议安装完成\n'
  printf '=======================================================\n'
  printf '后台地址：      https://%s/login\n' "$PANEL_DOMAIN"
  printf '管理员邮箱：    %s\n' "$ADMIN_EMAIL"
  printf '管理员密码：    %s\n' "$ADMIN_PASS"
  printf -- '-------------------------------------------------------\n'
  printf 'Hysteria2 节点：%s:%s/udp（已自动写入面板，直接可用）\n' "$HY2_DOMAIN" "$HY2_PORT"
  printf 'VLESS REALITY： %s:%s/tcp（已自动写入面板，直接可用）\n' "$REALITY_DOMAIN" "$REALITY_PORT"
  printf 'REALITY SNI：   %s\n' "$REALITY_SNI"
  printf 'REALITY 公钥：  %s\n' "$REALITY_PUBLIC_KEY"
  printf 'REALITY ShortID：%s\n' "$REALITY_SHORT_ID"
  printf -- '-------------------------------------------------------\n'
  printf 'VLESS + WS（待套 Cloudflare Tunnel，尚未写入面板）：\n'
  printf '  本地监听：    127.0.0.1:%s（明文 WS，仅本机）\n' "$WS_PORT"
  printf '  WS 路径：     %s\n' "$WS_PATH"
  printf '  采集地址：    http://127.0.0.1:9011\n'
  printf '  采集密钥：    %s\n' "$XRAY_WS_AGENT_SECRET"
  printf -- '-------------------------------------------------------\n'
  printf '后续人工步骤（VLESS + WS）：\n'
  printf '  1. 到 Cloudflare Zero Trust → Networks → Tunnels，新建 Tunnel，\n'
  printf '     Public Hostname 填你的域名，Service 填 http://127.0.0.1:%s\n' "$WS_PORT"
  printf '  2. 到面板 后台 → 节点管理 → 新增节点：\n'
  printf '       协议：VLESS + WS（CF Tunnel）\n'
  printf '       域名：你的 CF 隧道域名，端口：443\n'
  printf '       WS 路径：%s\n' "$WS_PATH"
  printf '       流量采集地址：http://127.0.0.1:9011\n'
  printf '       流量采集密钥：%s\n' "$XRAY_WS_AGENT_SECRET"
  printf '     保存后该节点即直接可用。\n'
  printf -- '-------------------------------------------------------\n'
  printf 'Worker：        hysteria2-worker (active)\n'
  printf '数据库备份：    %s / 每日 03:20 / 保留 14 天\n' "$BACKUP_DIR"
  printf 'SSH 允许：      TCP %s\n' "${SSH_PORTS[*]}"
  printf '网站允许：      TCP 80 / 443\n'
  printf 'REALITY 允许：  TCP %s\n' "$REALITY_PORT"
  printf 'HY2 允许：      UDP %s\n' "$HY2_PORT"
  printf '凭据文件：      %s（root 专用，转存后可删除）\n' "$CREDENTIALS_FILE"
  printf '安装状态：      %s\n' "$STATE_DIR"
  printf '=======================================================\n'
} > "$CRED_TTY"
[[ $CRED_TTY == /dev/null ]] && log "无交互终端，凭据未打印到屏幕，请查看：$CREDENTIALS_FILE"
