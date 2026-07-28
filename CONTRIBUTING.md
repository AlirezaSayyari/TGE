# Contributing to TGE

Thank you for contributing to TGE. Keep changes focused, reviewable, and safe for gateway environments.

## Supported development environment

TGE targets Ubuntu Server and uses Bash, systemd, Docker Compose, iproute2, and iptables. Tests that need root, network namespaces, containers, firewall changes, routes, or services must run only in an explicitly disposable environment. Ordinary repository bridge tests must not contact production infrastructure or mutate the host runtime.

## Workflow

1. Fork `runovelhq/tge` and create a short-lived branch such as `fix/short-name`, `feat/short-name`, or `docs/short-name`.
2. Keep each pull request limited to one coherent change.
3. Add or update tests and documentation when behavior changes.
4. Explain runtime, compatibility, security, and operational effects in the pull request.

Use concise imperative commit subjects. Conventional prefixes such as `fix:`, `feat:`, `docs:`, `test:`, and `chore:` are encouraged when they accurately describe the change.

## Security and credentials

Never commit credentials, tokens, passwords, private keys, production configuration, customer data, unredacted logs, or identifying network exports. Follow [SECURITY.md](SECURITY.md) for vulnerability reports.

## Shell expectations

- Use Bash for existing Bash entry points.
- Preserve `set -u` or `set -euo pipefail` behavior where present.
- Quote expansions and fail closed around privileged or destructive operations.
- Do not flush firewall, routing, or system state in tests.
- Preserve existing runtime paths, CLI names, and service names unless the change explicitly migrates them.

## Validation

Run before submitting:

```bash
bash -n deploy.sh
bash -n tge/bin/tge
bash tests/test_repository_bridge.sh
git diff --check
```

Update the README and changelog when user-visible behavior changes.

## Migration compatibility

The canonical repository is `runovelhq/tge`. The legacy repository fallbacks are intentional migration behavior. Do not remove or reorder them without an approved compatibility-removal plan, corresponding tests, and release communication.
