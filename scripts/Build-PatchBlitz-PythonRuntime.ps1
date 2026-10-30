#requires -Version 7.4
<#
.SYNOPSIS
    Builds the private CPython runtime archive that config/unified-runtime-lock.json pins.

.DESCRIPTION
    Recipe for the "python" asset of the unified Windows setup. It starts from one exact
    python-build-standalone install_only_stripped release (no PDB debug symbols), replaces only DLLs\sqlite3.dll with a
    build of one exact official SQLite amalgamation (same compile options the upstream
    DLL carries), removes the Tcl/Tk GUI stack a headless server never loads, and writes
    a deterministic tar.gz whose top-level directory is "python" -- the layout
    Build-PatchBlitz-UnifiedSetup.ps1 extracts.

    Every input is verified by size and digest before use. The script refuses to write
    an archive unless the result reports exactly the requested CPython, OpenSSL, SQLite,
    and pip identities and the replacement SQLite carries the upstream compile options.
    It prints the runtime_identity block the lock must record, computed with the same
    stable-tree algorithm the setup builder enforces.

    Nothing is installed and no machine setting changes. Requires Visual Studio 2022
    (or Build Tools) with the x64 C++ toolset.
#>

[CmdletBinding()]
param(
    [string] $CacheRoot = (Join-Path $env:TEMP "PatchBlitzPythonRuntimeBuild"),
    [string] $OutputDirectory = "",

    [string] $PbsRelease = "20261021",
    [string] $CPythonVersion = "3.14.9",
    [long] $PbsArchiveSize = 23250453,
    [string] $PbsArchiveSha256 = "57cc230da61d897e8e593511c9dac781491675a036cb727b7de5cb7a62ceebea",
    # The same release's full build carries the third-party license texts the stripped
    # archive omits (OpenSSL, SQLite, libffi, mpdecimal, liblzma, zlib, ...).
    [long] $PbsFullArchiveSize = 50005426,
    [string] $PbsFullArchiveSha256 = "f03ccd79ff289757a8a721faecb99ea318754df3141406ca0e83b1caf3af84d2",

    [string] $SqliteVersion = "3.54.1",
    [string] $SqliteAmalgamationPath = "2026/sqlite-amalgamation-3540100.zip",
    [long] $SqliteAmalgamationSize = 2990966,
    [string] $SqliteAmalgamationSha3_256 = "92281c86e2957f9b9305890f9ac04204caa7b677cc868dc326d942689df28e30",

    # Built-in limits a newer SQLite reports that the upstream (older) DLL predates;
    # anything else beyond the upstream compile options fails the build.
    [string[]] $NewSqliteDefaultOptions = @("MAX_SCHEMA=10000000"),

    [string] $ExpectedOpenSsl = "OpenSSL 3.5.9 29 Sep 2026",
    [string] $ExpectedPip = "26.2.2",

    [string] $VisualStudioInstallationVersion = "17.14.37824.6",
    [string] $VCToolsVersion = "14.44.35207",
    [string] $WindowsSdkVersion = "10.0.26100.0"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Stop-Build([string] $Message) { throw [InvalidOperationException]::new($Message) }

function Get-Sha256([string] $Path) {
    return (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash.ToLowerInvariant()
}

# Byte-for-byte the algorithm Build-PatchBlitz-UnifiedSetup.ps1 enforces on the extracted runtime.
function Get-StableRuntimeTreeIdentity([string] $Root) {
    $files = @(Get-ChildItem -LiteralPath $Root -Recurse -File -Force | Where-Object {
        $_.Extension -ne '.pyc' -and $_.FullName -notmatch '[\\/]__pycache__[\\/]'
    } | Sort-Object FullName)
    $entries = [Collections.Generic.List[string]]::new()
    [long]$totalBytes = 0
    foreach ($file in $files) {
        $relative = [IO.Path]::GetRelativePath($Root, $file.FullName).Replace('\', '/')
        $entries.Add(("{0}`t{1}`t{2}" -f $relative, $file.Length, (Get-Sha256 $file.FullName)))
        $totalBytes += $file.Length
    }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $entries))
    )).ToLowerInvariant()
    return [ordered]@{
        stable_file_count = $files.Count
        stable_total_bytes = $totalBytes
        stable_tree_sha256 = $digest
    }
}

