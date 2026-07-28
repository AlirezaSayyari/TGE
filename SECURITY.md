# Security Policy

## Supported versions

Only the latest stable TGE release should be assumed to receive security fixes. Users should reproduce reports against the latest stable release when practical and state if an older installation is affected.

## Reporting a vulnerability

Do not disclose suspected vulnerabilities or exploitable details in public issues, pull requests, discussions, or commit messages before coordinated disclosure.

Use GitHub's **Report a vulnerability** option for `runovelhq/tge` if it is available. If private vulnerability reporting is unavailable, contact Runovel at `info@runovel.com` and identify TGE as the affected project. This address is the approved fallback channel in the Runovel organization security policy.

Runovel will acknowledge reports on a best-effort basis, validate the issue, and coordinate remediation and disclosure. An acknowledgement time is not guaranteed.

## Scope

Security reports may cover:

- installer and upgrade behavior;
- root and privilege boundaries;
- configuration, metadata, and backup handling;
- routing, firewall, Docker, systemd, GRE, WireGuard, and egress behavior;
- repository, archive, release, and dependency integrity;
- handling of credentials, tokens, keys, and sensitive diagnostics.

## What to include

Include the affected TGE version, operating-system version, deployment mode, impact, minimal reproduction steps, relevant commands, and redacted logs. Explain whether the behavior requires root access or a specific network topology.

Remove credentials, tokens, passwords, private keys, personal data, identifying addresses, hostnames, production configuration, full firewall exports, and customer or provider data. Prefer minimal synthetic examples.
