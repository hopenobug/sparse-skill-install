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

# Parse options first, then keep remaining positional args; anything after --
# is treated as positional, never as an option
positional=()
while [[ $# -gt 0 ]]; do
    case "$1" in
        --skill)
            [[ ${2-} ]] || { echo "error: --skill requires a value" >&2; exit 1; }
            skill_names+=("$2")
            shift 2
            ;;
        --)
            shift
            positional+=("$@")
            break
            ;;
        -*)
            # Unknown option: pass it through to npx skills add
            extra_args+=("$1")
            shift
            ;;
        *)
            positional+=("$1")
            shift
            ;;
    esac
done

[[ ${#positional[@]} -gt 0 ]] || usage
repo_or_url="${positional[0]}"
extra_args+=("${positional[@]:1}")

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
trap 'rm -rf "$clone_dir"' EXIT

git clone --no-checkout --depth 1 --filter=blob:none "$repo" "$clone_dir"
cd "$clone_dir"
git sparse-checkout init --cone

# Compute the skill directories to install (single representation that feeds
# both the sparse-checkout paths and the install loop)
skill_dirs=()
if [[ ${#skill_names[@]} -gt 0 ]]; then
    for name in "${skill_names[@]}"; do
        skill_dirs+=("${SKILL_ROOT}/${name}")
    done
    git sparse-checkout set "${skill_dirs[@]}"
else
    git sparse-checkout set "$SKILL_ROOT"
fi

git checkout

if [[ ${#skill_names[@]} -gt 0 ]]; then
    # Explicit selection: a missing skill is an error
    for dir in "${skill_dirs[@]}"; do
        [[ -f "${dir}/SKILL.md" ]] || { echo "error: skill '${dir#"$SKILL_ROOT"/}' not found (missing SKILL.md)" >&2; exit 1; }
    done
else
    # No selection: install every directory under skills/ that has a SKILL.md
    [[ -d "$SKILL_ROOT" ]] || { echo "error: no '$SKILL_ROOT/' directory in $repo" >&2; exit 1; }
    skill_dirs=()
    for dir in "$SKILL_ROOT"/*/; do
        [[ -f "${dir}SKILL.md" ]] && skill_dirs+=("${dir%/}")
    done
    [[ ${#skill_dirs[@]} -gt 0 ]] || { echo "error: no skills found under '$SKILL_ROOT/' in $repo" >&2; exit 1; }
    shopt -s nullglob
fi

for dir in "${skill_dirs[@]}"; do
    echo "==> Adding skill: ${dir#"$SKILL_ROOT"/}"
    npx skills add "./$dir/" ${extra_args[@]+"${extra_args[@]}"}
done
