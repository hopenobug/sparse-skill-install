#!/usr/bin/env pwsh
#Requires -Version 5.1
# Sparse-clone the skills/ directory of any git repository and install each skill
# it contains. Requires git >= 2.25 (sparse-checkout) and npx.
#
# Usage: sparse-skill-install.ps1 <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:SkillRoot = 'skills'
$script:ScriptName = $MyInvocation.MyCommand.Name
if (-not $script:ScriptName) { $script:ScriptName = 'sparse-skill-install.ps1' }

function Write-ErrorLine {
    param([string]$Message)
    [Console]::Error.WriteLine($Message)
}

function Fail {
    param([string]$Message)
    Write-ErrorLine $Message
    exit 1
}

function Show-Usage {
    param([switch]$ToStdout)
    $text = "usage: $script:ScriptName <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']"
    if ($ToStdout) { [Console]::Out.WriteLine($text) } else { Write-ErrorLine $text }
}

function Invoke-Native {
    param([string]$Exe, [string[]]$Arguments)
    if ($Arguments.Count -gt 0) {
        & $Exe @Arguments
    } else {
        & $Exe
    }
    $code = $LASTEXITCODE
    if ($code -ne 0) { exit $code }
}

# Parse options first. The first positional argument is the repository; every
# other positional argument and every unknown option is forwarded to
# 'npx skills add' in its original order, so option/value pairs such as
# '-a pi' stay adjacent. Anything after -- is always positional.
$skillNames = New-Object System.Collections.Generic.List[string]
$extraArgs = New-Object System.Collections.Generic.List[string]
$repoOrUrl = $null
$afterDash = $false

$i = 0
while ($i -lt $args.Count) {
    $arg = [string]$args[$i]
    if (-not $afterDash -and ($arg -eq '--skill' -or $arg -eq '-skill')) {
        if ($i + 1 -ge $args.Count) { Fail 'error: --skill requires a value' }
        [void]$skillNames.Add([string]$args[$i + 1])
        $i += 2
    }
    elseif (-not $afterDash -and $arg -eq '--') {
        $afterDash = $true
        $i++
    }
    elseif (-not $afterDash -and ($arg -eq '-h' -or $arg -eq '--help' -or $arg -eq '-help')) {
        Show-Usage -ToStdout
        exit 0
    }
    elseif (-not $afterDash -and $arg.StartsWith('-')) {
        # Unknown option: pass it through to npx skills add
        [void]$extraArgs.Add($arg)
        $i++
    }
    elseif ($null -eq $repoOrUrl) {
        $repoOrUrl = $arg
        $i++
    }
    else {
        [void]$extraArgs.Add($arg)
        $i++
    }
}

if ($null -eq $repoOrUrl) { Show-Usage; exit 1 }

