# 由 setup.sh 安装到 /etc/profile.d/：登录时提醒备份状态（POSIX sh，被 source 执行）
# 只用 POSIX sh；任何情况下不报错、不阻塞登录。
__vw_state=/var/lib/vw-backup
__vw_now=$(date +%s 2>/dev/null) || __vw_now=0
if [ -r "$__vw_state/last-success" ]; then
    __vw_mtime=$(stat -c %Y "$__vw_state/last-success" 2>/dev/null) || __vw_mtime=0
    if [ "$__vw_now" -gt 0 ] && [ "$__vw_mtime" -gt 0 ] && [ $(( __vw_now - __vw_mtime )) -gt 93600 ]; then
        printf '\033[31m⚠ 超过 26 小时没有成功的备份，请运行 sudo /opt/vaultwarden/backup.sh 查看原因\033[0m\n'
    else
        __vw_when=$(head -n 1 "$__vw_state/last-success" 2>/dev/null)
        printf '\033[32m✓ 最近一次备份：%s\033[0m\n' "${__vw_when:-时间未知}"
    fi
else
    printf '\033[31m⚠ 超过 26 小时没有成功的备份，请运行 sudo /opt/vaultwarden/backup.sh 查看原因\033[0m\n'
fi
if [ -r "$__vw_state/offsite-failed" ]; then
    printf '\033[33m⚠ 上次异地同步失败：%s，见安装指南第 10 节\033[0m\n' "$(tr '\n' ' ' < "$__vw_state/offsite-failed" 2>/dev/null)"
fi
