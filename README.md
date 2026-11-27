# T3 Code custom release host

This repository hosts the public custom-build release feed. The migration
workflows are intentionally dry-run-only until the private source repository
has been validated and the owner explicitly enables the live paths.

## Migration dry run

The workflows use only manual dispatch, schedule, and repository-dispatch
events. They never run for pull requests. A private checkout is made with
`git clone` into a neutral runner-temporary directory; no private repository
identity is stored in this repository.

Before dispatching, configure these Actions secrets:

- `PRIVATE_REPO_READ_TOKEN`
- `PRIVATE_REPO_DISCOVER_TOKEN`
- `PRIVATE_REPO_MERGE_TOKEN`
- `PRIVATE_REPO_OWNER`
- `PRIVATE_REPO_NAME`

Start with `validate.yml` for the target private pull request. Leave
`full_build` disabled for the first run. The run should show only generic
success summaries, never a private repository name, URL, source path, raw
tool log, token, or uploaded artifact. After that privacy check, a second
manual run may enable `full_build`; it still only packages locally and never
uploads or publishes anything.

`discover.yml`, `auto-merge.yml`, `release.yml`, `repair-stable.yml`, and
`build-patched.yml` are all dry-run workflows. They report what they would do;
none creates a branch, opens or merges a private pull request, creates a
release, uploads an artifact, or changes repository settings.
