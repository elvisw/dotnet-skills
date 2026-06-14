# OpenCode Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `scripts/generate-opencode.ps1` that reads `plugins/` and generates OpenCode-compatible config files (`opencode.json`, `.opencode/skills/`).

**Architecture:** Single PowerShell script with embedded Python for YAML frontmatter parsing. Scans `plugins/*/plugin.json` for plugin manifests, copies SKILL.md to `.opencode/skills/`, extracts agent frontmatter via Python, translates MCP/LSP configs, and merges into `opencode.json`.

**Tech Stack:** PowerShell 7+, Python 3 (with `yaml` module), JSON

---

## File Structure

| File | Responsibility |
|---|---|
| `scripts/generate-opencode.ps1` | Main generation script |
| `.gitignore` | Add `opencode.json` and `.opencode/` to ignore rules |
| `.opencode/skills/<name>/SKILL.md` | Generated — copied skill files |
| `opencode.json` | Generated — OpenCode config |

---

### Task 1: Create script scaffolding and Python dependency check

**Files:**
- Create: `scripts/generate-opencode.ps1`

- [ ] **Step 1: Create the script file with header and dependency check**

```powershell
#!/usr/bin/env pwsh
<#
.SYNOPSIS
  Generate OpenCode configuration from dotnet/skills plugins.
.DESCRIPTION
  Scans plugins/*/plugin.json, copies SKILL.md files to .opencode/skills/,
  translates agent definitions and MCP/LSP config to opencode.json.
#>
param(
    [string]$PluginsDir = "plugins",
    [string]$OutputDir = ".opencode",
    [string]$ConfigFile = "opencode.json"
)

$ErrorActionPreference = "Stop"
$rootDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $rootDir
Set-Location $rootDir

Write-Host "=== OpenCode Config Generator ==="

# Check Python with yaml module
$pythonCheck = python -c "import yaml; print('ok')" 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Error "Python 'yaml' module required. Install: pip install pyyaml"
    exit 1
}
Write-Host "  Python + yaml: OK"
```

- [ ] **Step 2: Run script to verify it passes dependency check**

```powershell
python -c "import yaml; print('ok')"
```

Expected: prints `ok`

- [ ] **Step 3: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add OpenCode config generator scaffolding"
```

---

### Task 2: Plugin discovery — parse plugin.json files

**Files:**
- Modify: `scripts/generate-opencode.ps1` — append after Step 1

- [ ] **Step 1: Add plugin discovery function**

Append to `scripts/generate-opencode.ps1`:

```powershell
function Get-Plugins {
    param([string]$PluginsDir)

    $plugins = @()
    Get-ChildItem "$PluginsDir/*/plugin.json" | ForEach-Object {
        $json = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $pluginDir = Split-Path -Parent $_.FullName
        $plugins += [PSCustomObject]@{
            Name        = $json.name
            Dir         = $pluginDir
            SkillsDir   = if ($json.skills) { Join-Path $pluginDir ($json.skills[0]) } else { $null }
            Agents      = @($json.agents | ForEach-Object { Join-Path $pluginDir $_ })
            McpServers  = $json.mcpServers
        }
    }
    return $plugins
}
```

- [ ] **Step 2: Add main entry point to invoke and display**

Append:

```powershell
function Invoke-ScriptMain {
    Write-Host "  Discovering plugins..."
    $plugins = Get-Plugins -PluginsDir $PluginsDir
    Write-Host "  Found $($plugins.Count) plugins"

    foreach ($p in $plugins) {
        Write-Host "    $($p.Name) — skills: $($p.SkillsDir), agents: $($p.Agents.Count)"
    }
}

Invoke-ScriptMain
```

- [ ] **Step 3: Run script to verify plugin discovery**

```powershell
./scripts/generate-opencode.ps1
```

Expected: lists 14 plugins with their agent counts.

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add plugin discovery from plugin.json files"
```

---

### Task 3: Skill processing — copy SKILL.md to .opencode/skills/

