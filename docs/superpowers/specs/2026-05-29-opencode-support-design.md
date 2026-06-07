# OpenCode Support Design

## 概述

为从 `dotnet/skills` fork 的仓库添加 OpenCode 平台支持，
使 14 个插件的 92 个技能和 16 个代理可在 OpenCode 中完整使用。

### 目标

- 完整插件兼容：所有技能和代理可在 OpenCode 中加载
- 零侵入上游：不修改 `plugins/` 目录下任何文件，上游更新后运行一次脚本即可
- 仅本地使用，无需分发

### 核心策略

一个 PowerShell 脚本 `scripts/generate-opencode.ps1` 从 `plugins/` 读取源文件，
生成 OpenCode 所需的所有文件。生成物全部加入 `.gitignore`。

---

## 生成脚本设计

### 输入

| 来源 | 内容 |
|---|---|
| `plugins/*/plugin.json` | 插件名称、技能路径、代理列表、MCP 服务器 |
| `plugins/*/skills/*/SKILL.md` | 技能定义（YAML frontmatter + Markdown） |
| `plugins/*/agents/*.agent.md` | 代理定义（YAML frontmatter + Markdown） |
| `plugins/dotnet/lsp.json` | LSP 服务器配置 |

### 输出（生成物，gitignore）

| 目标 | 内容 |
|---|---|
| `.opencode/skills/<name>/SKILL.md` | 复制并处理后的 SKILL.md |
| `opencode.json` | 代理定义、MCP/LSP 配置、权限 |

### 脚本流程

1. **解析插件清单**：扫描所有 `plugins/*/plugin.json`，收集插件元数据（名称、技能目录、代理文件、MCP 配置）
2. **收集技能列表**：遍历 `plugins/*/skills/*/SKILL.md`，建立 `{技能名 → [源路径列表]}` 映射，检测同名冲突
3. **生成技能文件**：
   - 无冲突 → 复制原文件到 `.opencode/skills/<name>/SKILL.md`
   - 有冲突 → 加插件前缀重命名目录，同时**更新 SKILL.md frontmatter 的 `name` 字段**
4. **生成代理 prompt**：遍历 `plugins/*/agents/*.agent.md`，解析 YAML frontmatter，剥离后写入 `opencode.json` 的 `agent` 段（用 `{file:...}` 引用去 frontmatter 的 prompt 文件）
5. **翻译 MCP 配置**：从 `plugin.json` 读取 `mcpServers`，翻译为 OpenCode 格式写入 `opencode.json`
6. **翻译 LSP 配置**：从 `plugins/dotnet/lsp.json` 读取，翻译为 OpenCode 格式
7. **合并输出**：生成或更新 `opencode.json`，保留用户手动添加的配置段
8. **更新 .gitignore**：确保生成物规则存在（去重追加）

### opencode.json 合并策略

**不删除已有文件**。脚本对 `opencode.json` 采用分段更新策略：

- 如果文件不存在 → 创建完整配置
- 如果文件存在 → 仅更新 `agent`、`mcp`、`lsp`、`permission.skill` 这四个段，保留其他用户自定义配置
- 生成的段用注释标记 `# BEGIN GENERATED` / `# END GENERATED`，方便识别

---

## 技能适配

### 设计

生成脚本将技能从分散的 `plugins/` 目录复制到 OpenCode 发现的扁平目录：

```
plugins/dotnet-msbuild/skills/build-parallelism/SKILL.md  →  .opencode/skills/build-parallelism/SKILL.md
plugins/dotnet-test/skills/run-tests/SKILL.md              →  .opencode/skills/run-tests/SKILL.md
```

### 同名冲突处理

脚本扫描所有技能目录名，检测重复。冲突处理：

1. 重命名目录：`<plugin-short-name>-<skill-name>`（short-name = plugin.json `name` 去掉 `dotnet-` 前缀后剩余部分）
2. **同步更新 SKILL.md frontmatter 的 `name` 字段**为新的技能名（OpenCode 要求 `name` 与目录名一致）
3. 无冲突时保持原名

### 技能名变更的连锁影响

冲突重命名会影响代理 prompt 正文中对技能名的引用（如 "use `binlog-failure-analysis` skill"）。
脚本生成阶段不处理此问题（需要理解自然语言），但冲突检测时输出警告提示人工审查。

预期：实际检查 `plugins/` 下 92 个技能目录名后，大概率无冲突（技能名设计时已有意识避免重复）。

---

## 代理适配

### 设计

生成脚本从 `.agent.md` 读取 frontmatter 元数据，产出到 `opencode.json` 的 `agent` 段。
prompt 内容通过 `{file:...}` 直接引用原文件（路径相对于项目根 `./plugins/...`）。

如果 OpenCode 的 `{file:...}` 会自动剥离 YAML frontmatter，则无需中间文件；
如果不会，则脚本需剥离 frontmatter 后单独存为 prompt 文件。此点待实施时验证。

### 字段映射

