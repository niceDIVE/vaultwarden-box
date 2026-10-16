#!/usr/bin/env bash
# ============================================================================
# setup.sh —— 自建密码箱一键部署脚本（Ubuntu 24.04 LTS）
#
# 特点：可重复运行。每一步都先检查是否已完成，已完成就跳过，不会重复报错。
#
# 用法（在服务器上，root 或 sudo）：
#   sudo bash setup.sh
#
# 脚本会分阶段执行；最后一阶段"防火墙封锁公网"只有在检测到你是通过
# Tailscale 网络登录时才会执行，否则会提示你先装好 Tailscale 再重跑一次。
#
# 本脚本不包含任何密钥、密码、令牌；敏感内容全部在 .env 中填写。
# ============================================================================
set -euo pipefail

# ---------------- 固定配置（一般不需要改） ----------------
VW_VERSION="${VW_VERSION:-1.37.2}"          # Vaultwarden 固定版本号
VW_DIR="/opt/vaultwarden"                   # 部署目录
APP_PORT="${ROCKET_PORT:-8222}"             # 对内监听端口
APP_USER="vwadmin"                          # 日常登录服务器的管理员账号
BACKUP_DIR_DEFAULT="/var/backups/vaultwarden"  # 备份目录默认值（实际以 .env 中 BACKUP_DIR 为准，见阶段 5）
SRV_TZ="Asia/Shanghai"                      # 服务器时区（备份时间按此计算）
SSH_HARDEN_CONF="/etc/ssh/sshd_config.d/60-vw-hardening.conf"

# ---------------- 输出辅助 ----------------
c_g='\033[0;32m'; c_r='\033[0;31m'; c_y='\033[1;33m'; c_0='\033[0m'
ok()   { echo -e "${c_g}[完成]${c_0} $*"; }
info() { echo "        $*"; }
warn() { echo -e "${c_y}[注意]${c_0} $*"; }
fail() { echo -e "${c_r}[失败]${c_0} $*"; exit 1; }
banner() { echo; echo "================ $* ================"; }

# ---------------- 前置检查 ----------------
[ "$(id -u)" -eq 0 ] || fail "请用 root 或 sudo 运行：sudo bash setup.sh"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in docker-compose.yml .env.example backup.sh vw-backup.service vw-backup.timer; do
  [ -f "$SCRIPT_DIR/$f" ] || fail "当前目录缺少文件 $f —— 请把整个部署文件夹完整上传到服务器"
done

# ============================================================================
banner "阶段 1/10  系统基础：时区 + 基础软件包"
# ============================================================================
if [ "$(timedatectl show -p Timezone --value 2>/dev/null)" = "$SRV_TZ" ]; then
  ok "时区已是 $SRV_TZ（每日备份按北京时间凌晨 4 点执行）"
else
  timedatectl set-timezone "$SRV_TZ" && ok "时区已设为 $SRV_TZ（每日备份按北京时间凌晨 4 点执行）"
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update -y -qq
apt-get install -y -qq ca-certificates curl gnupg jq sqlite3 ufw rsync >/dev/null
ok "基础软件包就绪（curl / jq / sqlite3 / ufw / rsync）"

# age：Ubuntu 24.04 软件源里有；万一没有则从 GitHub 官方发布下载
if command -v age >/dev/null 2>&1; then
  ok "age 加密工具已安装：$(age --version 2>/dev/null || echo ok)"
else
  if apt-get install -y -qq age >/dev/null 2>&1 && command -v age >/dev/null 2>&1; then
    ok "age 加密工具已安装（apt）"
  else
    info "apt 源中没有 age，改从 GitHub 官方发布下载…"
    curl -fsSL https://github.com/FiloSottile/age/releases/download/v1.2.1/age-v1.2.1-linux-amd64.tar.gz \
      | tar xz -C /usr/local/bin --strip-components=1 age/age age/age-keygen
    ok "age 加密工具已安装（GitHub 官方二进制）"
  fi
fi

# ============================================================================
banner "阶段 2/10  安装 Docker（含 Compose 插件）"
# ============================================================================
if command -v docker >/dev/null 2>&1 && docker compose version >/dev/null 2>&1; then
  ok "Docker 与 Compose 插件已安装：$(docker --version | awk '{print $3}')"
else
  apt-get install -y -qq docker.io docker-compose-v2 >/dev/null
  systemctl enable --now docker >/dev/null 2>&1
  ok "Docker 安装完成：$(docker --version | awk '{print $3}')"
fi

