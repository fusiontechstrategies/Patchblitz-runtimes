# Security policy

## Supported material

Security reports for this repository should concern the committed runtime build recipe, published runtime archives, checksums, build records, provenance, or accidental secret exposure. The private PatchBlitz product and installer are maintained separately.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for `fusiontechstrategies/Patchblitz-runtimes`. Do not open a public issue for a vulnerability, suspected secret, unpublished product detail, or exploitable archive-integrity problem.

Include:

- the exact release tag, asset filename, size, and observed SHA-256 digest;
- whether the issue affects the build recipe, published archive, JSON build record, or checksum file;
- the relevant Windows, PowerShell, compiler, Python, OpenSSL, and SQLite versions;
- minimal reproduction steps that do not contain customer data or credentials; and
- any evidence that the same issue affects a PatchBlitz installer consuming the pinned artifact.

Do not upload a modified runtime archive containing exploit code or real secrets. A small description, digest, and isolated reproduction is sufficient to begin triage.

## Response boundary

Acknowledgment and remediation timing depend on severity, reproducibility, upstream component status, and the private product versions that pin the affected runtime. A replacement runtime, when required, receives a new versioned release and evidence set; consumers must not assume that an existing mutable download name has been silently repaired.
