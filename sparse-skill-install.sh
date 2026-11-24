#!/usr/bin/env bash
# Sparse-clone the skills/ directory of any git repository and install each skill
# it contains. Requires git >= 2.25 (sparse-checkout) and npx.
#
# Usage: sparse-skill-install.sh <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']

set -euo pipefail

usage() {
    echo "usage: $0 <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']" >&2
    exit 1
}

[[ ${1-} ]] || usage

SKILL_ROOT="skills"
skill_names=()
extra_args=()
repo_or_url=""
have_repo=0

# Parse options first. The first positional argument is the repository; every
# other positional argument and every unknown option is forwarded to
# 'npx skills add' in its original order, so option/value pairs such as
# '-a pi' stay adjacent. Anything after -- is always positional.
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skill)
            [[ ${2-} ]] || { echo "error: --skill requires a value" >&2; exit 1; }
            skill_names+=("$2")
            shift 2
            ;;
        --)
            shift
            while [[ $# -gt 0 ]]; do
                if (( have_repo == 0 )); then repo_or_url="$1"; have_repo=1; else extra_args+=("$1"); fi
                shift
            done
            ;;
        -*)
            # Unknown option: pass it through to npx skills add
            extra_args+=("$1")
            shift
            ;;
        *)
            if (( have_repo == 0 )); then repo_or_url="$1"; have_repo=1; else extra_args+=("$1"); fi
            shift
            ;;
    esac
done

(( have_repo == 1 )) || usage

command -v git >/dev/null 2>&1 || { echo "error: git not found" >&2; exit 1; }
command -v npx >/dev/null 2>&1 || { echo "error: npx not found" >&2; exit 1; }

# Expand GitHub HTTPS URLs; foo/bar-repo shorthand is supported
# (local paths like ./ ../ ~/ C:/ and .git-suffixed forms are excluded)
if [[ "$repo_or_url" =~ ^[A-Za-z0-9_][A-Za-z0-9_.-]*/[A-Za-z0-9_][A-Za-z0-9_.-]+$ && ! "$repo_or_url" =~ \.git$ ]]; then
    repo="https://github.com/${repo_or_url}.git"
else
    repo="$repo_or_url"
fi

clone_dir=$(mktemp -d)

# 'npx skills add' cannot be told to skip its lockfile, and every entry it writes
# records the source it was given — here the temp clone, which is deleted on exit.
# Classify the real source so those entries can be repointed at it afterwards.
if [[ "$repo" =~ ^(https?://github\.com/|git@github\.com:) ]]; then
    source_kind=github
    repo_source="$(printf '%s' "$repo" | sed -E 's#^(https?://github\.com/|git@github\.com:)##; s#\.git$##')"
    repo_url="$repo"
elif [[ "$repo" =~ ^(https?://|ssh://|git@) ]]; then
    source_kind=git
    repo_source="$repo"
    repo_url="$repo"
else
    source_kind=local
    repo_source="$repo"
    repo_url=""
fi

# -g / --global installs are tracked in the global lockfile (~/.agents/.skill-lock.json,
# or $XDG_STATE_HOME/skills/.skill-lock.json); everything else in ./skills-lock.json.
install_global=0
for arg in ${extra_args[@]+"${extra_args[@]}"}; do
    if [[ "$arg" == -g || "$arg" == --global ]]; then install_global=1; fi
done

lock_patch_js='const fs = require("fs"), path = require("path");
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
console.log("==> Repointed " + changed + " lockfile entry(ies) at " + source + " (" + lockPath + ")");'

# Replace the temp-clone sources the CLI just wrote with the real ones. Runs on
# every exit path so a failed run does not leave a dangling source behind.
repoint_lock() {
    local lock_path lock_arg clone_arg source_arg
    if (( install_global == 1 )); then
        if [[ -n ${XDG_STATE_HOME-} ]]; then
            lock_path="$XDG_STATE_HOME/skills/.skill-lock.json"
        else
            lock_path="$HOME/.agents/.skill-lock.json"
        fi
    else
        lock_path="$PWD/skills-lock.json"
    fi
    [[ -f "$lock_path" ]] || return 0
    if ! command -v node >/dev/null 2>&1; then
        echo "warning: node not found; left '$lock_path' pointing at the deleted temp clone" >&2
        return 0
    fi
    # node compares Windows paths, so hand it native paths on MSYS/Git Bash
    if command -v cygpath >/dev/null 2>&1; then
        lock_arg=$(cygpath -w "$lock_path")
        clone_arg=$(cygpath -w "$clone_dir")
        if [[ "$source_kind" == local ]]; then
            source_arg=$(cygpath -w "$repo_source")
        else
            source_arg="$repo_source"
        fi
    else
        lock_arg="$lock_path"
        clone_arg="$clone_dir"
        source_arg="$repo_source"
    fi
    node -e "$lock_patch_js" "$lock_arg" "$clone_arg" "$source_kind" "$source_arg" "$repo_url" || true
}

trap 'repoint_lock; rm -rf "$clone_dir"' EXIT

git clone --no-checkout --depth 1 --filter=blob:none "$repo" "$clone_dir"

# Git runs against the clone via -C and 'npx skills add' runs from the caller's
# current directory with an absolute source path, so the skills land where the
# caller expects them (not inside the temp clone, which gets deleted).
git -C "$clone_dir" sparse-checkout init --cone

# Compute the skill directories to install (single representation that feeds
# both the sparse-checkout paths and the install loop)
skill_dirs=()
if [[ ${#skill_names[@]} -gt 0 ]]; then
    for name in "${skill_names[@]}"; do
        skill_dirs+=("${SKILL_ROOT}/${name}")
    done
    git -C "$clone_dir" sparse-checkout set "${skill_dirs[@]}"
else
    git -C "$clone_dir" sparse-checkout set "$SKILL_ROOT"
fi

git -C "$clone_dir" checkout

if [[ ${#skill_names[@]} -gt 0 ]]; then
    # Explicit selection: a missing skill is an error
    for dir in "${skill_dirs[@]}"; do
        [[ -f "${clone_dir}/${dir}/SKILL.md" ]] || { echo "error: skill '${dir#"$SKILL_ROOT"/}' not found (missing SKILL.md)" >&2; exit 1; }
    done
else
    # No selection: install every directory under skills/ that has a SKILL.md
    source_root="${clone_dir}/${SKILL_ROOT}"
    [[ -d "$source_root" ]] || { echo "error: no '$SKILL_ROOT/' directory in $repo" >&2; exit 1; }
    shopt -s nullglob
    skill_dirs=()
    for dir in "$source_root"/*/; do
        [[ -f "${dir}SKILL.md" ]] && skill_dirs+=("${SKILL_ROOT}/$(basename "$dir")")
    done
    [[ ${#skill_dirs[@]} -gt 0 ]] || { echo "error: no skills found under '$SKILL_ROOT/' in $repo" >&2; exit 1; }
fi

for dir in "${skill_dirs[@]}"; do
    echo "==> Adding skill: ${dir#"$SKILL_ROOT"/}"
    npx skills add "${clone_dir}/${dir}/" ${extra_args[@]+"${extra_args[@]}"}
done