**Files:**
- Modify: `scripts/generate-opencode.ps1` — add Export-Skills function

- [ ] **Step 1: Add skill processing function**

Append to `scripts/generate-opencode.ps1` (before Invoke-ScriptMain):

```powershell
function Export-Skills {
    param([array]$Plugins, [string]$OutputDir)

    $skillsDir = Join-Path $OutputDir "skills"
    if (Test-Path $skillsDir) {
        Remove-Item -Recurse -Force $skillsDir
    }

    $skillMap = @{}  # name -> [source paths]

    foreach ($plugin in $Plugins) {
        if (-not $plugin.SkillsDir -or -not (Test-Path $plugin.SkillsDir)) { continue }
        Get-ChildItem "$($plugin.SkillsDir)/*/SKILL.md" | ForEach-Object {
            $skillName = Split-Path -Parent $_.FullName | Split-Path -Leaf
            if (-not $skillMap.ContainsKey($skillName)) {
                $skillMap[$skillName] = @()
            }
            $skillMap[$skillName] += $_.FullName
        }
    }

    $warnings = @()
    foreach ($name in $skillMap.Keys) {
        $sources = $skillMap[$name]
        $destName = $name
        if ($sources.Count -gt 1) {
            # Name conflict — add plugin prefix using short name
            $warnings += "WARNING: Skill name '$name' has ${sources.Count} sources, adding prefixes"
            foreach ($src in $sources) {
                $srcDir = Split-Path -Parent $src | Split-Path -Parent | Split-Path -Parent
                $pluginJson = Get-Content (Join-Path $srcDir "plugin.json") -Raw | ConvertFrom-Json
                $shortName = $pluginJson.name -replace '^dotnet-', ''
                $destName2 = "$shortName-$name"
                $destPath = Join-Path $skillsDir $destName2
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                Copy-Item $src (Join-Path $destPath "SKILL.md") -Force
                # Update frontmatter name field
                $content = Get-Content (Join-Path $destPath "SKILL.md") -Raw
                $content = $content -replace '^name: .*$', "name: $destName2"
                Set-Content (Join-Path $destPath "SKILL.md") $content -NoNewline
            }
        } else {
            $destPath = Join-Path $skillsDir $destName
            New-Item -ItemType Directory -Path $destPath -Force | Out-Null
            Copy-Item $sources[0] (Join-Path $destPath "SKILL.md") -Force
        }
    }

    Write-Host "  Skills exported: $($skillMap.Count) to $skillsDir"
    foreach ($w in $warnings) { Write-Host "  $w" }
}
```

- [ ] **Step 2: Call Export-Skills from Invoke-ScriptMain**

Insert after `Write-Host "  Found $($plugins.Count) plugins"`:

```powershell
    Export-Skills -Plugins $plugins -OutputDir $OutputDir
```

- [ ] **Step 3: Run script and verify skill output**

```powershell
./scripts/generate-opencode.ps1
Get-ChildItem .opencode/skills/ | Measure-Object | Select-Object -ExpandProperty Count
```

