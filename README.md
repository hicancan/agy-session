<p align="center">
  <img src="https://img.shields.io/badge/platform-Windows-0078D6?style=flat-square&logo=windows" alt="Windows">
  <img src="https://img.shields.io/badge/shell-PowerShell-5391FE?style=flat-square&logo=powershell" alt="PowerShell">
  <img src="https://img.shields.io/badge/license-MIT-green?style=flat-square" alt="MIT">
  <img src="https://img.shields.io/badge/dependencies-zero-brightgreen?style=flat-square" alt="Zero Dependencies">
</p>

<h1 align="center">agy-session</h1>
<p align="center"><strong>Zero-friction multi-account session switcher for Anti-Gravity CLI</strong></p>

---

## 这是什么 / What

agy 只支持单账号登录。多个 Google 账号来回切换，需要手动删除 `oauth_creds.json`、重新 OAuth 登录。

`agy-session` 把这个流程变成一行命令。每次运行自动保存当前 token，切换账号瞬间完成。

agy supports only a single login. Switching between Google accounts means manually deleting `oauth_creds.json` and re-authenticating via OAuth. `agy-session` reduces this to a single command — auto-saves your current session, switches instantly.

## 安装 / Install

```powershell
git clone https://github.com/hicancan/agy-session.git <your-path>
[Environment]::SetEnvironmentVariable("PATH", "$env:PATH;<your-path>", "User")
```

将 `<your-path>` 替换为你想存放的位置（如 `D:\tools\agy-session`），重启终端后 `agy-session` 全局可用。

## 使用 / Usage

```powershell
# 显示已保存账号，选择切换（紧凑模式）
agy-session

# 全量字段对比表（含完整 Google sub、token 过期时间）
agy-session list

# 按 email 切换
agy-session switch hicancan000@gmail.com

# 按 Google sub 前缀切换（全局搜索）
agy-session switch 112546691

# 模糊匹配 email
agy-session switch hican

# 保存当前 session 并删除凭证，准备登录新号
agy-session logout
```

### Switch 匹配策略 / Matching Strategy

| 输入 | 匹配逻辑 |
|------|---------|
| `email` | 精确匹配 email → 唯一则切换 |
| `<sub_prefix>` | 全局搜索 Google sub 前缀 → 唯一则切换 |
| `<fuzzy>` | 模糊匹配 email → 唯一则切换 |

## 原理 / How It Works

```
agy login (Google OAuth) → ~\.gemini\oauth_creds.json 生成
     ↓
agy-session  →  自动保存到 sessions\<email>\<google_sub>\oauth_creds.json
     ↓
agy-session switch xxx  →  覆盖 ~\.gemini\oauth_creds.json，完成切换
```

- **自动保存** — 每次运行都持久化当前 session
- **自动覆盖** — 同 email + 同 Google sub 自动覆盖，始终最新
- **google_accounts.json 同步** — 切换时自动更新 active 字段
- **自动清理** — logout 自动保存 + 删除，为登录新号准备

- **Auto-save** — persists current session on every invocation
- **Auto-overwrite** — same email + same Google sub sessions overwritten, always fresh
- **google_accounts.json sync** — updates active field on switch
- **Auto-cleanup** — logout saves + deletes, ready for new login

## 与 Codex 的对比 / vs Codex

| | Codex | Anti-Gravity (agy) |
|---|---|---|
| 凭证文件 | `~\.codex\auth.json` | `~\.gemini\oauth_creds.json` |
| 唯一标识 | `account_id` (UUID) | `sub` (Google 数字 ID) |
| 加密方式 | JWT (OpenAI) | JWT (Google OAuth2) |
| Token 刷新 | codex 自动管理 | refresh_token 自动续期 |
| 切换工具 | `codex-session` | `agy-session` |

## 安全 / Security

| 问题 | 答案 |
|---|---|
| token 会推到 GitHub 吗？ | 不会。`sessions/` 目录已在 `.gitignore` 中 |
| 其他人能看到我的 token 吗？ | 不能。所有 session 数据仅在本地 |

> **No.** `sessions/` is gitignored. Only the script itself is tracked. All tokens stay local.

## 文件结构 / Structure

```
agy-session/
├── .gitignore              # 忽略 sessions/（token 安全）
├── agy-session.cmd         # CMD 入口 → pwsh
├── agy-session.ps1         # 主脚本，纯 PowerShell，零依赖
└── sessions/               # 账号数据（gitignored）
    ├── <email>/
    │   └── <google_sub>/   # Google 账号唯一 sub
    │       └── oauth_creds.json
    ├── alice@gmail.com/
    │   └── 112546691283232964024/
    │       └── oauth_creds.json
    └── bob@gmail.com/
        └── 987654321098765432109/
            └── oauth_creds.json
```

## License

MIT
