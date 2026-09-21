# Security Policy

## Reporting a vulnerability

Please do not open a public issue for vulnerabilities involving authentication data, local file access, WebKit sessions, or App Group isolation. Use GitHub's private vulnerability reporting feature when enabled by the repository owner.

Include affected versions, reproduction steps, and impact. Remove cookies, tokens, account identifiers, certificate data, and private paths from reports.

## Data boundaries

- Claude authentication remains inside the app's local WebKit data store.
- Codex authentication is handled by the locally installed Codex app-server.
- The widget snapshot contains quota values, timestamps, failure flags, and display language only.
- Custom background images stay on the local Mac.

This project does not operate a backend service or collect telemetry.