Expected: ~92 skill directories created, no `WARNING` about name conflicts (or at most 1-2).

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add skill export to .opencode/skills/"
```

---

### Task 4: Agent processing — parse frontmatter and generate config

**Files:**
- Modify: `scripts/generate-opencode.ps1` — add Export-Agents function

- [ ] **Step 1: Add Python YAML frontmatter parsing function**

Append before `Export-Agents`:

```powershell
function Get-Frontmatter {
    param([string]$FilePath)
    $raw = Get-Content $FilePath -Raw
    if ($raw -notmatch '(?s)^---\s*\n(.*?)\n---') {
        Write-Warning "No frontmatter found in $FilePath"
        return $null
    }
    $yamlText = $Matches[1]
    $result = python -c @"
import sys, yaml, json
text = sys.argv[1]
data = yaml.safe_load(text)
if data is None:
    data = {}
print(json.dumps(data))
"@ $yamlText 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "YAML parse failed for $FilePath`: $result"
        return $null
    }
    return $result | ConvertFrom-Json
}
```

- [ ] **Step 2: Add tools-to-permission mapping function**

Append:

```powershell
function ConvertTo-Permission {
    param([array]$Tools)
    if (-not $Tools) { return @{ read = "allow" } }

    $perm = @{}
    $map = @{
        read       = "read"
        search     = @("glob", "grep", "websearch")
        edit       = "edit"
        bash       = "bash"
        task       = "task"
        skill      = "skill"
        web_search = "websearch"
        web_fetch  = "webfetch"
        ask_user   = "question"
    }

    foreach ($tool in $Tools) {
        $tool = $tool.ToString().Trim()
        if ($map.ContainsKey($tool)) {
            $mapped = $map[$tool]
            if ($mapped -is [array]) {
                foreach ($m in $mapped) { $perm[$m] = "allow" }
            } else {
                $perm[$mapped] = "allow"
            }
        }
    }

    if ($perm.Count -eq 0) { $perm["read"] = "allow" }
    return $perm
}
```

- [ ] **Step 3: Add agent processing function**

Append:

```powershell
function Export-Agents {
    param([array]$Plugins, [string]$OutputDir)

    $agentsDir = Join-Path $OutputDir "agents"
    if (Test-Path $agentsDir) {
        Remove-Item -Recurse -Force $agentsDir
    }
    New-Item -ItemType Directory -Path $agentsDir -Force | Out-Null

    $count = 0
    $warnings = @()

    foreach ($plugin in $Plugins) {
        foreach ($agentPath in $plugin.Agents) {
            if (-not (Test-Path $agentPath)) {
                $warnings += "WARNING: Agent file not found: $agentPath"
                continue
            }

            $fm = Get-Frontmatter -FilePath $agentPath
            if (-not $fm) { continue }

            $agentName = $fm.name
            if (-not $agentName) {
                $agentName = [IO.Path]::GetFileNameWithoutExtension($agentPath)
            }

            $mode = "subagent"
            $hidden = $false
            $userInvokable = $fm.PSObject.Properties["user-invokable"] -or $fm.PSObject.Properties["user-invocable"]
            if ($userInvokable) {
                $val = if ($fm.PSObject.Properties["user-invokable"]) {
                    $fm."user-invokable"
                } else {
                    $fm."user-invocable"
                }
                if ($val -eq $false) { $hidden = $true }
            }

            if ($fm.PSObject.Properties["handoffs"]) {
                $warnings += "WARNING: handoffs field ignored for agent '$agentName' ($agentPath)"
            }

            $permission = ConvertTo-Permission -Tools $fm.tools
            $desc = ($fm.description -split '\n')[0]

            $rawContent = Get-Content $agentPath -Raw
            $bodyMatches = [regex]::Match($rawContent, '(?s)^---\s*\n.*?\n---\s*\n(.*)')
            $promptBody = if ($bodyMatches.Success) { $bodyMatches.Groups[1].Value.Trim() } else { $rawContent }

            $sb = [System.Text.StringBuilder]::new()
            $sb.AppendLine("---") | Out-Null
            $sb.AppendLine("description: $desc") | Out-Null
            $sb.AppendLine("mode: $mode") | Out-Null
            if ($hidden) { $sb.AppendLine("hidden: true") | Out-Null }
            $sb.AppendLine("permission:") | Out-Null
            foreach ($key in ($permission.Keys | Sort-Object)) {
                $sb.AppendLine("  $($key): $($permission[$key])") | Out-Null
            }
            $sb.AppendLine("---") | Out-Null
            $sb.AppendLine() | Out-Null
            $sb.AppendLine($promptBody) | Out-Null

            $agentFile = Join-Path $agentsDir "$agentName.md"
            Set-Content $agentFile $sb.ToString() -NoNewline
            $count++
        }
    }

    Write-Host "  Agents written: $count to $agentsDir"
    foreach ($w in $warnings) { Write-Host "  $w" }
}
```

**Design note:** Agents are written to `.opencode/agents/<name>.md` as standalone
markdown files with YAML frontmatter (description, mode, hidden, permission).
OpenCode discovers them from this directory — they are NOT embedded in `opencode.json`.

- [ ] **Step 4: Call Export-Agents from Invoke-ScriptMain**

Insert after `Export-Skills` call:

```powershell
    Export-Agents -Plugins $plugins -OutputDir $OutputDir
```

- [ ] **Step 5: Run script to verify agent parsing**

```powershell
./scripts/generate-opencode.ps1
Get-ChildItem .opencode/agents/ | Measure-Object | Select-Object -ExpandProperty Count
```

Expected: shows "Agents written: 16 to .opencode\\agents", 16 agent files created.

- [ ] **Step 6: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add agent frontmatter parsing and permission mapping"
```

---

### Task 5: MCP and LSP configuration translation

**Files:**
- Modify: `scripts/generate-opencode.ps1` — add translation functions

- [ ] **Step 1: Add MCP translation function**

Append:

```powershell
function ConvertTo-OpenCodeMcp {
    param([array]$Plugins)

    $mcp = @{}
    foreach ($plugin in $Plugins) {
        if (-not $plugin.McpServers) { continue }
        foreach ($key in $plugin.McpServers.PSObject.Properties.Name) {
            if ($mcp.ContainsKey($key)) {
                Write-Warning "MCP server name conflict: '$key' — overwriting"
            }
            $src = $plugin.McpServers.$key
            $command = @($src.command) + $src.args
            $mcp[$key] = @{
                type    = "local"
                command = $command
                enabled = $true
            }
        }
    }
    return $mcp
}

function ConvertTo-OpenCodeLsp {
    param([string]$LspJsonPath = "plugins/dotnet/lsp.json")

    if (-not (Test-Path $LspJsonPath)) { return @{} }

    $lspJson = Get-Content $LspJsonPath -Raw | ConvertFrom-Json
    $lsp = @{}

    foreach ($key in $lspJson.lspServers.PSObject.Properties.Name) {
        $src = $lspJson.lspServers.$key
        $command = @($src.command) + $src.args
        $extensions = @($src.fileExtensions.PSObject.Properties.Name)
        $lsp[$key] = @{
            command    = $command
            extensions = $extensions
        }
    }
    return $lsp
}
```

- [ ] **Step 2: Call translation functions from Invoke-ScriptMain**

Insert after agent parsing:

```powershell
    $mcpConfig = ConvertTo-OpenCodeMcp -Plugins $plugins
    Write-Host "  MCP servers: $($mcpConfig.Count)"

    $lspConfig = ConvertTo-OpenCodeLsp
    Write-Host "  LSP servers: $($lspConfig.Count)"
```

- [ ] **Step 3: Run script to verify MCP/LSP translation**

```powershell
./scripts/generate-opencode.ps1
```

Expected: "MCP servers: 1", "LSP servers: 1"

- [ ] **Step 4: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add MCP and LSP config translation"
```

---

### Task 6: opencode.json generation with merge strategy

**Note:** Agents are written to `.opencode/agents/<name>.md` markdown files by
`Export-Agents` (Task 4), NOT into `opencode.json`. This task generates only the
MCP and LSP configuration in `opencode.json`, plus preserves any user-added
custom sections on merge.

**Files:**
- Modify: `scripts/generate-opencode.ps1` — add New-OpenCodeJson function

- [ ] **Step 1: Add opencode.json generation function**

Append:

```powershell
function New-OpenCodeJson {
    param(
        [hashtable]$McpConfig,
        [hashtable]$LspConfig,
        [string]$ConfigFile
    )

    $newConfig = [ordered]@{}
    if (Test-Path $ConfigFile) {
        Write-Host "  Existing $ConfigFile found, merging..."
        $existing = Get-Content $ConfigFile -Raw | ConvertFrom-Json
        foreach ($prop in $existing.PSObject.Properties.Name) {
            if ($prop -in @('$schema', 'agent', 'mcp', 'lsp', 'permission')) {
            } else {
                $newConfig[$prop] = ConvertTo-HashtableDeep $existing.$prop
            }
        }
    }

    $sb = [System.Text.StringBuilder]::new()
    $indent = 0
    function Write-JsonLine($text) {
        $sb.AppendLine(('  ' * $indent) + $text) | Out-Null
    }

    Write-JsonLine '{'
    $indent++
    Write-JsonLine '"$schema": "https://opencode.ai/config.json",'
    Write-JsonLine ''

    if ($McpConfig.Count -gt 0) {
        Write-JsonLine '"mcp": {'
        $first = $true
        foreach ($key in ($McpConfig.Keys | Sort-Object)) {
            if (-not $first) { $sb.AppendLine(',') | Out-Null }
            $first = $false
            $mcpEntry = $McpConfig[$key] | ConvertTo-Json -Depth 5 -Compress
            Write-JsonLine "    `"$key`": $mcpEntry"
        }
        $sb.AppendLine() | Out-Null
        Write-JsonLine '},'
        Write-JsonLine ''
    }

    if ($LspConfig.Count -gt 0) {
        Write-JsonLine '"lsp": {'
        $first = $true
        foreach ($key in ($LspConfig.Keys | Sort-Object)) {
            if (-not $first) { $sb.AppendLine(',') | Out-Null }
            $first = $false
            $lspEntry = $LspConfig[$key] | ConvertTo-Json -Depth 5 -Compress
            Write-JsonLine "    `"$key`": $lspEntry"
        }
        $sb.AppendLine() | Out-Null
        Write-JsonLine '},'
        Write-JsonLine ''
    }

    foreach ($prop in $newConfig.Keys) {
        $val = ConvertTo-Json $newConfig[$prop] -Depth 10 -Compress
        Write-JsonLine "`"$prop`": $val,"
    }

    $content = $sb.ToString() -replace ',\s*$', ''
    $indent--
    $content += "`n}"
    Set-Content $ConfigFile $content -NoNewline
    Write-Host "  Written: $ConfigFile"
}

