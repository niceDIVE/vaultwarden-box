# restore.md —— 密码箱灾难恢复手册

> 使用时机：服务器数据被误删、服务器报废需要换新机器、或者你想做一次恢复演练（强烈建议至少演练一次）。
>
> 阅读前提：你手里有下面"三样东西"。缺任何一样都无法恢复，请现在就检查。

---

## 〇、恢复前必须有的三样东西

| # | 东西 | 在哪里 | 什么样的 |
|---|------|--------|----------|
| 1 | **age 私钥文件** | 你离线保存的地方（U 盘 / 打印件 / 本机安全目录） | 一个文本文件，内容是 `AGE-SECRET-KEY-` 开头的一行 |
| 2 | **最新的加密备份包** | 异地备份服务器上，或你 Windows 电脑上手动复制的副本 | 文件名形如 `vw-backup-20250101-0402.tar.gz.age` |
| 3 | **一台能 SSH 的电脑** | 你的 Windows | 装有 PowerShell（系统自带） |

> ⚠️ 备份包本身是加密的，没有私钥谁也打不开——这正是我们要的效果。
> ⚠️ 如果你想不起私钥放在哪，**现在立刻去找并确认**，这是整套备份里最关键的一件东西。

---

## 一、在 Windows 上解密备份包

> 说明：解密在你自己的 Windows 上做，因为私钥在你手里。传输环节走 SSH（全程加密传输），恢复完成后删除明文临时文件即可。

1. 把加密备份包拷到你的 Windows，例如放到 `C:\Tools\age\` 目录下（和 `age.exe` 同一个文件夹）。
2. 打开 **PowerShell**（开始菜单 → 输入 PowerShell → 回车），逐条输入：

```powershell
# 进入工具目录（假设你的 age.exe、私钥、备份包都在这里）
cd C:\Tools\age

# 解密：-i 指定私钥文件，最后是加密备份包的文件名（改成你实际的文件名）
.\age.exe -d -i key.txt -o vw-backup.tar.gz vw-backup-20250101-0402.tar.gz.age
```

3. **确认成功的标志**：目录里出现 `vw-backup.tar.gz`，且命令没有报错。
4. （可选）看一眼包里有什么：`tar -tzf vw-backup.tar.gz`（Windows 10/11 自带 tar）
   应该能看到 `db.sqlite3`、`attachments/`、`sends/`、`rsa_key*`、`config.json`、`env`、`docker-compose.yml`。

---

## 二、恢复到服务器

分两种情况，从对应的小节开始做即可。

### 情况 A：服务器还在，只是数据没了 / 想回滚数据

前提：这台服务器上的 Vaultwarden 目录还在（`/opt/vaultwarden`），Tailscale 还能用。

1. **上传解密后的备份包**。在 Windows PowerShell 里执行（IP 换成你服务器的 Tailscale IP 或 ts.net 域名）：

```powershell
scp C:\Tools\age\vw-backup.tar.gz vwadmin@<服务器Tailscale地址>:/tmp/
```

2. **SSH 登录服务器**（此时应通过 Tailscale 登录，用户名是 `vwadmin`）：

```powershell
ssh vwadmin@<服务器Tailscale地址>
```

3. 在服务器上执行以下命令（逐条粘贴，每条回车）：
```bash
# 暂停定时备份，避免恢复过程中触发一次坏备份
sudo systemctl stop vw-backup.timer

# 先验证备份包完好（不显示"包完好"就停止，不要继续往下做）
sudo tar -tzf /tmp/vw-backup.tar.gz >/dev/null && echo 包完好

# 停掉容器
cd /opt/vaultwarden && sudo docker compose down

# 旧数据先改名保留（不要删！恢复失败靠它回到原状）
sudo mv /opt/vaultwarden/data /opt/vaultwarden/data.old-$(date +%F)
sudo mkdir -p /opt/vaultwarden/data

# 解开备份包，覆盖到数据目录
sudo tar -xzf /tmp/vw-backup.tar.gz -C /opt/vaultwarden/data

# 把包里的配置文件放回原位（包里的 env 就是 .env，docker-compose.yml 同理）
sudo mv /opt/vaultwarden/data/env /opt/vaultwarden/.env
sudo mv /opt/vaultwarden/data/docker-compose.yml /opt/vaultwarden/docker-compose.yml
sudo chmod 600 /opt/vaultwarden/.env

# 重新启动容器
cd /opt/vaultwarden && sudo docker compose up -d