# ============================================================================
banner "阶段 3/10  开启系统自动安全更新（unattended-upgrades）"
# ============================================================================
if ! command -v unattended-upgrade >/dev/null 2>&1; then
  apt-get install -y -qq unattended-upgrades >/dev/null
fi
printf 'APT::Periodic::Update-Package-Lists "1";\nAPT::Periodic::Unattended-Upgrade "1";\n' \
  > /etc/apt/apt.conf.d/20auto-upgrades
systemctl enable --now unattended-upgrades >/dev/null 2>&1 || true
ok "系统安全更新将自动安装（如何确认成功：cat /etc/apt/apt.conf.d/20auto-upgrades）"

# ============================================================================
banner "阶段 4/10  安装并登录 Tailscale"
# ============================================================================
if command -v tailscale >/dev/null 2>&1; then
  ok "Tailscale 已安装"
else
  info "正在安装 Tailscale（官方安装脚本）…"
  curl -fsSL https://tailscale.com/install.sh | sh
  ok "Tailscale 安装完成"
fi

if tailscale status >/dev/null 2>&1 && [ -n "$(tailscale ip -4 2>/dev/null | head -n1)" ]; then
  ok "Tailscale 已登录，本机 Tailscale 地址：$(tailscale ip -4 | head -n1)"
else
  echo
  warn "下面开始登录 Tailscale。屏幕会显示一个 https://login.tailscale.com/... 开头的链接："
  warn "  1) 把链接复制到任意电脑/手机的浏览器打开"
  warn "  2) 登录你的 Tailscale 账号（还没有账号就按页面提示用 Google/GitHub/微软账号注册）"
  warn "  3) 点 Authorize / Connect 授权，然后回到这里等待"
  echo
  tailscale up --hostname vaultwarden --accept-dns=false
  ok "Tailscale 登录成功，本机 Tailscale 地址：$(tailscale ip -4 | head -n1)"
fi

TS_FQDN="$(tailscale status --json | jq -r '.Self.DNSName | sub("\\.$";"")' 2>/dev/null || true)"
[ -n "$TS_FQDN" ] || TS_FQDN="$(hostname)"
info "本机 ts.net 域名：$TS_FQDN（下面会自动填入 DOMAIN）"

# ============================================================================
banner "阶段 5/10  部署 Vaultwarden 配置文件"
# ============================================================================
mkdir -p "$VW_DIR/data"

install -m 644 "$SCRIPT_DIR/docker-compose.yml" "$VW_DIR/docker-compose.yml"
install -m 700 "$SCRIPT_DIR/backup.sh"          "$VW_DIR/backup.sh"
install -m 644 "$SCRIPT_DIR/vw-backup.service"  /etc/systemd/system/vw-backup.service
install -m 644 "$SCRIPT_DIR/vw-backup.timer"    /etc/systemd/system/vw-backup.timer

# 备份目录以 .env 配置为准（.env 刚生成或已存在）
if [ -f "$VW_DIR/.env" ]; then
  # shellcheck disable=SC1091
  set -a
  # shellcheck disable=SC1091
  . "$VW_DIR/.env"
  set +a
fi
BACKUP_DIR="${BACKUP_DIR:-$BACKUP_DIR_DEFAULT}"
mkdir -p "$BACKUP_DIR"
chmod 700 "$BACKUP_DIR"

if [ -f "$VW_DIR/.env" ]; then
  ok ".env 已存在，不覆盖（如需重新配置请手动编辑 $VW_DIR/.env）"
else
  install -m 600 "$SCRIPT_DIR/.env.example" "$VW_DIR/.env"
  sed -i "s|^VW_VERSION=.*|VW_VERSION=$VW_VERSION|" "$VW_DIR/.env"
  ok "已生成 $VW_DIR/.env（模板复制而来，不含任何密钥）"
fi

# 自动把 ts.net 域名填进 DOMAIN（仅在仍是占位符时执行）
if grep -q '^DOMAIN=https://your-machine\.' "$VW_DIR/.env"; then
  sed -i "s|^DOMAIN=.*|DOMAIN=https://$TS_FQDN|" "$VW_DIR/.env"
  ok "DOMAIN 已自动填入：https://$TS_FQDN"
fi

# ============================================================================
banner "阶段 6/10  启动 Vaultwarden 容器"
# ============================================================================
cd "$VW_DIR"
info "拉取镜像 vaultwarden/server:$VW_VERSION …"
docker compose pull -q
docker compose up -d

i=0
until curl -fsS "http://127.0.0.1:${APP_PORT}/alive" >/dev/null 2>&1 || [ "$i" -ge 15 ]; do
  sleep 2
  i=$((i+1))
