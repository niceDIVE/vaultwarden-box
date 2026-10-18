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
SSH_HARDEN_CONF="/etc/ssh/sshd_config.d/01-vw-hardening.conf"

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
for f in docker-compose.yml .env.example backup.sh vw-backup-check.sh vw-backup.service vw-backup.timer; do
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

# age：Ubuntu 24.04 软件源（universe）自带；装不上就明确报错，不做无校验的下载
if ! command -v age >/dev/null 2>&1; then
  apt-get install -y -qq age >/dev/null 2>&1 || true
fi
if ! command -v age >/dev/null 2>&1; then
  fail "age 安装失败。请确认软件源 universe 已启用：sudo add-apt-repository universe，然后重跑本脚本"
fi
ok "age 加密工具已安装：$(age --version 2>/dev/null || echo ok)"

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

# 备份目录以 .env 配置为准（.env 刚生成或已存在）；只取 BACKUP_DIR，不导入整个 .env
if [ -f "$VW_DIR/.env" ]; then
  BACKUP_DIR="$(sed -n 's/^BACKUP_DIR=//p' "$VW_DIR/.env" 2>/dev/null | tail -n1)"
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

# DOMAIN 校准：占位符就自动填；已填但与期望不一致则黄字告警（不强行覆盖人为配置）
EXPECTED_DOMAIN="https://$TS_FQDN"
CUR_DOMAIN="$(sed -n 's/^DOMAIN=//p' "$VW_DIR/.env" 2>/dev/null | tail -n1)"
if [ -z "$CUR_DOMAIN" ] || grep -q '^DOMAIN=https://your-machine\.' "$VW_DIR/.env" 2>/dev/null; then
  sed -i "s|^DOMAIN=.*|DOMAIN=$EXPECTED_DOMAIN|" "$VW_DIR/.env"
  ok "DOMAIN 已填入：$EXPECTED_DOMAIN"
elif [ "$CUR_DOMAIN" != "$EXPECTED_DOMAIN" ]; then
  warn "DOMAIN 与当前 ts.net 域名不一致（客户端填的地址必须与它完全一致，否则 WebAuthn/附件会出错）："
  warn "  配置文件里：$CUR_DOMAIN"
  warn "  当前期望  ：$EXPECTED_DOMAIN"
  warn "确认要改就执行：sudo sed -i 's|^DOMAIN=.*|DOMAIN=$EXPECTED_DOMAIN|' $VW_DIR/.env && cd $VW_DIR && docker compose up -d"
else
  ok "DOMAIN 已是 $EXPECTED_DOMAIN"
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
SERVE_STATUS="$(tailscale serve status 2>/dev/null || true)"
if printf '%s' "$SERVE_STATUS" | grep -q "127.0.0.1:${APP_PORT}"; then
  ok "tailscale serve 已指向 127.0.0.1:${APP_PORT}，跳过"
elif printf '%s' "$SERVE_STATUS" | grep -q "127\.0\.0\.1:"; then
  warn "443 上已经有别的服务在代理，本脚本【不覆盖】它。当前配置："
  printf '%s\n' "$SERVE_STATUS"
  warn "这就是「一台机器别跑两套对外服务」的原因。若确认要用 443 给密码箱，先手动清理："
  warn "  sudo tailscale serve --https=443 off"
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
# --- 8.1 账号：独立判断 ---
if id "$APP_USER" &>/dev/null; then
  ok "管理员账号 $APP_USER 已存在"
else
  useradd -m -s /bin/bash "$APP_USER"
  ok "已创建管理员账号 $APP_USER"
fi
install -d -m 700 -o "$APP_USER" -g "$APP_USER" "/home/$APP_USER/.ssh"
AK="/home/$APP_USER/.ssh/authorized_keys"

# --- 8.2 公钥：独立判断。补齐失败只警告，不中断，避免"账号已建好但 sudoers 没写"的半成品状态 ---
touch "$AK"
if [ ! -s "$AK" ]; then
  if [ -s /root/.ssh/authorized_keys ]; then
    cat /root/.ssh/authorized_keys > "$AK"
    ok "已把 root 的 SSH 公钥复制给 $APP_USER"
  else
    echo
    warn "还没有可用的 SSH 公钥。请把你的【公钥】粘贴到下面（一行，以 ssh-ed25519 / ssh-rsa / ecdsa-sha2 开头）。"
    warn "公钥是长得像 ssh-ed25519 AAAA.... 的一行文字，不是私钥！"
    read -r PUBKEY || PUBKEY=""
    case "$PUBKEY" in
      ssh-*\ *|ecdsa-sha2-*\ *|sk-ssh-*\ *) echo "$PUBKEY" > "$AK"; ok "公钥已写入" ;;
      "") warn "未输入公钥，本次跳过写入（重跑本脚本可再试）" ;;
      *) warn "看起来不是有效的 SSH 公钥，本次跳过写入（不会中断其它步骤）" ;;
    esac
  fi
fi
chown "$APP_USER:$APP_USER" "$AK"
chmod 600 "$AK"