function ConvertTo-HashtableDeep {
    param($obj)
    if ($obj -is [System.Collections.IDictionary]) { return $obj }
    if ($null -eq $obj) { return $null }
    if ($obj -is [array]) { return @($obj | ForEach-Object { ConvertTo-HashtableDeep $_ }) }
    if ($obj -is [PSCustomObject]) {
        $hash = @{}
        foreach ($p in $obj.PSObject.Properties) {
            $hash[$p.Name] = ConvertTo-HashtableDeep $p.Value
        }
        return $hash
    }
    return $obj
}
```

- [ ] **Step 2: Call New-OpenCodeJson from Invoke-ScriptMain**

Insert at end of `Invoke-ScriptMain`:

```powershell
    New-OpenCodeJson -McpConfig $mcpConfig -LspConfig $lspConfig -ConfigFile $ConfigFile
```

- [ ] **Step 3: Run script and inspect generated opencode.json**

```powershell
./scripts/generate-opencode.ps1
python -c "import json; data=json.load(open('opencode.json')); print('MCP:', len(data.get('mcp',{}))); print('LSP:', len(data.get('lsp',{})))"
```

Expected: "MCP: 1", "LSP: 1"

- [ ] **Step 4: Verify agent markdown files exist**

```powershell
Get-ChildItem .opencode/agents/ | Measure-Object | Select-Object -ExpandProperty Count
```

Expected: 16 (agents are written to `.opencode/agents/<name>.md` by Task 4's `Export-Agents`)

- [ ] **Step 5: Commit**

```bash
git add scripts/generate-opencode.ps1
git commit -m "feat: add opencode.json generation with merge strategy"
```

---

### Task 7: .gitignore update

**Files:**
- Modify: `scripts/generate-opencode.ps1` — add Update-GitIgnore function
- Modify: `.gitignore` — append rule placeholder

- [ ] **Step 1: Add .gitignore update function**

Append:

```powershell
function Update-GitIgnore {
    param([string]$GitIgnorePath = ".gitignore")

    $entries = @(
        "# OpenCode generated files",
        "opencode.json",
        ".opencode/"
    )

    $existing = if (Test-Path $GitIgnorePath) {
        Get-Content $GitIgnorePath
    } else { @() }

    $toAdd = @()
    foreach ($entry in $entries) {
        if ($existing -notcontains $entry) {
            $toAdd += $entry
        }
    }

    if ($toAdd.Count -gt 0) {
        Add-Content $GitIgnorePath ""
        foreach ($entry in $toAdd) {
            Add-Content $GitIgnorePath $entry
        }
        Write-Host "  Updated .gitignore — added $($toAdd.Count) entries"
    } else {
        Write-Host "  .gitignore already up to date"
    }
}
```

- [ ] **Step 2: Call Update-GitIgnore from Invoke-ScriptMain**

Insert before `New-OpenCodeJson`:

```powershell
    Update-GitIgnore
