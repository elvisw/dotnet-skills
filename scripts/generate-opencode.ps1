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

function Get-Plugins {
    param([string]$PluginsDir)

    $plugins = @()
    Get-ChildItem "$PluginsDir/*/plugin.json" | ForEach-Object {
        $json = Get-Content $_.FullName -Raw | ConvertFrom-Json
        $pluginDir = Split-Path -Parent $_.FullName
        $plugins += [PSCustomObject]@{
            Name        = $json.name
            Dir         = $pluginDir
            SkillsDir   = if ($json.skills) { Join-Path $pluginDir (@($json.skills)[0]) } else { $null }
            Agents      = @(if ($json.agents) { $json.agents | ForEach-Object { Join-Path $pluginDir $_ } })
            McpServers  = $json.mcpServers
        }
    }
    return $plugins
}

function Export-Skills {
    param([array]$Plugins, [string]$OutputDir)

    $skillsDir = Join-Path $OutputDir "skills"
    if (Test-Path $skillsDir) {
        Remove-Item -Recurse -Force $skillsDir
    }

    $skillMap = @{}

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
            $warnings += "WARNING: Skill name '$name' has $($sources.Count) sources, adding prefixes"
            foreach ($src in $sources) {
                $srcDir = Split-Path -Parent $src | Split-Path -Parent | Split-Path -Parent
                $pluginJson = Get-Content (Join-Path $srcDir "plugin.json") -Raw | ConvertFrom-Json
                $shortName = $pluginJson.name -replace '^dotnet-', ''
                $destName2 = "$shortName-$name"
                $destPath = Join-Path $skillsDir $destName2
                New-Item -ItemType Directory -Path $destPath -Force | Out-Null
                Copy-Item $src (Join-Path $destPath "SKILL.md") -Force
                $content = Get-Content (Join-Path $destPath "SKILL.md") -Raw
                $content = $content -replace '(?m)^name: .*$', "name: $destName2"
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

    if (-not $lspJson.lspServers) { return @{} }

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
            if ($prop -in @('$schema', 'agent', 'mcp', 'lsp')) {
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

    $content = $sb.ToString()
    $content = $content -replace ',\r?\n(\s*)$', "`n`$1"
    $indent--
    $content += "}"
    Set-Content $ConfigFile $content -NoNewline
    Write-Host "  Written: $ConfigFile"
}

function Update-GitIgnore {
    param([string]$GitIgnorePath = ".gitignore")

    $entries = @(
        "# OpenCode generated files",
        ".opencode/*",
        "!.opencode/commands/",
        "!opencode.json"
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

function Invoke-ScriptMain {
    Write-Host "  Discovering plugins..."
    $plugins = Get-Plugins -PluginsDir $PluginsDir
    Write-Host "  Found $($plugins.Count) plugins"

    Export-Skills -Plugins $plugins -OutputDir $OutputDir

    Export-Agents -Plugins $plugins -OutputDir $OutputDir

    $mcpConfig = ConvertTo-OpenCodeMcp -Plugins $plugins
    Write-Host "  MCP servers: $($mcpConfig.Count)"

    $lspConfig = ConvertTo-OpenCodeLsp
    Write-Host "  LSP servers: $($lspConfig.Count)"

    foreach ($p in $plugins) {
        Write-Host "    $($p.Name) — skills: $($p.SkillsDir), agents: $($p.Agents.Count)"
    }

    Update-GitIgnore

    New-OpenCodeJson -McpConfig $mcpConfig -LspConfig $lspConfig -ConfigFile $ConfigFile
}

Invoke-ScriptMain
