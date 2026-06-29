---
description: 合并上游 dotnet/skills 更新，保持 OpenCode 支持设计
---

# 合并上游更新

你是这个 fork 仓库的维护者。你的任务是合并上游 `dotnet/skills` 的更新，
同时保持本地 OpenCode 支持的设计完整性。

## 设计原则（来自 docs/superpowers/specs/2026-05-29-opencode-support-design.md）

**零侵入上游**：`plugins/` 目录下所有文件不修改，冲突时一律接受上游版本。
**保留本地资产**：`docs/superpowers/`、`scripts/generate-opencode.ps1`、`.gitignore` 中的 opencode 规则不可丢失。

## 执行步骤

### Step 1: 获取上游最新代码

```bash
git fetch upstream
```

### Step 2: 检查是否有未提交的本地变更

```bash
git status --short
```

如果有未跟踪或未提交的文件，先暂存：

```bash
git add -A && git stash -m "pre-merge: sync-upstream"
```

### Step 3: 执行 merge（使用 merge，不用 rebase）

```bash
git merge upstream/main --no-commit --no-ff
```

### Step 4: 分析冲突

列出所有冲突文件：

```bash
git diff --name-only --diff-filter=U
```

冲突分为三类：

| 类型 | 策略 |
|------|------|
| `plugins/` 下的内容冲突 | `git checkout --theirs <file>` 接受上游 |
| `plugins/` 下的 modify/delete | `git add <file>` 接受上游（保留文件） |
| `tests/` 下的冲突 | `git checkout --theirs <file>` 接受上游（tests/ 非本地资产，与 plugins/ 同策略） |
| 本地独有文件（docs/superpowers/、scripts/、.gitignore） | 不应冲突，如有冲突保留本地版本 |

### Step 5: 逐个解决冲突

对每个冲突文件执行对应策略。解决后确认无剩余冲突：

```bash
git diff --name-only --diff-filter=U
```

### Step 6: 验证 generate-opencode.ps1

提交前运行脚本确保 OpenCode 转化功能正常。注意只删除生成物子目录，保留 `commands/`：

```bash
rm -rf .opencode/skills .opencode/agents
rm -f opencode.json
./scripts/generate-opencode.ps1
```

预期输出：15 个插件、~99 个技能、16 个代理，无技能名冲突。

验证命令文件未被误删：

```bash
ls .opencode/commands/sync-upstream.md >/dev/null 2>&1 && echo "OK" || echo "MISSING"
```

### Step 7: 恢复暂存的本地变更

如果 Step 2 执行了 stash，在提交前恢复：

```bash
git stash pop
```

如果 pop 有冲突，手动解决后 `git stash drop`。

### Step 8: 提交并推送

```bash
git commit -m "chore: merge upstream/main - resolve conflicts"
git push origin main
```

### Step 9: 输出摘要

报告合并结果：冲突数量、解决方式、脚本验证结果、新增/删除的技能或插件。