# --- 8.3 sudoers：无论账号是否早已存在，都必须确保在位 ---
SUDOERS="/etc/sudoers.d/90-$APP_USER"
if [ ! -f "$SUDOERS" ]; then
  echo "$APP_USER ALL=(ALL) NOPASSWD:ALL" > "$SUDOERS"
  chmod 440 "$SUDOERS"
  ok "已写入 sudo 权限（$SUDOERS）"
else
  ok "sudo 权限已存在（$SUDOERS）"
fi

# --- 8.4 D1：备份目录组权限（与账号步骤无关，独立执行）---
if getent group "$APP_USER" >/dev/null 2>&1; then
  chown root:"$APP_USER" "$BACKUP_DIR"
  chmod 750 "$BACKUP_DIR"
fi

# --- 8.5 加固：先双重确认（公钥在位 + sudo 真的可用），再收紧 ---
if [ ! -s "$AK" ]; then
  warn "管理员账号还没有 SSH 公钥，本阶段跳过 SSH 加固（避免把你锁在门外）。"
  warn "把公钥放入 $AK 后重跑本脚本即可。"
elif ! sudo -l -U "$APP_USER" 2>/dev/null | grep -q '(ALL)'; then
  warn "检测不到 $APP_USER 的 sudo 权限，本阶段跳过 SSH 加固（避免锁死）。"
  warn "请检查 $SUDOERS 后重跑本脚本。"
else
  cat > "$SSH_HARDEN_CONF" <<EOF
# 由 setup.sh 生成：只允许密钥登录，禁止 root 与密码登录
PermitRootLogin no
PasswordAuthentication no
KbdInteractiveAuthentication no
PubkeyAuthentication yes
EOF
  # 先校验实际生效值（sshd 只认第一次出现的值；云镜像的 50-cloud-init.conf 可能写允许密码，01- 前置保证我们排最前）
  sshd -T | grep -Ei 'passwordauthentication|kbdinteractiveauthentication|permitrootlogin'
  if [ "$(sshd -T | grep -i '^passwordauthentication' | awk '{print $2}')" != "no" ] ||
     [ "$(sshd -T | grep -i '^permitrootlogin' | awk '{print $2}')" != "no" ]; then
    warn "sshd 实际生效值与预期不符，不执行 reload。请检查 /etc/ssh/sshd_config.d/ 下的其他文件后重跑本脚本。"
  else
    sshd -t && systemctl reload ssh
    ok "SSH 已加固：禁止 root 登录 / 禁止密码登录 / 仅密钥认证（已用 sshd -T 核验实际生效值）"
  fi
fi

# ============================================================================
banner "阶段 9/10  启用每日加密备份定时任务"
# ============================================================================
install -m 644 "$SCRIPT_DIR/vw-backup-check.sh" /etc/profile.d/vw-backup-check.sh
ok "登录备份状态提醒已安装（/etc/profile.d/vw-backup-check.sh）"
systemctl daemon-reload
systemctl enable --now vw-backup.timer >/dev/null 2>&1
ok "每日备份定时任务已启用（北京时间 04:00，系统时区 $SRV_TZ）"
cat > /etc/logrotate.d/vw-backup <<'LREOF'
/var/log/vw-backup.log {
    weekly
    rotate 8
    compress
    missingok
    notifempty
}
LREOF
ok "备份日志轮转已配置（/etc/logrotate.d/vw-backup，weekly 保留 8 份）"
info "查看下次执行时间：systemctl list-timers vw-backup.timer"

if grep -q '^AGE_PUBLIC_KEY=$' "$VW_DIR/.env" 2>/dev/null || ! grep -q '^AGE_PUBLIC_KEY=age1' "$VW_DIR/.env" 2>/dev/null; then
  warn "AGE_PUBLIC_KEY 还没有填！在此之前备份任务会失败（这是预期的保护）。"
  warn "请在 Windows 上生成 age 密钥对（安装指南第 3 节），把公钥填入 $VW_DIR/.env，"
  warn "然后手动试跑一次：sudo /opt/vaultwarden/backup.sh"
fi

# ============================================================================
banner "阶段 10/10  防火墙封锁公网（只在经 Tailscale 登录时执行）"
# ============================================================================
# 判断来源 IP 是否属于 Tailscale 的 CGNAT 段 100.64.0.0/10。
is_tailscale_ip() {
  local ip="$1" second
  case "$ip" in
    100.*) ;;
    *) return 1 ;;
  esac
  second="${ip#100.}"; second="${second%%.*}"
  case "$second" in ''|*[!0-9]*) return 1 ;; esac
  if [ "$second" -ge 64 ] && [ "$second" -le 127 ]; then return 0; fi
  return 1
}

# 登录来源 IP：优先用 who -m（sudo 会清空 SSH_CLIENT，但 who -m 仍能给出当前会话来源）。
SRC_IP="$(who -m 2>/dev/null | awk '{print $NF}' | tr -d '()' | head -n1)"
[ -n "$SRC_IP" ] || SRC_IP="${SSH_CLIENT:-}"
SRC_IP="${SRC_IP%% *}"

if ! is_tailscale_ip "$SRC_IP"; then
  warn "无法确认你是经 Tailscale 登录（当前来源：${SRC_IP:-未知}）。"
  warn "为避免把自己锁在门外，本阶段【已跳过】——这是不冒险，不代表已经安全。"
  warn "请按以下顺序操作后重跑本脚本："
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
