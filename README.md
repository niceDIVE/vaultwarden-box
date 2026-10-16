# vaultwarden-box

自建密码箱（个人密码管理器）的完整部署与运维包：Ubuntu 24.04 VPS + Docker Compose 部署 Vaultwarden（固定版本），全设备经 Tailscale 内网访问，age 公钥加密每日备份。

> **给人类/AI 审查者的说明**：本仓库欢迎复审。请先读完本 README 和下方"硬性约束"再提 PR，避免提出与威胁模型冲突的"改进"。

## 架构（不要更改）

```
[Windows]──┐
           ├──(Tailscale 加密隧道)──► [Ubuntu 24.04 VPS]
[Android]──┘                            ├─ Vaultwarden 1.37.2（Docker，仅绑定 127.0.0.1:8222）
                                        ├─ tailscale serve 反代（*.ts.net HTTPS 443）
                                        ├─ ufw：默认拒绝，仅放行 tailscale0 + UDP 41641
                                        ├─ SSH：仅密钥 / 禁 root / 禁密码 / 仅限 Tailscale 访问
                                        └─ 每日 04:00（Asia/Shanghai）：sqlite3 .backup → tar → age 加密
                                                                     → 保留 30 天 → rsync 到异地服务器
```

- 威胁模型：公网扫描器、爬虫、自动化爆破。便利性优先于极致安全，不针对国家级攻击者。
- 使用者是非程序员，所有文档（`安装指南.md`、`restore.md`、`加固自检清单.md`）都要求"每步写明在哪操作、输入什么、如何确认成功"。

## 文件清单

| 文件 | 用途 |
|---|---|
| `docker-compose.yml` | Vaultwarden 服务定义（版本经 `.env` 的 `VW_VERSION` 固定） |
| `.env.example` | 配置模板（不含任何真实密钥；部署时复制为 `.env`） |
| `setup.sh` | 从全新 VPS 到可用的一键部署脚本，幂等可重复运行 |
| `backup.sh` | 每日加密备份（由 `vw-backup.timer` 触发，也可手动运行） |
| `vw-backup.service` / `vw-backup.timer` | systemd 备份定时任务（北京时间 04:00） |
| `restore.md` | 灾难恢复手册 |
| `安装指南.md` | VPS / Windows / Android 三端保姆级安装指南 |
| `加固自检清单.md` | 30+ 项安全自检（含验收标准核对） |

## 硬性约束（PR 若违反将被拒绝）

1. **不引入任何自研加密或认证逻辑**——加密依赖 age，认证依赖 Vaultwarden/Tailscale 本身。
2. **任何密钥、密码、令牌不得写入代码或提交到 Git**（`.env`、age 私钥、备份包均已被 `.gitignore` 排除）。
3. **不得开放任何公网应用端口**；不得把 Vaultwarden 暴露到 0.0.0.0 或公网。
4. 镜像版本必须固定具体版本号，禁止 `latest`。
5. 脚本必须保持幂等：`setup.sh` 重复运行不能出错、不能产生破坏性副作用。
6. 文档改动需保持"面向非程序员"的粒度：位置 + 输入 + 成功标志。

## 审查 / 改进工作流

1. 通过 Issue 提出问题或改进建议；通过 PR 提交改动。
2. shell 脚本改动必须通过：`bash -n <script>` 与 `shellcheck -S info <script>`（当前基准：两者零告警）。
3. 安全相关改动请说明对威胁模型的影响。
4. 仓库统一 LF 换行（见 `.gitattributes`），请勿提交 CRLF 文件。

## 当前已知设计决定（视为特性，勿当缺陷上报）

- 防火墙封锁仅在检测到操作者经 Tailscale 登录时执行（防自锁）。
- 管理后台完全关闭（`ADMIN_TOKEN` 留空），不用 argon2 方案。
- 异地备份是 rsync-over-SSH 到用户自备的第二台服务器（`.env` 中 `OFFSITE_TARGET` 留空即停用）。
- 备份私钥永不落服务器；服务器只持有 age 公钥。
- 客户端不启用 Bitwarden 推送通知，依赖打开/刷新时同步。