```

- [ ] **Step 3: Run script twice to verify idempotent behavior**

```powershell
./scripts/generate-opencode.ps1
./scripts/generate-opencode.ps1
```

Expected: second run says ".gitignore already up to date"

- [ ] **Step 4: Verify .gitignore content**

```bash
git diff .gitignore
```

Expected: shows the 3 new lines at end of file.

- [ ] **Step 5: Commit**

```bash
git add scripts/generate-opencode.ps1 .gitignore
git commit -m "feat: add .gitignore update for OpenCode generated files"
```

---

### Task 8: Integration test — full script run

**Files:**
- No new files — verification task only

- [ ] **Step 1: Clean any previous output and run full script**

```powershell
Remove-Item -Recurse -Force .opencode -ErrorAction SilentlyContinue
Remove-Item opencode.json -ErrorAction SilentlyContinue
./scripts/generate-opencode.ps1
```

Expected output:
```
=== OpenCode Config Generator ===
  Python + yaml: OK
  Discovering plugins...
  Found 14 plugins
    dotnet — skills: ..., agents: 0
    ...
  Skills exported: 92 to .opencode\skills
  Agents written: 16 to .opencode\agents
  MCP servers: 1
  LSP servers: 1
  Updated .gitignore — added 3 entries
  Written: opencode.json