# 等 10 秒，确认服务活着（输出 OK 即成功）
sleep 10 && curl http://127.0.0.1:8222/alive
```
4. **清理明文临时文件**（重要！明文数据库不能留在服务器上）：

```bash
rm -f /tmp/vw-backup.tar.gz
```

5. 跳到本文【三、逐项验收】。

> **恢复失败怎么回到原状**：`cd /opt/vaultwarden && sudo docker compose down` → 删除新解压出来的 data → 把 `data.old-日期` 改回 `data` → `sudo docker compose up -d`。
> **第三节验收全部通过后**，再清理并恢复定时任务：`sudo rm -rf /opt/vaultwarden/data.old-*` 和 `sudo systemctl start vw-backup.timer`。

### 情况 B：全新服务器（原服务器报废）

1. **先把新服务器部署到"可用"状态**：按《安装指南.md》第 1～2 节完成：
   - 开通 Ubuntu 24.04 VPS、首次 SSH 登录
   - 上传部署文件夹、运行 `sudo bash setup.sh`（会自动装好 Docker、Tailscale、备份定时任务等）
   - 此时 Tailscale 会给新服务器分配域名，**记下它**（用 `tailscale ip -4` 和 `tailscale status` 查看）

2. **按【情况 A】的第 1～4 步完成上传、解压、还原、启动**。
   注意：解压会把备份包里的旧 `.env` 覆盖到新服务器上——这正是想要的，
   因为旧 `.env` 里保存着你的 age 公钥和账号策略。但旧 `.env` 里的 `DOMAIN`
   指向旧服务器的域名，所以下一步要修正它。

3. **修正域名**：新服务器的 ts.net 域名可能与旧服务器不同，如果不同，改回来：

   ```bash
   sudo nano /opt/vaultwarden/.env
   # 找到 DOMAIN=... 一行，改成新服务器的完整 ts.net 地址（https:// 开头）
   # 保存：Ctrl+O 回车，退出：Ctrl+X
   sudo docker compose -f /opt/vaultwarden/docker-compose.yml --project-directory /opt/vaultwarden up -d
   ```

   查看新服务器域名的命令：`tailscale status`（Self 一行里 `vaultwarden.xxx.ts.net` 就是）。

4. 如果客户端（Windows/安卓）里的服务器地址变了，也要改成新地址。

---

## 三、逐项验收（恢复是否成功的标准）

| # | 检查 | 怎么做 | 成功标志 |
|---|------|--------|----------|
| 1 | 服务活着 | `curl http://127.0.0.1:8222/alive` | 输出 `OK` |
| 2 | HTTPS 通 | 浏览器打开 `https://<你的ts.net域名>` | 出现 Bitwarden/Vaultwarden 登录页 |
| 3 | 数据回来了 | 用旧账号+主密码登录 | 登录成功，密码条目和原来一致 |
| 4 | 附件回来了 | 打开原来带附件的条目 | 附件能下载 |
| 5 | 双账号都在 | 切换到第二个身份账号登录 | 也能登录，数据独立可见 |
| 6 | 注册已关闭 | 打开 `https://<域名>/#/register`（注册页） | 提示不可注册（SIGNUPS_ALLOWED=false 生效） |
| 7 | 备份任务正常 | `sudo systemctl list-timers vw-backup.timer` | 显示明天 04:00 将触发 |
| 8 | 手动备份能跑 | `sudo /opt/vaultwarden/backup.sh` | 提示"已生成加密备份"且"本次备份全部完成" |

第 8 项跑完后，在 Windows 上用你的 age 私钥试解一次**新备份包**：

```powershell
.\age.exe -d -i key.txt -o test.tar.gz <新备份包文件名>.age
```

解密成功 = 整个"备份 → 恢复"闭环验证通过。验证完删除 `test.tar.gz`。

---

## 四、收尾清理

- Windows 上 `C:\Tools\age\vw-backup.tar.gz`（明文）→ 删除。
- 服务器上 `/tmp/vw-backup.tar.gz` → 已在步骤中删除；不放心可再 `ls /tmp/` 确认。
- age 私钥文件放回离线保存处，**不要**留在下载文件夹、桌面、网盘同步目录。

## 五、常见问题

- **`age: error: decryption failed`** → 私钥文件不对（可能拿了公钥或别的密钥）。检查 `key.txt` 第一行是否以 `AGE-SECRET-KEY-` 开头。
- **`scp` 提示 permission denied** → 确认用户名是 `vwadmin` 且你在用 Tailscale 地址连接（公网 22 已被防火墙封锁，这是故意的）。
- **登录页能开但密码错误** → 主密码不随服务器存储/恢复，它在你脑子里。主密码丢了且没有客户端还登录着，数据无法找回——所以主密码请用密码箱自己存一份纸质副本在保险处。
- **恢复后 HTTPS 打不开** → 新服务器域名变了导致 DOMAIN 不对，按【情况 B】第 2 步改 `.env` 后 `sudo docker compose up -d`。
