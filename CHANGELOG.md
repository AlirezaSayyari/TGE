# Changelog

This changelog records verified TGE changes from the Runovel migration onward. Earlier releases are listed without reconstructed details.

## [Unreleased]

No changes yet.

## [1.2.6] - 2026-07-29

### Fixed

- Preserve the executable Git mode of `deploy.sh` for clean Linux checkouts and direct installer execution.

### Added

- Add Runovel repository governance and contribution documentation.
- Add security reporting guidance and private vulnerability reporting support.
- Add GitHub issue templates, pull request template, and CODEOWNERS.
- Add the `Shell validation` GitHub Actions workflow.

### Changed

- Standardize repository identity and documentation for `runovelhq/tge`.
- Rename the Apache 2.0 license file to the canonical `LICENSE` path without changing its content.
- Preserve compatibility with existing TGE installation, upgrade, and bridge behavior.

### Validation

- Validate shell syntax successfully.
- Validate clean Linux checkout executable behavior.
- Pass all 102 repository bridge tests locally and in GitHub Actions.

## [v1.2.5] — 2026-07-28

### Added

- Runovel repository migration bridge with canonical-first resolution.
- Legacy compatibility fallbacks for `AlirezaSayyari/TGE` and `AlirezaSayyari/V2rayTGE`.
- Comprehensive repository bridge tests and disposable runtime validation.

### Changed

- Hardened repository, version, archive, and temporary-directory upgrade validation.
- Unified post-upgrade verification on the canonical `/usr/local/bin/tge` path.

### Security

- Made pre-upgrade configuration backup handling fail closed.

## Earlier releases

- [v1.2.4](https://github.com/runovelhq/tge/releases/tag/v1.2.4)
- [v1.2.3](https://github.com/runovelhq/tge/releases/tag/v1.2.3)
- [v1.2.2](https://github.com/runovelhq/tge/releases/tag/v1.2.2)
- [v1.2.1](https://github.com/runovelhq/tge/tree/v1.2.1)
- [v1.2.0](https://github.com/runovelhq/tge/releases/tag/v1.2.0)
- [v1.1.0](https://github.com/runovelhq/tge/releases/tag/v1.1.0)
- [v1.0.1](https://github.com/runovelhq/tge/releases/tag/v1.0.1)
- [v1.0.0](https://github.com/runovelhq/tge/tree/v1.0.0)

[Unreleased]: https://github.com/runovelhq/tge/compare/v1.2.6...HEAD
[1.2.6]: https://github.com/runovelhq/tge/releases/tag/v1.2.6
[v1.2.5]: https://github.com/runovelhq/tge/releases/tag/v1.2.5
