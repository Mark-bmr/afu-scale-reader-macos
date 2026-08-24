# Security Policy

## Supported version

Security fixes are made on the current `main` branch. This source release targets macOS 13 or later.

## Report a vulnerability privately

Use [GitHub Private Vulnerability Reporting](https://github.com/Mark-bmr/afu-scale-reader-macos/security/advisories/new). Do not open a public Issue for an unpatched vulnerability, and do not attach real configuration files, health records, device identifiers or logs containing personal data.

Include a concise description, affected commit, reproduction steps using synthetic data, expected impact and any suggested mitigation. Maintainers will acknowledge a usable report, investigate it and coordinate disclosure through the security advisory.

## Security boundaries

- The application has no built-in network client or telemetry.
- Local configuration, output, mirrors and logs contain sensitive health information and use `0600` permissions.
- Output restoration requires the expected schema and random `store_id`; unrelated files are not overwritten.
- Debug logging is opt-in and can contain sensitive troubleshooting details.
- The app is ad-hoc signed during local installation. Users build it from source and grant macOS Bluetooth permission locally.

Compromise of the macOS user account, a user-selected sync provider or a directory with broader access is outside the application's isolation boundary, but reports about unsafe defaults or file handling are welcome.