function Get-VerifiedDownload([string] $Uri, [string] $Destination, [long] $Size) {
    if (-not (Test-Path -LiteralPath $Destination -PathType Leaf)) {
        $partial = "$Destination.part"
        Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        try {
            Invoke-WebRequest -UseBasicParsing -Uri $Uri -OutFile $partial -Headers @{ 'User-Agent' = 'PatchBlitz-python-runtime-build/1' }
            Move-Item -LiteralPath $partial -Destination $Destination -Force
        } finally {
            Remove-Item -LiteralPath $partial -Force -ErrorAction SilentlyContinue
        }
    }
    if ((Get-Item -LiteralPath $Destination).Length -ne $Size) { Stop-Build "Downloaded size differs from the pin: $Destination" }
    return $Destination
}

function Reset-Directory([string] $Path) {
    if (Test-Path -LiteralPath $Path) { Remove-Item -LiteralPath $Path -Recurse -Force }
    New-Item -ItemType Directory -Path $Path -Force | Out-Null
}

$CacheRoot = [IO.Path]::GetFullPath($CacheRoot).TrimEnd('\')
if (-not $OutputDirectory) { $OutputDirectory = Join-Path $CacheRoot "output" }
$OutputDirectory = [IO.Path]::GetFullPath($OutputDirectory).TrimEnd('\')
$downloadRoot = Join-Path $CacheRoot "downloads"
$workRoot = Join-Path $CacheRoot "work"
New-Item -ItemType Directory -Path $downloadRoot, $OutputDirectory -Force | Out-Null
Reset-Directory $workRoot

# 1. Upstream CPython (python-build-standalone install_only_stripped), pinned by size and SHA-256.
$pbsName = "cpython-$CPythonVersion+$PbsRelease-x86_64-pc-windows-msvc-install_only_stripped.tar.gz"
$pbsArchive = Get-VerifiedDownload `
    -Uri "https://github.com/astral-sh/python-build-standalone/releases/download/$PbsRelease/$([Uri]::EscapeDataString($pbsName))" `
    -Destination (Join-Path $downloadRoot $pbsName) -Size $PbsArchiveSize
if ((Get-Sha256 $pbsArchive) -cne $PbsArchiveSha256) { Stop-Build "python-build-standalone archive SHA-256 differs from the pin." }
& tar.exe -xf $pbsArchive -C $workRoot
if ($LASTEXITCODE -ne 0) { Stop-Build "Extraction of $pbsName failed." }
$runtime = Join-Path $workRoot "python"
$python = Join-Path $runtime "python.exe"
if (-not (Test-Path -LiteralPath $python -PathType Leaf)) { Stop-Build "Upstream archive does not have the expected python\python.exe layout." }

$pbsFullName = "cpython-$CPythonVersion+$PbsRelease-x86_64-pc-windows-msvc-pgo-full.tar.zst"
$pbsFullArchive = Get-VerifiedDownload `
    -Uri "https://github.com/astral-sh/python-build-standalone/releases/download/$PbsRelease/$([Uri]::EscapeDataString($pbsFullName))" `
    -Destination (Join-Path $downloadRoot $pbsFullName) -Size $PbsFullArchiveSize
if ((Get-Sha256 $pbsFullArchive) -cne $PbsFullArchiveSha256) { Stop-Build "python-build-standalone full archive SHA-256 differs from the pin." }
$licenseCopy = @'
import os, sys, tarfile
archive, destination = sys.argv[1], sys.argv[2]
os.makedirs(destination, exist_ok=True)
count = 0
with tarfile.open(archive, "r:zst") as tar:
    for member in tar.getmembers():
        name = member.name
        if not (member.isfile() and name.startswith("python/licenses/")):
            continue
        leaf = name.rsplit("/", 1)[-1]
        if not leaf or leaf != os.path.basename(leaf) or not leaf.startswith("LICENSE."):
            raise SystemExit(f"unexpected license entry: {name}")
        with tar.extractfile(member) as source, open(os.path.join(destination, leaf), "wb") as target:
            target.write(source.read())
        count += 1
if count == 0 or not os.path.exists(os.path.join(destination, "LICENSE.openssl-3.txt")):
    raise SystemExit("the upstream license set is missing or lacks OpenSSL")
print(f"licenses copied: {count}")
'@
& $python -I -B -c $licenseCopy $pbsFullArchive (Join-Path $runtime "licenses")
if ($LASTEXITCODE -ne 0) { Stop-Build "Copying upstream third-party license texts failed." }

$probeSqliteOptions ='import json,sqlite3;c=sqlite3.connect(":memory:");print(json.dumps(sorted(r[0] for r in c.execute("pragma compile_options") if not r[0].startswith("COMPILER="))))'
$upstreamOptions = (& $python -I -B -c $probeSqliteOptions | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Stop-Build "Upstream SQLite compile-option probe failed." }

# 2. Official SQLite amalgamation, pinned by size and the SHA3-256 sqlite.org publishes.
$sqliteZipName = Split-Path -Leaf $SqliteAmalgamationPath
$sqliteZip = Get-VerifiedDownload -Uri "https://sqlite.org/$SqliteAmalgamationPath" `
    -Destination (Join-Path $downloadRoot $sqliteZipName) -Size $SqliteAmalgamationSize
$sqliteSha3 = (& $python -I -B -c "import hashlib,sys;print(hashlib.sha3_256(open(sys.argv[1],'rb').read()).hexdigest())" $sqliteZip | Out-String).Trim()
if ($sqliteSha3 -cne $SqliteAmalgamationSha3_256) { Stop-Build "SQLite amalgamation SHA3-256 differs from the pin." }
$sqliteSource = Join-Path $workRoot "sqlite"
Expand-Archive -LiteralPath $sqliteZip -DestinationPath $sqliteSource -Force
$amalgamation = @(Get-ChildItem -LiteralPath $sqliteSource -Recurse -Filter "sqlite3.c" -File)
if ($amalgamation.Count -ne 1) { Stop-Build "SQLite amalgamation layout is unexpected." }
$amalgamationDir = $amalgamation[0].DirectoryName

# 3. Build sqlite3.dll with the exact feature set the upstream DLL reports, deterministically.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { Stop-Build "The pinned Visual Studio locator is required." }
$vsInstances = @(& $vswhere -all -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -format json | ConvertFrom-Json)
$vsMatches = @($vsInstances | Where-Object { $_.installationVersion -ceq $VisualStudioInstallationVersion })
if ($vsMatches.Count -ne 1) {
    Stop-Build "Exactly one Visual Studio installation at version $VisualStudioInstallationVersion is required."
}
$vsPath = [string]$vsMatches[0].installationPath
$vcvars = Join-Path $vsPath "VC\Auxiliary\Build\vcvars64.bat"
$clPath = Join-Path $vsPath "VC\Tools\MSVC\$VCToolsVersion\bin\Hostx64\x64\cl.exe"
$linkPath = Join-Path $vsPath "VC\Tools\MSVC\$VCToolsVersion\bin\Hostx64\x64\link.exe"
$rcPath = Join-Path ${env:ProgramFiles(x86)} "Windows Kits\10\bin\$WindowsSdkVersion\x64\rc.exe"
foreach ($requiredTool in @($vcvars, $clPath, $linkPath, $rcPath)) {
    if (-not (Test-Path -LiteralPath $requiredTool -PathType Leaf)) {
        Stop-Build "Pinned toolchain file is missing: $requiredTool"
    }
}
$parts = $SqliteVersion.Split('.')
$rc = @"
#include <winver.h>
VS_VERSION_INFO VERSIONINFO
 FILEVERSION $($parts[0]),$($parts[1]),$($parts[2]),0
 PRODUCTVERSION $($parts[0]),$($parts[1]),$($parts[2]),0
 FILEOS VOS_NT_WINDOWS32
 FILETYPE VFT_DLL
BEGIN
  BLOCK "StringFileInfo"
  BEGIN
    BLOCK "040904B0"
    BEGIN
      VALUE "FileDescription", "SQLite library\0"
      VALUE "FileVersion", "$SqliteVersion\0"
      VALUE "InternalName", "sqlite3\0"
      VALUE "OriginalFilename", "sqlite3.dll\0"
      VALUE "ProductName", "SQLite\0"
      VALUE "ProductVersion", "$SqliteVersion\0"
      VALUE "LegalCopyright", "Public domain\0"
    END
  END
  BLOCK "VarFileInfo"
  BEGIN
    VALUE "Translation", 0x409, 1200
  END
END
"@
Set-Content -LiteralPath (Join-Path $amalgamationDir "sqlite3.rc") -Value $rc -Encoding ascii
$defines = @(
    'SQLITE_API=__declspec(dllexport)', 'SQLITE_THREADSAFE=1', 'SQLITE_OMIT_AUTOINIT',
    'SQLITE_ENABLE_MATH_FUNCTIONS', 'SQLITE_ENABLE_FTS3', 'SQLITE_ENABLE_FTS3_PARENTHESIS',
    'SQLITE_ENABLE_FTS4', 'SQLITE_ENABLE_FTS5', 'SQLITE_ENABLE_RTREE', 'SQLITE_ENABLE_GEOPOLY',
    'SQLITE_ENABLE_DBSTAT_VTAB'
) | ForEach-Object { "/D`"$_`"" }
$buildCmd = @(
    "set `"PATH=$(Split-Path -Parent $vswhere);%PATH%`"",
    "call `"$vcvars`" -vcvars_ver=$VCToolsVersion -winsdk=$WindowsSdkVersion >nul",
    "if not `"!VCToolsVersion!`"==`"$VCToolsVersion`" exit /b 86",
    "if not `"!WindowsSDKVersion!`"==`"$WindowsSdkVersion\`" exit /b 87",
    "cd /d `"$amalgamationDir`"",
    "`"$rcPath`" /nologo /fo sqlite3.res sqlite3.rc",
    "`"$clPath`" /nologo /O2 /GL /MD /W0 /Brepro /Zc:inline /guard:cf $($defines -join ' ') sqlite3.c sqlite3.res /LD /Fe:sqlite3.dll /link /LTCG /Brepro /OPT:REF /OPT:ICF /DYNAMICBASE /NXCOMPAT /HIGHENTROPYVA /GUARD:CF"
) -join " && "
& cmd.exe /d /v:on /s /c $buildCmd
if ($LASTEXITCODE -ne 0) { Stop-Build "SQLite build failed." }
$builtSqlite = Join-Path $amalgamationDir "sqlite3.dll"
Copy-Item -LiteralPath $builtSqlite -Destination (Join-Path $runtime "DLLs\sqlite3.dll") -Force

# 4. Remove the Tcl/Tk GUI stack: the server and its tooling never import tkinter, turtle, or IDLE.
$guiPaths = @('tcl', 'Lib\tkinter', 'Lib\idlelib', 'Lib\turtledemo', 'Lib\turtle.py', 'DLLs\_tkinter.pyd') +
    @(Get-ChildItem -LiteralPath (Join-Path $runtime "DLLs") -File | Where-Object Name -Match '^(tcl|tk)\d[^\\/]*\.dll$' | ForEach-Object { "DLLs\$($_.Name)" })
foreach ($relative in $guiPaths) {
    $target = Join-Path $runtime $relative
    if (Test-Path -LiteralPath $target) { Remove-Item -LiteralPath $target -Recurse -Force }
}
Get-ChildItem -LiteralPath $runtime -Recurse -Directory -Force -Filter "__pycache__" | Remove-Item -Recurse -Force

# 5. Verify identity, SQLite feature parity, and the capabilities the platform relies on.
$identityJson = (& $python -I -B -c 'import json,pip,ssl,sqlite3,sys;print(json.dumps({"python":".".join(map(str,sys.version_info[:3])),"openssl":ssl.OPENSSL_VERSION,"sqlite":sqlite3.sqlite_version,"pip":pip.__version__}))' | Out-String).Trim()
if ($LASTEXITCODE -ne 0) { Stop-Build "Runtime identity probe failed." }
$identity = $identityJson | ConvertFrom-Json
if ($identity.python -cne $CPythonVersion -or $identity.openssl -cne $ExpectedOpenSsl -or
    $identity.sqlite -cne $SqliteVersion -or $identity.pip -cne $ExpectedPip) {
    Stop-Build "Built runtime identity is unexpected: $identityJson"
}
$builtOptions = (& $python -I -B -c $probeSqliteOptions | Out-String).Trim()
$upstreamSet = @($upstreamOptions | ConvertFrom-Json)
$builtSet = @($builtOptions | ConvertFrom-Json)
$missing = @($upstreamSet | Where-Object { $_ -cnotin $builtSet })
$extra = @($builtSet | Where-Object { $_ -cnotin $upstreamSet -and $_ -cnotin $NewSqliteDefaultOptions })
if ($missing.Count -or $extra.Count) {
    Stop-Build "Replacement SQLite compile options differ from upstream. Missing: $($missing -join ', ') Unexpected: $($extra -join ', ')"
}
$smoke = @'
import hashlib, json, sqlite3, ssl, sys, zlib, lzma, bz2, ctypes, ctypes.util, uuid, decimal, asyncio, concurrent.futures
c = sqlite3.connect(":memory:")
c.execute("create virtual table f using fts5(body)"); c.execute("insert into f values ('patch blitz runtime')")
assert c.execute("select count(*) from f where f match 'blitz'").fetchone()[0] == 1
c.execute("create virtual table r using rtree(id, x0, x1)")
assert abs(c.execute("select sqrt(16)").fetchone()[0] - 4.0) < 1e-9
assert c.execute("pragma integrity_check").fetchone()[0] == "ok"
ctx = ssl.create_default_context(); assert ctx.verify_mode == ssl.CERT_REQUIRED and ctx.check_hostname
assert ssl.HAS_TLSv1_3 and len(ctx.get_ca_certs()) >= 0
assert hashlib.sha3_256(b"").hexdigest().startswith("a7ffc6f8")
import importlib.util
assert importlib.util.find_spec("tkinter") is None, "the Tcl/Tk stack must not ship"
print("smoke ok")
'@
& $python -I -B -c $smoke
if ($LASTEXITCODE -ne 0) { Stop-Build "Runtime smoke test failed." }
Get-ChildItem -LiteralPath $runtime -Recurse -Directory -Force -Filter "__pycache__" | Remove-Item -Recurse -Force

# 6. Deterministic archive: sorted entries, fixed mtime/owner/mode, gzip without a timestamp.
$opensslShort = ($ExpectedOpenSsl -split ' ')[1]
$archiveName = "patchblitz-cpython-$CPythonVersion-openssl-$opensslShort-sqlite-$SqliteVersion-windows-x64.tar.gz"
$archivePath = Join-Path $OutputDirectory $archiveName
$packer = @'
import gzip, os, sys, tarfile
src, out = sys.argv[1], sys.argv[2]
base = os.path.dirname(src)
paths = []
for root, dirs, files in os.walk(src):
    dirs.sort()
    paths.append(root)
    paths.extend(os.path.join(root, f) for f in sorted(files))
def norm(info):
    info.mtime = 0; info.uid = info.gid = 0; info.uname = info.gname = ""
    info.mode = 0o755 if info.isdir() else 0o644
    return info
with open(out, "wb") as raw, gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0, compresslevel=9) as gz:
    with tarfile.open(fileobj=gz, mode="w", format=tarfile.PAX_FORMAT) as tar:
        for p in paths:
            tar.add(p, arcname=os.path.relpath(p, base).replace(os.sep, "/"), recursive=False, filter=norm)
'@
& $python -I -B -c $packer $runtime $archivePath
if ($LASTEXITCODE -ne 0) { Stop-Build "Archive creation failed." }
Get-ChildItem -LiteralPath $runtime -Recurse -Directory -Force -Filter "__pycache__" | Remove-Item -Recurse -Force

# 7. Re-extract the archive and measure it exactly as the setup builder will.
$verifyRoot = Join-Path $workRoot "verify"
Reset-Directory $verifyRoot
& tar.exe -xf $archivePath -C $verifyRoot
if ($LASTEXITCODE -ne 0) { Stop-Build "Re-extraction of $archiveName failed." }
$extractedRuntime = Join-Path $verifyRoot "python"
$tree = Get-StableRuntimeTreeIdentity -Root $extractedRuntime
$asset = [ordered]@{
    id = "python"
    version = $CPythonVersion
    archive_name = $archiveName
    archive_type = "tar.gz"
    size = (Get-Item -LiteralPath $archivePath).Length
    sha256 = Get-Sha256 $archivePath
    payload_directory = "runtime/python"
    runtime_identity = [ordered]@{
        python = $identity.python
        openssl = $identity.openssl
        sqlite = $identity.sqlite
        pip = $identity.pip
        python_exe_sha256 = Get-Sha256 (Join-Path $extractedRuntime "python.exe")
        stable_file_count = $tree.stable_file_count
        stable_total_bytes = $tree.stable_total_bytes
        stable_tree_sha256 = $tree.stable_tree_sha256
    }
    build_inputs = [ordered]@{
        build_recipe_sha256 = Get-Sha256 $PSCommandPath
        python_build_standalone_release = $PbsRelease
        python_build_standalone_archive = $pbsName
        python_build_standalone_sha256 = $PbsArchiveSha256
        license_source_archive = $pbsFullName
        license_source_sha256 = $PbsFullArchiveSha256
        sqlite_amalgamation = "https://sqlite.org/$SqliteAmalgamationPath"
        sqlite_amalgamation_sha3_256 = $SqliteAmalgamationSha3_256
        sqlite3_dll_sha256 = Get-Sha256 $builtSqlite
    }
    toolchain = [ordered]@{
        visual_studio_installation_version = $VisualStudioInstallationVersion
        vc_tools_version = $VCToolsVersion
        windows_sdk_version = $WindowsSdkVersion
        cl_file_version = (Get-Item -LiteralPath $clPath).VersionInfo.FileVersion
        cl_sha256 = Get-Sha256 $clPath
        link_sha256 = Get-Sha256 $linkPath
        rc_sha256 = Get-Sha256 $rcPath
        powershell_version = $PSVersionTable.PSVersion.ToString()
        operating_system = [Environment]::OSVersion.VersionString
    }
}
$receiptPath = "$archivePath.json"
$asset | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $receiptPath -Encoding utf8NoBOM
Write-Host "Archive: $archivePath"
Write-Host "Lock entry: $receiptPath"
$asset | ConvertTo-Json -Depth 5
