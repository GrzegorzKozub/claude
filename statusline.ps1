#!/usr/bin/env pwsh
$ErrorActionPreference = 'SilentlyContinue'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$e  = [char]27
$pl = [char]0xE0B6
$pr = [char]0xE0B4

$json = [Console]::In.ReadToEnd()
$data = $json | ConvertFrom-Json

$DIR        = [string]$data.workspace.current_dir
$MODEL      = (([string]$data.model.display_name) -replace ' ?\([^)]*\)', '').ToLower()
$u          = $data.context_window.current_usage
$USED       = [string]$data.context_window.used_percentage
$MAX        = [string]$data.context_window.context_window_size
$CUR_IN_VAL = [long]$u.input_tokens + [long]$u.cache_creation_input_tokens + [long]$u.cache_read_input_tokens
$CUR_IN     = if ($CUR_IN_VAL -gt 0) { "$CUR_IN_VAL" } else { '' }
$EFFORT     = [string]$data.effort.level
$VIM_MODE   = [string]$data.vim.mode
$SESSION_ID = if ($data.session_id) { [string]$data.session_id } else { 'default' }
$AGENT      = [string]$data.agent.name
$WORKTREE   = [string]$data.workspace.git_worktree

$CACHE_FILE    = "$env:TEMP\statusline-git-cache-$SESSION_ID"
$CACHE_MAX_AGE = 5
$COMPACT_HINT_TOKENS = if ($env:STATUSLINE_COMPACT_HINT_TOKENS -match '^\d+$') { [long]$env:STATUSLINE_COMPACT_HINT_TOKENS } else { 250000 }

$CTX_ICONS = @('󰪞','󰪟','󰪠','󰪡','󰪢','󰪣','󰪤','󰪥')

function Test-CacheStale {
    if (-not (Test-Path $CACHE_FILE)) { return $true }
    $age = ([DateTimeOffset]::UtcNow - [DateTimeOffset](Get-Item $CACHE_FILE).LastWriteTimeUtc).TotalSeconds
    return $age -gt $CACHE_MAX_AGE
}

function Format-Tokens([long]$n) {
    if ($n -ge 1000000) { return "$([int](($n + 500000) / 1000000))M" }
    if ($n -ge 1000)    { return "$([int](($n + 500) / 1000))k" }
    return "$n"
}

function Format-Remaining($at) {
    if ($null -eq $at -or "$at" -eq '') { return '' }
    $target = if ("$at" -match '^\d+$') {
        [DateTimeOffset]::FromUnixTimeSeconds([long]"$at")
    } else {
        try { [DateTimeOffset]::Parse("$at") } catch { return '' }
    }
    $secs = [long][Math]::Max(0, ($target - [DateTimeOffset]::UtcNow).TotalSeconds)
    $d = [int][Math]::Floor($secs / 86400)
    $h = [int][Math]::Floor(($secs % 86400) / 3600)
    $m = [int][Math]::Floor(($secs % 3600) / 60)
    if ($d -gt 0) { return "${d}d ${h}h" }
    if ($h -gt 0) { return "${h}h ${m}m" }
    return "${m}m"
}

function Get-CtxIcon([double]$pct) {
    $idx = [int]($pct * 8 / 100)
    if ($idx -gt 7) { $idx = 7 }
    if ($idx -lt 0) { $idx = 0 }
    return $CTX_ICONS[$idx]
}

if ($DIR -and (Test-CacheStale)) {
    $TAG    = git -C "$DIR" describe --exact-match --tags HEAD 2>$null
    $BEHIND = 0; $AHEAD = 0; $CONFLICTED = 0; $STAGED = 0; $UNSTAGED = 0; $UNTRACKED = 0
    $BRANCH = ''

    # Single call replaces: symbolic-ref + rev-list + status --porcelain
    $porcelain = git -C "$DIR" status --porcelain=v2 --branch 2>$null
    foreach ($line in $porcelain) {
        switch -Regex ($line) {
            '^# branch\.head (.+)'          { $BRANCH = $Matches[1]; break }
            '^# branch\.ab \+(\d+) -(\d+)' { $AHEAD = [int]$Matches[1]; $BEHIND = [int]$Matches[2]; break }
            '^\?'                           { $UNTRACKED++; break }
            '^u'                            { $CONFLICTED++; break }
            '^[12]' {
                $xy = $line.Split(' ')[1]
                if ($xy[0] -ne '.') { $STAGED++ }
                if ($xy[1] -ne '.') { $UNSTAGED++ }
                break
            }
        }
    }

    if ($BRANCH -eq '(detached)') {
        $BRANCH = if ($TAG) { $TAG } else { git -C "$DIR" rev-parse --short HEAD 2>$null }
    }

    "$BRANCH|$TAG|$BEHIND|$AHEAD|$CONFLICTED|$STAGED|$UNSTAGED|$UNTRACKED" |
        Set-Content $CACHE_FILE -NoNewline -Encoding UTF8
}

