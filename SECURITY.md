# Security policy

## Supported versions

Only the [latest release](https://github.com/jgoodliffe/AppleBeat/releases/latest) is supported. Fixes are made there, not in older versions.

## Reporting a vulnerability

Please report security problems privately, not in a public issue:

1. Go to the repository's [Security tab](https://github.com/jgoodliffe/AppleBeat/security).
2. Choose **Report a vulnerability** and describe the problem and how to reproduce it.

This is a small personal project, so there is no guaranteed response time, but reports are read and a fix or a reply will follow as soon as possible.

## What the app does

Knowing what AppleBeat touches may help when judging a report:

- It captures the Mac's system audio through a Core Audio process tap, after macOS asks for permission. Audio is analysed in memory and never recorded, saved or sent anywhere.
- It makes no network connections.
- It controls the lid logo through a private macOS interface (`CoreBrightness`), which is why it is not sandboxed.
- Releases are signed with a Developer ID and notarised by Apple. Each release lists the SHA-256 of its download.
