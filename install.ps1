<#
.SYNOPSIS
    Install a prebuilt zellij (no-web build) for Windows from the kruseio/zellij GitHub releases.

.DESCRIPTION
    Downloads zellij-no-web-x86_64-pc-windows-msvc.zip, verifies the SHA-256 checksum of
    zellij.exe and installs it. If zellij is already on your PATH (an official build or this
    fork), that zellij.exe is replaced, upgrading or downgrading it to the selected version.
    Otherwise it goes to ~\.local\bin, which is added to the user PATH.
    On Linux and macOS use install.sh instead.

.EXAMPLE
    powershell -ExecutionPolicy Bypass -c "irm https://raw.githubusercontent.com/kruseio/zellij/HEAD/install.ps1 | iex"

.EXAMPLE
    & ([scriptblock]::Create((irm https://raw.githubusercontent.com/kruseio/zellij/HEAD/install.ps1))) -Version v0.44.4
#>
param(
    # Release tag to install, e.g. v0.44.4. Defaults to $env:ZELLIJ_VERSION, else 'latest'.
    [string]$Version = $(if ($env:ZELLIJ_VERSION) { $env:ZELLIJ_VERSION } else { 'latest' }),
    # Install directory. Defaults to $env:ZELLIJ_INSTALL_DIR, else the directory of the
    # zellij.exe already on PATH, else ~\.local\bin.
    [string]$BinDir = $env:ZELLIJ_INSTALL_DIR,
    # GitHub owner/repo to download from. Defaults to $env:ZELLIJ_REPO, else kruseio/zellij.
    [string]$Repo = $(if ($env:ZELLIJ_REPO) { $env:ZELLIJ_REPO } else { 'kruseio/zellij' }),
    # Do not add BinDir to the user PATH. Also set by $env:ZELLIJ_NO_MODIFY_PATH = '1'.
    [switch]$NoModifyPath = ($env:ZELLIJ_NO_MODIFY_PATH -eq '1')
)

# Everything lives in functions and errors are thrown rather than `exit`ed, so
# running under `irm | iex` never closes the caller's PowerShell session or
# changes its preference variables.

function Test-SameDir([string]$A, [string]$B) {
    [Environment]::ExpandEnvironmentVariables($A).TrimEnd('\') -ieq [Environment]::ExpandEnvironmentVariables($B).TrimEnd('\')
}

function Test-InPathList([string]$List, [string]$Dir) {
    [bool]($List -split ';' | Where-Object { $_ -and (Test-SameDir $_ $Dir) })
}

function Add-ToUserPath([string]$Dir) {
    if (Test-InPathList ([Environment]::GetEnvironmentVariable('Path', 'Machine')) $Dir) { return $false }
    # Edit the raw registry value so %VARIABLE% references in the user PATH stay unexpanded.
    $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
    try {
        $current = [string]$key.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
        if (Test-InPathList $current $Dir) { return $false }
        $entries = @($current -split ';' | Where-Object { $_ })
        $key.SetValue('Path', (($entries + $Dir) -join ';'), [Microsoft.Win32.RegistryValueKind]::ExpandString)
    } finally {
        $key.Dispose()
    }
    # Setting a user variable through .NET broadcasts WM_SETTINGCHANGE, so newly
    # started terminals see the updated PATH.
    [Environment]::SetEnvironmentVariable('ZELLIJ_INSTALL_PATH_REFRESH', '1', 'User')
    [Environment]::SetEnvironmentVariable('ZELLIJ_INSTALL_PATH_REFRESH', $null, 'User')
    return $true
}

# The package manager or installer an existing zellij.exe came from, if recognizable.
function Get-PackageOwner([string]$Path) {
    switch -Wildcard ($Path) {
        '*\scoop\*' { return 'Scoop (scoop uninstall zellij)' }
        '*\WinGet\*' { return 'WinGet (winget uninstall zellij)' }
        '*\.cargo\bin\*' { return 'cargo (cargo uninstall zellij)' }
        '*\Program Files*' { return 'an installer (uninstall Zellij in Settings > Apps)' }
    }
    return $null
}

function Install-Zellij([string]$Version, [string]$BinDir, [string]$Repo, [bool]$ModifyPath) {
    $ErrorActionPreference = 'Stop'
    # Invoke-WebRequest is very slow with its progress bar in Windows PowerShell.
    $ProgressPreference = 'SilentlyContinue'

    if ($PSVersionTable.PSVersion.Major -ge 6 -and -not $IsWindows) {
        throw 'install.ps1 is for Windows; on Linux and macOS use install.sh'
    }

    $arch = if ($env:PROCESSOR_ARCHITEW6432) { $env:PROCESSOR_ARCHITEW6432 } else { $env:PROCESSOR_ARCHITECTURE }
    if ($arch -ne 'AMD64') {
        throw "unsupported architecture: $arch (Windows builds exist for x86_64 only)"
    }
    $target = 'x86_64-pc-windows-msvc'
    $asset = "zellij-no-web-$target.zip"
    $checksum = "zellij-no-web-$target.sha256sum"

    if ($Version -eq 'latest') {
        $base = "https://github.com/$Repo/releases/latest/download"
    } else {
        if (-not $Version.StartsWith('v')) { $Version = "v$Version" }
        $base = "https://github.com/$Repo/releases/download/$Version"
    }

    # Without an explicit -BinDir, replace the zellij already on PATH (whether an official
    # build or this fork), so the selected version is the one that runs.
    if (-not $BinDir) {
        $existing = Get-Command zellij -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $BinDir = if ($existing) { Split-Path -Parent $existing.Source } else { Join-Path $HOME '.local\bin' }
    }
    $BinDir = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($BinDir).TrimEnd('\')
    $dest = Join-Path $BinDir 'zellij.exe'

    $current = $null
    $owner = $null
    if (Test-Path -LiteralPath $dest) {
        $current = try { & $dest --version 2>$null } catch { $null }
        if (-not $current) { $current = 'zellij (unknown version)' }
        $owner = Get-PackageOwner $dest
    }

    # Windows PowerShell 5.1 does not always enable TLS 1.2 by default.
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $tmp = Join-Path ([IO.Path]::GetTempPath()) "zellij-install-$([guid]::NewGuid())"
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        Write-Host "zellij-install: downloading $asset ($Version) from github.com/$Repo"
        try {
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$asset" -OutFile (Join-Path $tmp $asset)
            Invoke-WebRequest -UseBasicParsing -Uri "$base/$checksum" -OutFile (Join-Path $tmp $checksum)
        } catch {
            throw "download failed from $base (does release '$Version' exist and include ${asset}?): $_"
        }

        $extract = Join-Path $tmp 'extract'
        Expand-Archive -LiteralPath (Join-Path $tmp $asset) -DestinationPath $extract -Force
        $exe = Join-Path $extract 'zellij.exe'
        if (-not (Test-Path -LiteralPath $exe -PathType Leaf)) { throw "$asset does not contain zellij.exe" }

        # The published checksum covers zellij.exe itself, not the zip.
        $line = [string](Get-Content -LiteralPath (Join-Path $tmp $checksum) -TotalCount 1)
        $expected = ($line.Trim() -split '\s+')[0].ToLowerInvariant()
        if ($expected -notmatch '^[0-9a-f]{64}$') { throw "malformed checksum file $checksum" }
        $actual = (Get-FileHash -Algorithm SHA256 -LiteralPath $exe).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "checksum mismatch for zellij.exe: expected $expected, got $actual" }
        Write-Host "zellij-install: verified sha256 $actual"

        if ($current) { Write-Host "zellij-install: replacing $current at $dest" }
        # A running zellij.exe cannot be overwritten, but it can be renamed out of the way.
        # Renaming also replaces a symlink (e.g. WinGet's) rather than the file it points to.
        $old = "$dest.zellij-install-old"
        $moved = $false
        try {
            New-Item -ItemType Directory -Force -Path $BinDir | Out-Null
            Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue
            if (Test-Path -LiteralPath $dest) {
                Move-Item -LiteralPath $dest -Destination $old -Force
                $moved = $true
            }
            Copy-Item -LiteralPath $exe -Destination $dest
        } catch {
            if ($moved -and -not (Test-Path -LiteralPath $dest)) {
                Move-Item -LiteralPath $old -Destination $dest -Force -ErrorAction SilentlyContinue
            }
            throw "cannot write $dest ($($_.Exception.Message)). Run PowerShell as administrator, uninstall the existing zellij, or pass -BinDir / set ZELLIJ_INSTALL_DIR to install elsewhere."
        }
        if ($moved) { Remove-Item -LiteralPath $old -Force -ErrorAction SilentlyContinue }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $installed = try { & $dest --version 2>$null } catch { $null }
    if (-not $installed) { $installed = 'zellij' }
    if ($current) {
        Write-Host "zellij-install: replaced $current with $installed at $dest"
    } else {
        Write-Host "zellij-install: installed $installed to $dest"
    }
    if ($owner) {
        Write-Warning "the zellij you replaced came from $owner; it may put its own version back when it upgrades. To switch for good, uninstall it there and rerun this script."
    }

    $inSessionPath = Test-InPathList $env:Path $BinDir
    if ($ModifyPath) {
        if (Add-ToUserPath $BinDir) {
            Write-Host "zellij-install: added $BinDir to your user PATH (open a new terminal to pick it up)"
        }
        if (-not $inSessionPath) { $env:Path = "$env:Path;$BinDir" }
    } elseif (-not $inSessionPath) {
        Write-Warning "$BinDir is not on your PATH"
    }

    $found = Get-Command zellij -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($found -and -not (Test-SameDir $found.Source $dest)) {
        Write-Warning "'zellij' on your PATH resolves to $($found.Source), which takes precedence over $dest"
    }
}

Install-Zellij -Version $Version -BinDir $BinDir -Repo $Repo -ModifyPath (-not $NoModifyPath)
