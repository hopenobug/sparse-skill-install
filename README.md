# sparse-skill-install

Install [skills](https://github.com/anthropics/skills) from any git repository, fast.

The scripts sparse-clone only the repository's `skills/` directory (via `git sparse-checkout` + `--filter=blob:none`), then install each skill they find with `npx skills add`. For large repositories this avoids downloading and checking out the entire tree.

Two equivalent scripts are provided — pick the one that fits your platform:

| Script | Runtime |
| --- | --- |
| `sparse-skill-install.sh` | bash (Linux, macOS, WSL, Git Bash) |
| `sparse-skill-install.ps1` | Windows PowerShell 5.1+, PowerShell 7+ (Windows, Linux, macOS) |

Both accept the same arguments and behave identically.

## Requirements

- git >= 2.25 (for `sparse-checkout`)
- [npx](https://docs.npmjs.com/cli/commands/npx)
- bash, or PowerShell 5.1+ / PowerShell 7+

## Usage

Run the script from the directory you want the skills installed in (typically your project root); the skills CLI installs them relative to the current directory, e.g. `.agents/skills/<name>`.

```sh
./sparse-skill-install.sh <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']
```

```powershell
./sparse-skill-install.ps1 <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']
```

The PowerShell script also accepts the PowerShell-style `-Skill <name>` (and `-h` / `--help` for usage). Everything else is identical, including pass-through arguments.

### PowerShell notes

On Windows, either run it from a PowerShell session:

```powershell
./sparse-skill-install.ps1 someuser/some-repo --skill code-review
```

or invoke it through the host (useful when the execution policy is restricted):

```powershell
pwsh -File ./sparse-skill-install.ps1 someuser/some-repo --skill code-review
powershell -ExecutionPolicy Bypass -File ./sparse-skill-install.ps1 someuser/some-repo
```

If the file was downloaded from the internet and is blocked, unblock it once:

```powershell
Unblock-File ./sparse-skill-install.ps1
```

On Linux/macOS the script carries a `#!/usr/bin/env pwsh` shebang, so once it is executable it runs directly (requires PowerShell 7 as `pwsh` on `PATH`). Git checkouts may not preserve the executable bit, so set it once:

```sh
chmod +x ./sparse-skill-install.ps1
./sparse-skill-install.ps1 someuser/some-repo
```

### Install all skills in a repository

```sh
./sparse-skill-install.sh someuser/some-repo
```

```powershell
./sparse-skill-install.ps1 someuser/some-repo
```

Every directory under `skills/` that contains a `SKILL.md` is installed.

### Install selected skills only

```sh
./sparse-skill-install.sh someuser/some-repo --skill code-review --skill eli5
```

```powershell
./sparse-skill-install.ps1 someuser/some-repo -Skill code-review -Skill eli5
```

Only `skills/code-review` and `skills/eli5` are fetched and installed. A missing skill is an error.

### Repository sources

- `foo/bar-repo` — GitHub shorthand, expanded to `https://github.com/foo/bar-repo.git`
- Any full clone URL: `https://...`, `git@...`, `ssh://...`, or a local path

Local paths that happen to look like `owner/repo` are treated as GitHub shorthand, so quote and qualify them, e.g. `"C:/work/myrepo"` or `../myrepo`. Windows paths with backslashes (`C:\work\myrepo`) and paths containing spaces need quoting:

```powershell
./sparse-skill-install.ps1 "C:\work\my repo" --skill code-review
```

```sh
./sparse-skill-install.sh "./my repo" --skill code-review
```

### Extra arguments

Unknown options and extra positional arguments are passed through to `npx skills add` in their original order, so option/value pairs such as `-a pi` stay adjacent. For example, `--yes` skips npx prompts and `-a <agent>` selects the target agent:

```sh
./sparse-skill-install.sh someuser/some-repo --skill code-review -a pi -y
```

```powershell
./sparse-skill-install.ps1 someuser/some-repo -Skill code-review -a pi -y
```

Use `--` to force everything after it to be treated as positional.

## What it does

1. Clones the repository with `--no-checkout --depth 1 --filter=blob:none` into a temp directory (removed on exit).
2. Applies `git sparse-checkout` to fetch only `skills/` — or only the selected skill directories.
3. Verifies each target directory has a `SKILL.md` (fails loudly if the repository has no skills).
4. Runs `npx skills add` once per skill, from your current working directory and with the absolute path of the cloned copy, so skills land where the skills CLI installs for the current project — never inside the temp clone (which is deleted).
5. Points the lockfile at the real repository instead of the temp clone. `npx skills add` cannot be told to skip its lockfile, and the source it records is whatever it was given — here the temp clone, which is deleted on exit. Both scripts therefore rewrite *only* those entries (`source`, `sourceType`, `sourceUrl`, `skillPath`) after the installs: `npx skills ls` then shows `someuser/some-repo` instead of a dead `…\Temp\…` path, `skills update` can re-fetch from the real repository, and hashes plus all unrelated entries are left untouched. `-g` / `--global` runs patch `~/.agents/.skill-lock.json` (or `$XDG_STATE_HOME/skills/.skill-lock.json` when that variable is set); every other run patches `./skills-lock.json`. The rewrite needs `node` (already required by `npx`); if it is missing the script warns and leaves the lockfile alone.

## Errors

Both scripts exit non-zero with a message on stderr when:

- no repository is given (usage),
- `--skill` is given without a value,
- a selected skill is missing its `SKILL.md`,
- the repository has no `skills/` directory or no skills in it,
- `git` or `npx` is not installed.

`git` and `npx` failures abort the run with their own exit code.