if (Test-Path $CACHE_FILE) {
    $cached     = (Get-Content $CACHE_FILE -Raw -Encoding UTF8) -split '\|'
    $BRANCH     = $cached[0]
    $TAG        = $cached[1]
    $BEHIND     = [int]$cached[2]
    $AHEAD      = [int]$cached[3]
    $CONFLICTED = [int]$cached[4]
    $STAGED     = [int]$cached[5]
    $UNSTAGED   = [int]$cached[6]
    $UNTRACKED  = [int]$cached[7]
}

if ($BRANCH.Length   -gt 16) { $BRANCH   = $BRANCH.Substring(0, 15)   + '…' }
if ($TAG.Length      -gt 16) { $TAG      = $TAG.Substring(0, 15)      + '…' }
if ($WORKTREE.Length -gt 16) { $WORKTREE = $WORKTREE.Substring(0, 15) + '…' }

$PARTS = [System.Collections.Generic.List[string]]::new()

# Vim mode
if ($VIM_MODE) {
    $modeLetter = $VIM_MODE[0].ToString().ToLower()
    # cap fg uses '38;5;7' (not 37): Claude Code 2.1.300+ draws a plain 37 foreground too dark, so light gray pill caps mismatched their 47 bodies
    $FG, $BG = switch -Wildcard ($VIM_MODE) {
        'INSERT'  { 34, 44 }
        'VISUAL*' { 32, 42 }
        default   { '38;5;7', 47 }
    }
    $PARTS.Add("$e[${FG}m$pl$e[${BG};30m$modeLetter$e[0;${FG}m$pr$e[0m")
}

# CWD
$CWD = $DIR -replace [regex]::Escape($env:USERPROFILE), '~'
if ($CWD.Length -gt 32) { $CWD = Split-Path $CWD -Leaf }
$PARTS.Add("$e[36m$CWD$e[0m")

# Worktree
if ($WORKTREE) {
    $PARTS.Add("$e[94m$WORKTREE$e[0m")
}

# Git
if ($BRANCH) {
    $GIT_STR = ''
    # the worktree segment already shows the branch when the names match
    if ($WORKTREE -and $BRANCH -eq $WORKTREE) {
        if ($TAG -and $BRANCH -ne $TAG) { $GIT_STR = "$e[35m$TAG$e[0m" }
    } elseif ($TAG -and $BRANCH -eq $TAG) {
        $GIT_STR = "$e[35m$BRANCH$e[0m"
    } elseif ($TAG) {
        $GIT_STR = "$e[34m$BRANCH$e[0m $e[35m$TAG$e[0m"
    } else {
        $GIT_STR = "$e[34m$BRANCH$e[0m"
    }
    $gitFlags = @()
    if ($BEHIND     -gt 0) { $gitFlags += "$e[33m↓$BEHIND$e[0m" }
    if ($AHEAD      -gt 0) { $gitFlags += "$e[32m↑$AHEAD$e[0m" }
    if ($CONFLICTED -gt 0) { $gitFlags += "$e[31m?$CONFLICTED$e[0m" }
    if ($STAGED     -gt 0) { $gitFlags += "$e[32m+$STAGED$e[0m" }
    if ($UNSTAGED   -gt 0) { $gitFlags += "$e[33m~$UNSTAGED$e[0m" }
    if ($UNTRACKED  -gt 0) { $gitFlags += "$e[31m*$UNTRACKED$e[0m" }
    if ($gitFlags) { $GIT_STR = (@($GIT_STR) + $gitFlags | Where-Object { $_ }) -join ' ' }
    if ($GIT_STR) { $PARTS.Add($GIT_STR) }
}

