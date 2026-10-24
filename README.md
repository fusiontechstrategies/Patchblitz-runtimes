# PatchBlitz runtimes

Pinned, reproducible runtime archives bundled by the PatchBlitz Enterprise
Windows setup. This repository holds only the build recipes and their
published release artifacts; it contains no PatchBlitz product source.

## Python runtime

Release tag: `patchblitz-python-3.14.9-openssl-3.5.9`

| Component | Version | Source |
|---|---|---|
| CPython | 3.14.9 | [python-build-standalone](https://github.com/astral-sh/python-build-standalone) release `20261021`, `install_only_stripped` x86_64 Windows build |
| OpenSSL | 3.5.9 (29 Sep 2026) | As built upstream by python-build-standalone |
| SQLite | 3.54.1 | Official amalgamation from sqlite.org, compiled with the same feature set as the upstream DLL |
| pip | 26.2.2 | As bundled upstream |

[`scripts/Build-PatchBlitz-PythonRuntime.ps1`](scripts/Build-PatchBlitz-PythonRuntime.ps1)
builds the archive. It:

1. Downloads the upstream CPython archive and verifies its size and SHA-256.
2. Copies the upstream third-party license texts from the same release's full build into `python/licenses/`.
3. Compiles `DLLs/sqlite3.dll` from the SQLite amalgamation (verified by the SHA3-256 sqlite.org publishes) and checks that it reports every upstream compile option.
4. Removes the Tcl/Tk GUI stack (`tkinter`, IDLE, turtle), which a headless server never loads.
5. Verifies the Python, OpenSSL, SQLite, and pip identities, and runs a smoke test.
6. Writes a deterministic `tar.gz` and a JSON record of every input digest and the resulting tree identity.

Building twice gives byte-identical archives. Requirements: PowerShell 7.4+
and Visual Studio 2022 (or Build Tools) with the x64 C++ toolset.

## Licenses

Each archive keeps the licenses of what it contains:

- CPython: Python Software Foundation License (`python/LICENSE.txt`).
- OpenSSL: Apache-2.0.
- SQLite: public domain.
- libffi, mpdecimal, liblzma, zlib, bzip2, zstd, Expat and others: under their own licenses.

The full upstream texts are in `python/licenses/`.

The build recipe is Copyright (c) 2026 Fusion Technology Strategies, Inc.
