# sparse-skill-install.sh

Install [skills](https://github.com/anthropics/skills) from any git repository, fast.

The script sparse-clones only the repository's `skills/` directory (via `git sparse-checkout` + `--filter=blob:none`), then installs each skill it finds with `npx skills add`. For large repositories this avoids downloading and checking out the entire tree.

## Requirements

- bash
- git >= 2.25 (for `sparse-checkout`)
- [npx](https://docs.npmjs.com/cli/commands/npx)

## Usage

```sh
./sparse-skill-install.sh <repo-or-url> [--skill <name>]... [extra args for 'npx skills add']
```

### Install all skills in a repository

```sh
./sparse-skill-install.sh someuser/some-repo
```

Every directory under `skills/` that contains a `SKILL.md` is installed.

### Install selected skills only

```sh
./sparse-skill-install.sh someuser/some-repo --skill code-review --skill eli5
```

Only `skills/code-review` and `skills/eli5` are fetched and installed. A missing skill is an error.

### Repository sources

- `foo/bar-repo` — GitHub shorthand, expanded to `https://github.com/foo/bar-repo.git`
- Any full clone URL: `https://...`, `git@...`, `ssh://...`, or a local path

### Extra arguments

Unknown options and trailing positional arguments are passed through to `npx skills add`, e.g. `--yes` to skip npx prompts. Use `--` to force everything after it to be treated as positional.

## What it does

1. Clones the repository with `--no-checkout --depth 1 --filter=blob:none` into a temp directory (removed on exit).
2. Applies `git sparse-checkout` to fetch only `skills/` — or only the selected skill directories.
3. Verifies each target directory has a `SKILL.md` (fails loudly if the repository has no skills).
4. Runs `npx skills add` once per skill.

## Errors

The script exits non-zero with a message on stderr when:

- no repository is given (usage),
- `--skill` is given without a value,
- a selected skill is missing its `SKILL.md`,
- the repository has no `skills/` directory or no skills in it,
- `git` or `npx` is not installed.