if (-not (Get-Command -Name git -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail 'error: git not found'
}
if (-not (Get-Command -Name npx -CommandType Application -ErrorAction SilentlyContinue)) {
    Fail 'error: npx not found'
}

# Expand GitHub HTTPS URLs; foo/bar-repo shorthand is supported
# (local paths like ./ ../ ~/ C:/ and .git-suffixed forms are excluded)
$shorthand = '^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]+$'
if ($repoOrUrl -cmatch $shorthand -and $repoOrUrl -cnotmatch '\.git$') {
    $repo = "https://github.com/$repoOrUrl.git"
} else {
    $repo = $repoOrUrl
}

# 'npx skills add' cannot be told to skip its lockfile, and every entry it writes
# records the source it was given - here the temp clone, which is deleted on exit.
# Classify the real source so those entries can be repointed at it afterwards.
if ($repo -cmatch '^(https?://github\.com/|git@github\.com:)') {
    $sourceKind = 'github'
    $repoSource = ($repo -creplace '^(https?://github\.com/|git@github\.com:)', '') -creplace '\.git$', ''
    $repoUrl = $repo
}
elseif ($repo -cmatch '^(https?://|ssh://|git@)') {
    $sourceKind = 'git'
    $repoSource = $repo
    $repoUrl = $repo
}
else {
    $sourceKind = 'local'
    $repoSource = $repo
    $repoUrl = ''
}

# -g / --global installs are tracked in the global lockfile (~/.agents/.skill-lock.json,
# or $XDG_STATE_HOME/skills/.skill-lock.json); everything else in ./skills-lock.json.
$installGlobal = $false
foreach ($arg in $extraArgs) {
    if ($arg -eq '-g' -or $arg -eq '--global') { $installGlobal = $true }
}

$cloneDir = Join-Path ([System.IO.Path]::GetTempPath()) ('sparse-skill-install-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $cloneDir | Out-Null

$lockPatchJs = @'
const fs = require("fs"), path = require("path");
const [lockPath, prefix, kind, source, sourceUrl] = process.argv.slice(1);
const norm = (v) => String(v || "").split("\\").join("/").replace(/\/+$/, "");
const abs = (v) => norm(path.resolve(path.dirname(lockPath), v));
const root = abs(prefix).toLowerCase();
let lock;
try { lock = JSON.parse(fs.readFileSync(lockPath, "utf8")); } catch (e) { process.exit(0); }
if (!lock || !lock.skills) process.exit(0);
let changed = 0;
for (const entry of Object.values(lock.skills)) {
    if (!entry) continue;
    const src = norm(entry.source), url = norm(entry.sourceUrl);
    const inside = (v) => { if (!v) return false; const a = abs(v).toLowerCase(); return a === root || a.indexOf(root + "/") === 0; };
    const hit = inside(src) ? src : (inside(url) ? url : null);
    if (!hit) continue;
    const tail = abs(hit).slice(root.length).replace(/^\//, "");
    if (kind === "local") {
        entry.source = abs(source) + (tail ? "/" + tail : "");
        entry.sourceType = "local";
        delete entry.sourceUrl;
        delete entry.skillPath;
    } else {
        entry.source = source;
        entry.sourceType = kind;
        entry.sourceUrl = sourceUrl || source;
        if (tail) entry.skillPath = tail + "/SKILL.md";
    }
    changed++;
}
if (!changed) process.exit(0);
fs.writeFileSync(lockPath + ".tmp", JSON.stringify(lock, null, 2) + "\n");
fs.renameSync(lockPath + ".tmp", lockPath);
console.log("==> Repointed " + changed + " lockfile entry(ies) at " + source + " (" + lockPath + ")");
'@

# Replace the temp-clone sources the CLI just wrote with the real ones. Runs on
# every exit path so a failed run does not leave a dangling source behind.
function Update-LockSource {
    if ($installGlobal) {
        $lockPath = if ($env:XDG_STATE_HOME) { Join-Path $env:XDG_STATE_HOME 'skills/.skill-lock.json' }
        else { Join-Path $HOME '.agents/.skill-lock.json' }
    }
    else {
        $lockPath = Join-Path $PWD.Path 'skills-lock.json'
    }

    if (-not (Test-Path -LiteralPath $lockPath -PathType Leaf)) { return }
    if (-not (Get-Command -Name node -CommandType Application -ErrorAction SilentlyContinue)) {
        Write-ErrorLine "warning: node not found; left '$lockPath' pointing at the deleted temp clone"
        return
    }
    & node -e $lockPatchJs $lockPath $cloneDir $sourceKind $repoSource $repoUrl
}

try {
    Invoke-Native 'git' @('clone', '--no-checkout', '--depth', '1', '--filter=blob:none', $repo, $cloneDir)

    # Git runs against the clone via -C and 'npx skills add' runs from the caller's
    # current directory with an absolute source path, so the skills land where the
    # caller expects them (not inside the temp clone, which gets deleted).
    Invoke-Native 'git' @('-C', $cloneDir, 'sparse-checkout', 'init', '--cone')

    # Compute the skill directories to install (single representation that feeds
    # both the sparse-checkout paths and the install loop)
    $skillDirs = New-Object System.Collections.Generic.List[string]
    if ($skillNames.Count -gt 0) {
        foreach ($name in $skillNames) {
            [void]$skillDirs.Add("$script:SkillRoot/$name")
        }
        Invoke-Native 'git' ((@('-C', $cloneDir, 'sparse-checkout', 'set')) + $skillDirs.ToArray())
    } else {
        Invoke-Native 'git' @('-C', $cloneDir, 'sparse-checkout', 'set', $script:SkillRoot)
    }

    Invoke-Native 'git' @('-C', $cloneDir, 'checkout')

    $sourceRoot = Join-Path $cloneDir $script:SkillRoot
    if ($skillNames.Count -gt 0) {
        # Explicit selection: a missing skill is an error
        foreach ($dir in $skillDirs) {
            if (-not (Test-Path -LiteralPath (Join-Path $cloneDir (Join-Path $dir 'SKILL.md')) -PathType Leaf)) {
                Fail ("error: skill '" + $dir.Substring($script:SkillRoot.Length + 1) + "' not found (missing SKILL.md)")
            }
        }
    } else {
        # No selection: install every directory under skills/ that has a SKILL.md
        if (-not (Test-Path -LiteralPath $sourceRoot -PathType Container)) {
            Fail ("error: no '$($script:SkillRoot)/' directory in $repo")
        }
        $skillDirs.Clear()
        $candidates = @(Get-ChildItem -LiteralPath $sourceRoot -Directory | Sort-Object -Property Name)
        foreach ($candidate in $candidates) {
            if (Test-Path -LiteralPath (Join-Path $candidate.FullName 'SKILL.md') -PathType Leaf) {
                [void]$skillDirs.Add("$script:SkillRoot/$($candidate.Name)")
            }
        }
        if ($skillDirs.Count -eq 0) {
            Fail ("error: no skills found under '$($script:SkillRoot)/' in $repo")
        }
    }

    foreach ($dir in $skillDirs) {
        Write-Host "==> Adding skill: $($dir.Substring($script:SkillRoot.Length + 1))"
        $skillPath = (Join-Path $cloneDir $dir) + [System.IO.Path]::DirectorySeparatorChar
        Invoke-Native 'npx' ((@('skills', 'add', $skillPath)) + $extraArgs.ToArray())
    }
}
finally {
    Update-LockSource
    if (Test-Path -LiteralPath $cloneDir) {
        try {
            Remove-Item -LiteralPath $cloneDir -Recurse -Force -ErrorAction Stop
        } catch {
            Write-ErrorLine "warning: could not remove temp directory '$cloneDir': $($_.Exception.Message)"
        }
    }
}
