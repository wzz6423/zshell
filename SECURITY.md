# Security Policy

**English** | [简体中文](SECURITY.zh-CN.md)

## Supported Versions

Security fixes are prioritized for the latest Zshell release. Older releases
are not maintained; update through the in-app updater or [the Zshell website](https://wzz6423.github.io/zshell/).

| Version | Supported |
| --- | --- |
| Latest release | Yes |
| Older releases | No |

## Reporting a Vulnerability

Please do not report security vulnerabilities in a public issue, pull request,
or discussion. Use [GitHub Private Vulnerability Reporting](https://github.com/wzz6423/zshell/security/advisories/new)
so the report stays private while it is investigated.

Please include the affected version or commit, the security impact,
reproduction steps or a proof of concept, and relevant macOS and installation
details. Remove real credentials and personal data. If a credential may have
been exposed, revoke or rotate it immediately.

If private reporting is unavailable, contact the maintainer through
[@wzz6423](https://github.com/wzz6423) and do not disclose sensitive
details publicly.

Include the Zshell version shown in **Zshell → About Zshell** when applicable.

## Scope

Zshell embeds libghostty (vendored in `mac/Vendor/libghostty-spm`) for
terminal emulation. In scope here: Zshell's configuration and host
integration of it — clipboard access, escape-sequence handling that
crosses a trust boundary, the update chain, and anything that lets
terminal output reach data outside the session. Vulnerabilities in
upstream Ghostty itself should also be reported to the Ghostty
project: https://github.com/ghostty-org/ghostty/security.

## Response

We aim to acknowledge a report within 7 calendar days and provide an initial
assessment or status update within 14 calendar days. We will coordinate any
public disclosure with the reporter after a fix or mitigation is available.