done
if curl -fsS "http://127.0.0.1:${APP_PORT}/alive" >/dev/null 2>&1; then
  ok "Vaultwarden 已启动并响应（本机地址 http://127.0.0.1:${APP_PORT}/alive）"
else
  warn "容器已启动但 /alive 暂未响应，稍等片刻后运行以下命令确认："
  warn "  curl http://127.0.0.1:${APP_PORT}/alive && docker ps"
fi

# ============================================================================
banner "阶段 7/10  配置 Tailscale HTTPS 反代（tailscale serve）"
# ============================================================================
if tailscale serve status 2>/dev/null | grep -q "https://"; then
  ok "tailscale serve 已配置过，跳过"
else
  # 注意：需要先在 Tailscale 管理后台开启 HTTPS 证书（见安装指南 2.6 节）
  if tailscale serve --bg --https=443 "http://127.0.0.1:${APP_PORT}" 2>/tmp/vw-serve.err; then
    ok "tailscale serve 配置完成（443 → 127.0.0.1:${APP_PORT}）"
  else
    warn "tailscale serve 执行失败，错误如下："; cat /tmp/vw-serve.err || true
    warn "最常见原因：尚未在 Tailscale 管理后台开启 HTTPS 证书功能。"
    warn "处理：打开 https://login.tailscale.com/admin/dns ，找到 HTTPS Certificates，点 Enable，"
    warn "      然后重新运行本脚本即可（会自动跳过已完成的部分）。见安装指南 2.6 节。"
  fi
fi
tailscale serve status || true

# 验证 HTTPS 是否真的通了（证书签发需要几秒到几十秒）
if [ -n "$TS_FQDN" ]; then
  info "正在验证 https://$TS_FQDN/alive （证书首次签发可能需要约 30 秒）…"
  i=0
  until curl -fsS "https://$TS_FQDN/alive" >/dev/null 2>&1 || [ "$i" -ge 12 ]; do
    sleep 5
    i=$((i+1))
  done
  if curl -fsS "https://$TS_FQDN/alive" >/dev/null 2>&1; then
    ok "HTTPS 验证通过：https://$TS_FQDN/alive —— 这就是你所有客户端要填的服务器地址"
  else
    warn "HTTPS 暂未验证通过。请确认 Tailscale 后台的 HTTPS Certificates 已开启后重跑本脚本。"
  fi
fi

# ============================================================================
banner "阶段 8/10  SSH 加固 + 创建管理员账号"
# ============================================================================
if id "$APP_USER" &>/dev/null; then
  ok "管理员账号 $APP_USER 已存在，跳过"
else
  useradd -m -s /bin/bash "$APP_USER"
  install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/$APP_USER/.ssh"
  touch "/home/$APP_USER/.ssh/authorized_keys"
  if [ -s /root/.ssh/authorized_keys ]; then
    # 沿用 root 现有的登录密钥
    cat /root/.ssh/authorized_keys > "/home/$APP_USER/.ssh/authorized_keys"
    ok "已把 root 的 SSH 公钥复制给 $APP_USER"
  else
    echo
    warn "root 还没有 SSH 公钥。请把你的【公钥】粘贴到下面（一行，以 ssh-ed25519 或 ssh-rsa 开头）。"
    warn "公钥是长得像 ssh-ed25519 AAAA.... 的一行文字，不是私钥！"
    read -r PUBKEY
    case "$PUBKEY" in
      ssh-*\ *) echo "$PUBKEY" > "/home/$APP_USER/.ssh/authorized_keys" ;;
      *) fail "看起来不是有效的 SSH 公钥，请重新运行本脚本" ;;
    esac
  fi
  chown "$APP_USER:$APP_USER" "/home/$APP_USER/.ssh/authorized_keys"
  chmod 600 "/home/$APP_USER/.ssh/authorized_keys"
  echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "/etc/sudoers.d/90-$APP_USER"
  chmod 440 "/etc/sudoers.d/90-$APP_USER"
  ok "管理员账号 $APP_USER 创建完成（已具备 sudo 权限，登录后直接可用）"
fi

# D1：备份目录组权限（vwadmin 直接 scp 下载备份用；backup.sh 每次运行也会补设）
if getent group "$APP_USER" >/dev/null 2>&1; then
  chown root:"$APP_USER" "$BACKUP_DIR"
  chmod 750 "$BACKUP_DIR"
fi

