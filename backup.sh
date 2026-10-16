#!/usr/bin/env bash
# ============================================================================
# backup.sh —— 密码箱每日加密备份
#
# 由 systemd 定时器 vw-backup.timer 每天北京时间 04:00 自动调用，
# 也可以随时手动运行：sudo /opt/vaultwarden/backup.sh
#
# 流程：
#   1. sqlite3 .backup 在线安全导出数据库（不停服务、不锁库）+ 完整性校验
#   2. 连同 attachments、sends、rsa_key*、config.json、.env、compose 一起打包
#   3. 用 age 公钥加密（私钥在离线保存，服务器上没有，所以服务器被黑也读不了备份）
#   4. 清理超过保留期（默认 30 天）的本地旧备份
#   5. 如果 .env 配置了 OFFSITE_TARGET，用 rsync 同步到异地服务器（失败只提醒不中断）
#
# 日志：journalctl -u vw-backup.service  以及  /var/log/vw-backup.log
# ============================================================================
set -euo pipefail

VW_DIR="/opt/vaultwarden"
DATA_DIR="$VW_DIR/data"
ENV_FILE="$VW_DIR/.env"
LOG_FILE="/var/log/vw-backup.log"

log() { echo "[$(date '+%F %T')] $*" | tee -a "$LOG_FILE"; }
die() { log "[失败] $*"; exit 1; }

# ---------------- 读取配置 ----------------
[ -f "$ENV_FILE" ] || die "找不到配置文件 $ENV_FILE"
set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

DATA_DIR="${DATA_DIR:-$VW_DIR/data}"
BACKUP_DIR="${BACKUP_DIR:-/var/backups/vaultwarden}"
RETENTION_DAYS="${RETENTION_DAYS:-30}"
OFFSITE_TARGET="${OFFSITE_TARGET:-}"
OFFSITE_SSH_KEY="${OFFSITE_SSH_KEY:-/root/.ssh/vw_offsite}"

# ---------------- 前置检查 ----------------
exec 9>/run/vw-backup.lock
flock -n 9 || die "已有备份任务在运行，本次退出"

command -v sqlite3 >/dev/null || die "缺少 sqlite3"
command -v age     >/dev/null || die "缺少 age"
[ -n "${AGE_PUBLIC_KEY:-}" ] || die "AGE_PUBLIC_KEY 未设置。请编辑 $ENV_FILE 填入 age 公钥（安装指南第 3-4 节）"
case "$AGE_PUBLIC_KEY" in
  age1*) : ;;
  *) die "AGE_PUBLIC_KEY 不是有效的 age 公钥（应以 age1 开头）" ;;
esac
[ -f "$DATA_DIR/db.sqlite3" ] || die "找不到数据库 $DATA_DIR/db.sqlite3"

mkdir -p "$BACKUP_DIR"
# D1：备份目录组可读（包已 age 加密，组可读无风险；vwadmin 可直接 scp 下载）
if getent group vwadmin >/dev/null 2>&1; then
  chown root:vwadmin "$BACKUP_DIR"
  chmod 750 "$BACKUP_DIR"
else
  chmod 700 "$BACKUP_DIR"
  log "[注意] 不存在 vwadmin 组，备份目录保持 700（仅 root 可读）"
fi

STAMP="$(date +%Y%m%d-%H%M)"
TMP="$(mktemp -d /tmp/vw-backup.XXXXXX)"
trap 'rm -rf "$TMP"' EXIT
STAGE="$TMP/stage"
mkdir -p "$STAGE/attachments" "$STAGE/sends"

# ---------------- 1) 服务健康检查（只提醒，不中断） ----------------
if curl -fsS "http://127.0.0.1:${ROCKET_PORT:-8222}/alive" >/dev/null 2>&1; then
  log "服务健康检查：正常"
else
  log "[注意] Vaultwarden 的 /alive 没有响应，仍将继续备份现有数据"
fi

# ---------------- 2) 数据库在线安全导出 ----------------
sqlite3 "$DATA_DIR/db.sqlite3" ".backup '$STAGE/db.sqlite3'"
CHK="$(sqlite3 "$STAGE/db.sqlite3" 'PRAGMA integrity_check;')"
[ "$CHK" = "ok" ] || die "导出的数据库完整性校验失败：$CHK"
log "数据库导出完成，完整性校验通过"

# ---------------- 3) 汇集其余需要备份的内容 ----------------
for d in attachments sends; do
  if [ -d "$DATA_DIR/$d" ]; then
    cp -a "$DATA_DIR/$d/." "$STAGE/$d/" || die "复制 $d 失败（磁盘满或权限问题？）"
  fi
done
if compgen -G "$DATA_DIR/rsa_key*" >/dev/null; then
  cp -a "$DATA_DIR"/rsa_key* "$STAGE/" || die "复制 rsa_key 失败"
else
  log "[注意] 没有找到 rsa_key*：恢复后所有客户端需要重新登录（数据不受影响）"
fi
if [ -f "$DATA_DIR/config.json" ]; then cp -a "$DATA_DIR/config.json" "$STAGE/"; fi
cp -a "$ENV_FILE"               "$STAGE/env"
cp -a "$VW_DIR/docker-compose.yml" "$STAGE/docker-compose.yml"

# ---------------- 4) 打包 + age 公钥加密 ----------------
tar -C "$STAGE" -czf "$TMP/payload.tar.gz" .
OUT="$BACKUP_DIR/vw-backup-$STAMP.tar.gz.age"
age -R "$AGE_PUBLIC_KEY" -o "$OUT" "$TMP/payload.tar.gz"
if getent group vwadmin >/dev/null 2>&1; then
  chown root:vwadmin "$OUT"
  chmod 640 "$OUT"
  find "$BACKUP_DIR" -maxdepth 1 -name 'vw-backup-*.tar.gz.age' -exec chown root:vwadmin {} + -exec chmod 640 {} +
else
  chmod 600 "$OUT"
fi
log "已生成加密备份：$OUT（大小 $(du -h "$OUT" | cut -f1)）"

# 快速自检：必须是 age 加密格式（文件头 age-encryption.org/v1）
[ "$(head -c 21 "$OUT" 2>/dev/null)" = "age-encryption.org/v1" ] || die "异常：$OUT 不是 age 加密文件，请立即检查 age 配置"

# ---------------- 5) 清理过期备份 ----------------
find "$BACKUP_DIR" -maxdepth 1 -name 'vw-backup-*.tar.gz.age' -mtime +"$RETENTION_DAYS" \
  -print -delete | while IFS= read -r f; do log "清理过期备份：$f"; done

# ---------------- 6) 异地同步（可选） ----------------
if [ -n "$OFFSITE_TARGET" ]; then
  RSH="ssh"
  if [ -n "$OFFSITE_SSH_KEY" ]; then RSH="ssh -i \"$OFFSITE_SSH_KEY\""; fi
  if rsync -a -e "$RSH -o BatchMode=yes -o ConnectTimeout=15" \
       "$BACKUP_DIR/" "$OFFSITE_TARGET" 2>/dev/null; then
    log "异地同步完成：$OFFSITE_TARGET"
  else
    log "[注意] 异地同步失败（本地备份不受影响）。请检查异地服务器与 SSH 密钥配置。"
  fi
fi

log "本次备份全部完成"