# Model (background by cost tier: haiku < sonnet < opus < fable)
if ($MODEL) {
    $MODEL_FG, $MODEL_BG = switch -Wildcard ($MODEL) {
        '*haiku*' { 32, 42 }
        '*opus*'  { 33, 43 }
        '*fable*' { 31, 41 }
        default   { '38;5;7', 47 }
    }
    $PARTS.Add("$e[${MODEL_FG}m$pl$e[${MODEL_BG};30m󰚩 $MODEL$e[0;${MODEL_FG}m$pr$e[0m")
}

# Effort (background by token-use tier: low < medium < high < xhigh < max)
if ($EFFORT) {
    $EFFORT_STR, $EFFORT_FG, $EFFORT_BG = switch ($EFFORT) {
        'low'    { 'lo',  32, 42 }
        'medium' { 'med', '38;5;7', 47 }
        'high'   { 'hi',  33, 43 }
        'xhigh'  { 'xhi', 31, 41 }
        'max'    { 'max', 91, 101 }
        default  { $EFFORT, '38;5;7', 47 }
    }
    $ICON_EFFORT = [char]::ConvertFromUtf32(0xF0238)
    $PARTS.Add("$e[${EFFORT_FG}m$pl$e[${EFFORT_BG};30m$ICON_EFFORT $EFFORT_STR$e[0;${EFFORT_FG}m$pr$e[0m")
}

# Context window
if ($USED) {
    $USED_INT  = [int][Math]::Round([double]$USED, 0, [MidpointRounding]::AwayFromZero)
    $CTX_GLYPH = Get-CtxIcon $USED_INT
    $CTX_FG, $CTX_BG = if ($USED_INT -ge 90) { 31, 41 } elseif ($USED_INT -ge 80) { 33, 43 } else { 90, 100 }
    if ($CUR_IN -and $MAX) {
        $curStr = Format-Tokens ([long]$CUR_IN)
        $maxStr = Format-Tokens ([long]$MAX)
        $PARTS.Add("$e[${CTX_FG}m$pl$e[${CTX_BG};30m$CTX_GLYPH ${USED_INT}% $curStr $maxStr$e[0;${CTX_FG}m$pr$e[0m")
    } else {
        $PARTS.Add("$e[${CTX_FG}m$pl$e[${CTX_BG};30m$CTX_GLYPH ${USED_INT}%$e[0;${CTX_FG}m$pr$e[0m")
    }
    if ($CUR_IN -and [long]$CUR_IN -gt $COMPACT_HINT_TOKENS) {
        $ICON_COMPACT = [char]::ConvertFromUtf32(0xF084D)
        $PARTS.Add("$e[35m$pl$e[45;30m$ICON_COMPACT$e[0;35m$pr$e[0m")
    }
}

# Agent
if ($AGENT) {
    $PARTS.Add("$e[35m󰊠 $AGENT$e[0m")
}

# Usage limits (/usage): 5-hour and 7-day windows
$ICON_5H = [char]::ConvertFromUtf32(0xF051B)  # nf-md-timer_outline
$ICON_7D = [char]::ConvertFromUtf32(0xF0679)  # nf-md-calendar_range
$limits = foreach ($w in @(@($ICON_5H, $data.rate_limits.five_hour), @($ICON_7D, $data.rate_limits.seven_day))) {
    $pct = $w[1].used_percentage
    if ($null -eq $pct -or $pct -eq '') { continue }
    $p = [int][Math]::Round([double]$pct, 0, [MidpointRounding]::AwayFromZero)
    $c = if ($p -ge 90) { 31 } elseif ($p -ge 80) { 33 } else { 90 }
    $s = "$e[${c}m$($w[0]) ${p}%"
    if ($p -ge 80) {
        $left = Format-Remaining $w[1].resets_at
        if ($left) { $s += " $left" }
    }
    "$s$e[0m"
}
if ($limits) { $PARTS.Add($limits -join ' ') }

[Console]::Write($PARTS -join ' ')