```

- [ ] **Step 2: Verify output structure**

```powershell
Test-Path opencode.json
Test-Path .opencode/skills
Get-ChildItem .opencode/skills/ | Measure-Object | Select-Object -ExpandProperty Count
```

Expected: `True`, `True`, `92`

- [ ] **Step 3: Verify opencode.json is valid JSON with MCP and LSP**

```powershell
python -c "
import json
data = json.load(open('opencode.json'))
assert '\$schema' in data
assert 'binlog' in data['mcp']
assert data['mcp']['binlog']['type'] == 'local'
assert data['mcp']['binlog']['enabled'] == True
assert 'csharp' in data['lsp']
assert 'extensions' in data['lsp']['csharp']
print('All assertions passed')
"
```

Expected: `All assertions passed`

- [ ] **Step 3b: Verify agent markdown files**

```powershell
$count = Get-ChildItem .opencode/agents/*.md | Measure-Object | Select-Object -ExpandProperty Count
Write-Host "Agent files: $count"
# spot-check one agent
$msbuild = Get-Content .opencode/agents/msbuild.md -Raw
$msbuild -match '^---\s*\ndescription:'
$msbuild -match 'mode: subagent'
```

Expected: 16 agent files, msbuild.md has valid frontmatter.

- [ ] **Step 4: Verify a skill file is valid and has correct frontmatter**

```powershell
$firstSkill = Get-ChildItem .opencode/skills/*/SKILL.md | Select-Object -First 1
$content = Get-Content $firstSkill.FullName -Raw
$content -match '^---\s*\nname: '
```

Expected: `True`

- [ ] **Step 5: Run script again to verify idempotency**

```powershell
./scripts/generate-opencode.ps1
```

Expected: all same counts, no errors.
```