# 只在管理员账号确实装好了公钥之后，才收紧 SSH
if [ -s "/home/$APP_USER/.ssh/authorized_keys" ]; then
  cat > "$SSH_HARDEN_CONF" <<EOF
# 由 setup.sh 生成：只允许密钥登录，禁止 root 与密码登录
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  if sshd -t 2>/dev/null; then
    systemctl reload ssh
    ok "SSH 已加固：禁止 root 登录 / 禁止密码登录 / 仅密钥认证"
  else
    warn "sshd 配置校验未通过，已保留原配置。请运行 sshd -t 查看错误。"
  fi
else
  warn "管理员账号还没有 SSH 公钥，本阶段跳过 SSH 加固（避免把你锁在门外）。"
  warn "把公钥放入 /home/$APP_USER/.ssh/authorized_keys 后重跑本脚本即可。"
fi

# ============================================================================
banner "阶段 9/10  启用每日加密备份定时任务"
# ============================================================================
systemctl daemon-reload
systemctl enable --now vw-backup.timer >/dev/null 2>&1
ok "每日备份定时任务已启用（北京时间 04:00，系统时区 $SRV_TZ）"
info "查看下次执行时间：systemctl list-timers vw-backup.timer"

if grep -q '^AGE_PUBLIC_KEY=$' "$VW_DIR/.env" 2>/dev/null || ! grep -q '^AGE_PUBLIC_KEY=age1' "$VW_DIR/.env" 2>/dev/null; then
  warn "AGE_PUBLIC_KEY 还没有填！在此之前备份任务会失败（这是预期的保护）。"
  warn "请在 Windows 上生成 age 密钥对（安装指南第 3 节），把公钥填入 $VW_DIR/.env，"
  warn "然后手动试跑一次：sudo /opt/vaultwarden/backup.sh"
fi

# ============================================================================
banner "阶段 10/10  防火墙封锁公网（只在经 Tailscale 登录时执行）"
# ============================================================================
SRC_IP="${SSH_CLIENT:-}"; SRC_IP="${SRC_IP%% *}"
TS_IP="$(tailscale ip -4 2>/dev/null | head -n1)"

if [ -n "$SRC_IP" ] && [ "$SRC_IP" != "$TS_IP" ]; then
  warn "检测到你当前是【公网 IP】SSH 登录（来源 $SRC_IP）。"
  warn "为避免把自己锁在门外，本阶段已跳过。请按以下顺序操作后重跑本脚本："
  warn "  1) 在 Windows 上安装 Tailscale 并登录同一账号（安装指南第 2.7 节）"
  warn "  2) 用 Tailscale 地址重新 SSH 登录本服务器：ssh $APP_USER@$(tailscale ip -4 | head -n1)"
  warn "  3) 重新运行：sudo bash setup.sh"
else
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow in on tailscale0 comment 'Tailscale 全部放行'
  ufw allow 41641/udp comment 'Tailscale DERP'
  ufw --force enable
  ok "防火墙已开启：公网默认全部拒绝，仅放行 tailscale0 接口与 UDP 41641"
  echo
  ufw status verbose
  echo
  info "自查命令：sudo ufw status verbose   期望看到 Default deny (incoming)"
fi

# ============================================================================
banner "部署完成 —— 接下来你需要做的事"
# ============================================================================
cat <<EOF
已经自动完成：
  [x] Docker + 固定版本 Vaultwarden $VW_VERSION（仅本机 127.0.0.1 可访问）
  [x] Tailscale + HTTPS 反代：https://$TS_FQDN
  [x] SSH 加固（仅密钥、禁 root、禁密码）
  [x] 每日 04:00（北京时间）加密备份定时任务
  [x] 系统自动安全更新
  [x] 防火墙（如果上面显示已开启）

你还需要手动完成（全部步骤都在《安装指南.md》里）：
  1) 在 Windows 生成 age 密钥对，把【公钥】填入 $VW_DIR/.env 的 AGE_PUBLIC_KEY
  2) 手动试跑一次备份：sudo /opt/vaultwarden/backup.sh
  3) 浏览器打开 https://$TS_FQDN 注册你所有的身份账号
  4) 每个账号开启 TOTP 二步验证
  5) 所有账号注册完后，把 .env 中 SIGNUPS_ALLOWED 改为 false 并重启容器
  6) 配置异地备份服务器（可选但强烈推荐，安装指南第 10 节）
  7) 对照《加固自检清单.md》逐项验收

重要提醒：
  * 客户端（Windows/安卓）里填的服务器地址 = https://$TS_FQDN
  * 本脚本可以随时重跑：sudo bash setup.sh
EOF
