<#
.SYNOPSIS
Installs zigsaw for the current user, upgrades it, or removes it.

.DESCRIPTION
Downloads a release of zigsaw from GitHub, checks it against the release's
SHA256SUMS, puts zigsaw.exe, its two shim programs and its relay in
%LOCALAPPDATA%\zigsaw\bin, where zigsaw also puts the commands of the apps it
installs, and adds that directory to the user's PATH. No administrator is
needed. Run it again to upgrade: programs that are running are moved aside,
and installed apps' commands, shortcuts and file associations are written
again by the new zigsaw (zigsaw repair).

    irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1 | iex

With parameters:

    & ([scriptblock]::Create((irm https://github.com/zigsaw-io/zigsaw/releases/latest/download/install.ps1))) -Version 0.19.0

.PARAMETER Version
The release to install, such as 0.19.0. The latest by default. Also
$env:ZIGSAW_VERSION.

.PARAMETER Dir
Where to put zigsaw. %LOCALAPPDATA%\zigsaw\bin by default. Also
$env:ZIGSAW_INSTALL_DIR.

.PARAMETER From
A directory or URL that has zigsaw-x86_64-windows.zip and SHA256SUMS, instead
of a release on GitHub. Also $env:ZIGSAW_INSTALL_FROM.

.PARAMETER NoPath
Leave the user's PATH as it is. Also $env:ZIGSAW_INSTALL_NO_PATH.

.PARAMETER Uninstall
Remove zigsaw and its PATH entry. Apps have to be removed first, with
zigsaw rm; the store's other files, such as downloads and apps' data, stay.
#>
param(
    [string]$Version = $env:ZIGSAW_VERSION,
    [string]$Dir = $env:ZIGSAW_INSTALL_DIR,
    [string]$From = $env:ZIGSAW_INSTALL_FROM,
    [switch]$NoPath,
    [switch]$Uninstall
)

# In a scope of its own: piped to iex, the script runs in the caller's session,
# whose preferences are theirs.
& {
    param([string]$Version, [string]$Dir, [string]$From, [bool]$NoPath, [bool]$Uninstall)
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue'

    $programs = 'zigsaw.exe', 'zigsaw-shim.exe', 'zigsaw-shimw.exe', 'zigsaw-relay.exe'
    $archive = 'zigsaw-x86_64-windows.zip'
    # The user's environment variables. Tests name another key.
    $envKey = if ($env:ZIGSAW_INSTALL_ENV_KEY) { $env:ZIGSAW_INSTALL_ENV_KEY } else { 'Environment' }

    if (-not $Dir) { $Dir = Join-Path $env:LOCALAPPDATA 'zigsaw\bin' }
    $Dir = [IO.Path]::GetFullPath($Dir).TrimEnd('\')

    function Same-Dir([string]$entry) {
        $expanded = [Environment]::ExpandEnvironmentVariables($entry.Trim().Trim('"')).TrimEnd('\')
        return $expanded -ieq $Dir
    }

    # Adds $Dir to the user's PATH, or removes it. The value is read and
    # written as it is stored: it usually refers to other variables
    # (%USERPROFILE%), which [Environment]::SetEnvironmentVariable would
    # replace by their values for good.
    function Set-UserPath([bool]$present) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey($envKey)
        try {
            $old = [string]$key.GetValue('Path', '', 'DoNotExpandEnvironmentNames')
            $kind = if ($key.GetValueNames() -contains 'Path') { $key.GetValueKind('Path') } else { [Microsoft.Win32.RegistryValueKind]::ExpandString }
            $entries = @($old -split ';' | Where-Object { $_ -ne '' })
            $others = @($entries | Where-Object { -not (Same-Dir $_) })
            if ($present -and $others.Count -ne $entries.Count) { return $false }
            if (-not $present -and $others.Count -eq $entries.Count) { return $false }
            if ($present) { $others += $Dir }
            $key.SetValue('Path', ($others -join ';'), $kind)
        } finally { $key.Close() }
        if ($envKey -eq 'Environment') {
            # Tells running programs, Explorer first, that the environment
            # changed: setting any user variable through .NET broadcasts it.
            [Environment]::SetEnvironmentVariable('ZIGSAW_INSTALL_NOTIFY', $null, 'User')
        }
        return $true
    }

    # Deletes a program, or moves it aside if it's running: Windows lets a
    # running program be renamed, not deleted. A later install deletes it.
    function Clear-Program([string]$path) {
        if (-not (Test-Path -LiteralPath $path)) { return }
        try { Remove-Item -LiteralPath $path -Force }
        catch { Rename-Item -LiteralPath $path -NewName ((Split-Path -Leaf $path) + '.old-' + [Guid]::NewGuid().ToString('N').Substring(0, 8)) }
    }

    function Remove-Leftovers {
        foreach ($name in $programs) {
            Get-ChildItem -LiteralPath $Dir -Filter "$name.old-*" -ErrorAction SilentlyContinue |
                ForEach-Object { Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue }
        }
    }

    if ($Uninstall) {
        $zigsaw = Join-Path $Dir 'zigsaw.exe'
        if (Test-Path -LiteralPath $zigsaw) {
            # A header line, then a line per app.
            $apps = @(& $zigsaw list | Select-Object -Skip 1 | ForEach-Object { ($_ -split '\s+')[0] } | Where-Object { $_ })
            if ($apps.Count -gt 0) {
                throw "These apps are still installed: $($apps -join ', '). Remove each with 'zigsaw rm <id>' first: zigsaw undoes what it changed for them, which deleting its files wouldn't."
            }
        }
        foreach ($name in $programs) {
            $path = Join-Path $Dir $name
            if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
        }
        Remove-Leftovers
        if (-not $NoPath -and (Set-UserPath $false)) { Write-Host "Removed $Dir from your PATH." }
        $store = if ($env:ZIGSAW_HOME) { $env:ZIGSAW_HOME } else { Join-Path $env:LOCALAPPDATA 'zigsaw' }
        Write-Host "zigsaw is removed from $Dir. Its store, with downloads and apps' data, is $store; delete that too if you don't want them."
        return
    }

    if (-not [Environment]::Is64BitOperatingSystem) { throw 'zigsaw needs 64-bit Windows.' }
    if (-not $From) {
        $From = if ($Version) { "https://github.com/zigsaw-io/zigsaw/releases/download/v$($Version.TrimStart('v'))" }
        else { 'https://github.com/zigsaw-io/zigsaw/releases/latest/download' }
    }

    $tmp = Join-Path ([IO.Path]::GetTempPath()) ('zigsaw-install-' + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $tmp | Out-Null
    try {
        foreach ($name in $archive, 'SHA256SUMS') {
            $dest = Join-Path $tmp $name
            if ($From -match '^https?://') {
                # Windows PowerShell 5.1 doesn't offer TLS 1.2 by itself everywhere.
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                Invoke-WebRequest -UseBasicParsing -Uri "$($From.TrimEnd('/'))/$name" -OutFile $dest
            } else {
                Copy-Item -LiteralPath (Join-Path $From $name) -Destination $dest
            }
        }

        # Before anything is changed.
        $want = Get-Content -LiteralPath (Join-Path $tmp 'SHA256SUMS') |
            Where-Object { $_ -match "^([0-9a-fA-F]{64})\s+\*?$([regex]::Escape($archive))\s*$" } |
            ForEach-Object { $Matches[1].ToLower() } | Select-Object -First 1
        if (-not $want) { throw "SHA256SUMS from $From doesn't list $archive." }
        $got = (Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $tmp $archive)).Hash.ToLower()
        if ($got -ne $want) { throw "$archive from $From isn't the file its SHA256SUMS lists: expected $want, got $got. Nothing was installed." }

        $unpacked = Join-Path $tmp 'unpacked'
        Expand-Archive -LiteralPath (Join-Path $tmp $archive) -DestinationPath $unpacked
        foreach ($name in $programs) {
            if (-not (Test-Path -LiteralPath (Join-Path $unpacked $name))) { throw "$archive has no $name. Nothing was installed." }
        }

        New-Item -ItemType Directory -Path $Dir -Force | Out-Null
        Remove-Leftovers
        foreach ($name in $programs) {
            Clear-Program (Join-Path $Dir $name)
            Copy-Item -LiteralPath (Join-Path $unpacked $name) -Destination (Join-Path $Dir $name)
        }
    } finally {
        Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
    }

    $zigsaw = Join-Path $Dir 'zigsaw.exe'
    $installed = & $zigsaw version
    Write-Host "Installed $installed in $Dir."

    # Apps installed by an earlier zigsaw have its shims, which name its path.
    $store = if ($env:ZIGSAW_HOME) { $env:ZIGSAW_HOME } else { Join-Path $env:LOCALAPPDATA 'zigsaw' }
    if (Test-Path (Join-Path $store 'refs\*.json')) {
        & $zigsaw repair
        if ($LASTEXITCODE -ne 0) { Write-Warning "Some apps' commands are still those of the zigsaw before. Close the apps and run 'zigsaw repair'." }
    }

    if (-not $NoPath) {
        if (Set-UserPath $true) { Write-Host "Added $Dir to your PATH. Terminals opened from now on have it." }
        if (-not (@($env:Path -split ';') | Where-Object { $_ -ne '' -and (Same-Dir $_) })) { $env:Path = "$($env:Path.TrimEnd(';'));$Dir" }
    }
    Write-Host "Try: zigsaw pull org.nodejs.node"
} $Version $Dir $From ($NoPath -or [bool]$env:ZIGSAW_INSTALL_NO_PATH) ([bool]$Uninstall)