| 仓库 .agent.md 字段 | opencode.json 字段 | 说明 |
|---|---|---|
| `description` | `description` | 直接复用 |
| `user-invocable: true` 或缺失 | `mode: subagent` | 用户可 @ 调用。**缺失时默认视为 true** |
| `user-invocable: false` | `mode: subagent` + `hidden: true` | 隐藏，仅可通过 Task 工具被其他代理调用 |
| `disable-model-invocation: true` | 忽略 | OpenCode 无对应概念 |
| `handoffs` | 忽略，输出警告 | OpenCode 通过 Task 工具实现代理路由，语义不同 |
| `tools` | `permission` | 映射上游工具列表到 OpenCode permission（见下方映射表） |
| 无 `tools` 字段 | `permission` | 默认 `{ read: "allow" }` |

#### tools → permission 映射

| 上游 tools 值 | OpenCode permission |
|---|---|
| `read` | `read: "allow"` |
| `search` | `glob: "allow"`, `grep: "allow"`, `websearch: "allow"` |
| `edit` | `edit: "allow"` |
| `bash` | `bash: "allow"` |
| `task` | `task: "allow"` |
| `skill` | `skill: "allow"` |
| `web_search` | `websearch: "allow"` |
| `web_fetch` | `webfetch: "allow"` |
| `ask_user` | `question: "allow"` |

### handoffs 字段

部分代理定义 `handoffs` 指向其他代理，用于上游代理间路由。
OpenCode 代理间通过 Task 工具调用子代理，与此机制不同。
脚本在解析到 `handoffs` 时输出警告 `WARNING: handoffs field ignored for agent '<name>'`，不尝试转换。

---

## 其他配置

### MCP 服务器 — 格式翻译

`plugin.json` 的 `mcpServers` 与 `opencode.json` 的 `mcp` 格式不兼容，需翻译：

```
plugin.json (上游)                    opencode.json (目标)
─────────────────────────────────────────────────────────
"mcpServers": {                       "mcp": {
  "binlog": {                           "binlog": {
    "type": "stdio",        ──→           "type": "local",
    "command": "dotnet",    ──┐           "command": ["dotnet",
    "args": ["dnx", ...],   ──┘             "dnx", "Microsoft.AITools.BinlogMcp",
    "tools": ["*"]                        "--yes", "--prerelease", "--add-source",
  }                                       "https://..."],
}                                       "enabled": true
                                      }
                                    }
```

翻译规则：
- `type: "stdio"` → `"local"`
- `command` + `args` → 合并为 `command` 数组
- `tools: ["*"]` → 丢弃（OpenCode 用 permission 控制）
- 添加 `"enabled": true`

同名 MCP 服务器冲突：后发现的覆盖先发现的，输出警告。

### LSP 服务器 — 格式翻译

`lsp.json` 与 `opencode.json` 的 `lsp` 格式不兼容，需翻译：

```
lsp.json (上游)                        opencode.json (目标)
─────────────────────────────────────────────────────────
"lspServers": {                        "lsp": {
  "csharp": {                            "csharp": {
    "command": "dotnet",    ──┐            "command": ["dotnet",
    "args": ["dnx", ...],   ──┘              "dnx", "roslyn-language-server",
    "fileExtensions": {     ──→              "--yes", "--prerelease",
      ".cs": "csharp",                        "--", "--stdio",
      ".razor": "...",                        "--autoLoadProjects"],
      ".cshtml": "..."                   "extensions": [".cs", ".razor", ".cshtml"]
    }                                 }
  }                                 }
}                                 }
```

翻译规则：
- 顶层键 `lspServers` → `lsp`
- `command` + `args` → 合并为 `command` 数组
- `fileExtensions` 从对象 `{".cs": "csharp"}` 转为数组 `[".cs"]`，字段名改为 `extensions`
- `warmupTimeoutMs` → 丢弃（OpenCode LSP 不支持此字段）

### 权限

```jsonc
{
  "permission": {
    "skill": { "*": "allow" }
  }
}
```

---

## 上游合并策略

- `plugins/` 目录零修改 → `git merge upstream/main` 完全无冲突
- `scripts/` 目录在上游仓库中不存在，无冲突
- 上游新增/删除技能或代理 → 运行 `./scripts/generate-opencode.ps1` 即可
- 上游修改 MCP/LSP 配置 → 运行脚本即可同步

---

## 文件清单

### 新增（入仓库）

| 文件 | 说明 |
|---|---|
| `scripts/generate-opencode.ps1` | 生成脚本 |

### 修改（入仓库）

| 文件 | 说明 |
|---|---|
| `.gitignore` | 追加生成物忽略规则（去重） |

### 生成物（不入仓库，.gitignore 忽略）

| 文件 | 说明 |
|---|---|
| `opencode.json` | OpenCode 根配置 |
| `.opencode/skills/<name>/SKILL.md` | 技能文件（最大 92 个） |

### 不修改

| 文件 | 说明 |
|---|---|
| `plugins/**` | 全部上游文件 |

---

## 待验证事项

仅剩 1 项：

1. **OpenCode 的 `{file:...}` 是否自动剥离 YAML frontmatter** — 决定 agent prompt 是否需要单独剥离 frontmatter 后存文件。如自动剥离，可直接引用原 `.agent.md` 路径。

已确认：

- 技能名无冲突 ✓
- LSP `command` 数组格式正确 ✓，字段名为 `extensions`
- MCP `type: "local"` + `command` 数组格式正确 ✓
- LSP `command` 数组 + `extensions` 字段名正确 ✓
- Agent `hidden: true` 可用于 `user-invocable: false` 代理 ✓
- `warmupTimeoutMs` 不支持 ✓，丢弃
