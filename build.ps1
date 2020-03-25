Param (
    [string] $build_path = "$PSScriptRoot\win_builds", # Build Path
    [string] $webrtc_head = "3987",                    # WebRTC branch, see https://chromiumdash.appspot.com/branches
    [ValidateSet('x86','x64','both')] 
    [string] $target_cpu = "x86",                      # The target cpu for compilation. Default is 'x86'. Values can be 'x86','x64','both'
    [ValidateSet('Debug','Release','All')] 
    [string] $config = "Release",                      # Build configuration. Default is 'Release'. Values can be 'Debug', 'Release', 'All'.
    [switch] $express = $false                         # Express build mode. Skip repo sync and dependency checks, just compile.
)

$checkout_path = "$(Get-Location)\webrtc"       # Checkout path

$do_x86 = $false
$do_x64 = $false
if ($target_cpu -eq 'x86') {
    $do_x86 = $true
} elseif ($target_cpu -eq 'x64') {
    $do_x64 = $true
} else {
    $do_x86 = $true
    $do_x64 = $true
}

$do_debug = $false
$do_release = $false
if ($config -eq 'Debug') {
    $do_debug = $true
} elseif ($config -eq 'Release') {
    $do_release = $true
} else {
    $do_debug = $true
    $do_release = $true
}

Write-Output "Checkout path: $checkout_path"
Write-Output "Build Path: $build_path"
Write-Output "WebRTC branch: $webrtc_head"
Write-Output "Target CPU(s): $(if ($do_x86) { 'x86' }) $(if ($do_x64) { 'x64' })"
Write-Output "Config(s): $(if ($do_debug) { 'Debug' }) $(if ($do_release) { 'Release' })"
Write-Output "Express build mode: $express"

$do_checkout = !$express # Checks Depot Tools, checks out webrtc repository; skip if you have this part ready and you are debugging
$do_patch = !$express # Patch webrtc checkout, or otheriwse it is assumed that you have a changes in progress that you are debugging

if(($do_checkout -eq $true) -and ($do_patch -eq $false)) {
    throw "You cannot skip patching if you are checking out, it is expected that patches are a part of the build in any case.";
}

# TODO: Rename cmdlets using approved verb names, see https://docs.microsoft.com/en-us/powershell/scripting/developer/cmdlet/approved-verbs-for-windows-powershell-commands?view=powershell-7

# WARN: webrtc repo is pretty deep and effective file names are long; you are interested in using as short base path as possible

function Depot-Tools-Installed {
    if (Get-Command "gclient" -ErrorAction SilentlyContinue) {
        return $True
    }
    return $False
}

function Apply-Patch {
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Name
    )
    $diff = Start-Process "git" -ArgumentList "apply $Name" -PassThru -Wait -NoNewWindow
    if ($diff.ExitCode -ne 0) {
        throw "Failed to apply diff $Name"
    }
    Write-Output "Applied $Name"
}

function Build-WebRTC {
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Target,
        [Parameter(Mandatory = $true, Position = 1)]
        [bool] $IsDebug
    )

    $is_debug = If ($IsDebug) { "true" } Else { "false" }
    $build_name = If ($IsDebug) { "Debug" } Else { "Release" }
    $output = "$build_path\$Target\$build_name"
    $symbol_level = If ($IsDebug) { 2 } Else { 0 }
    $arguments = "use_rtti=true is_debug=$is_debug target_cpu=""""$Target"""" symbol_level=$symbol_level rtc_enable_sctp=true rtc_include_tests=false"
    $gn = Start-Process "gn" -ArgumentList "gen $output --args=""$arguments""" -PassThru -Wait -NoNewWindow
    if ($gn.ExitCode -ne 0) {
        throw "Failed to generate build manifest for $output"
    }
    $ninja = Start-Process "ninja" -ArgumentList "-C $output" -PassThru -Wait -NoNewWindow
    if ($ninja.ExitCode -ne 0) {
        throw "Failed to build WebRTC for $output"
    }
}

function Copy-Libs {
    Param
    (
        [Parameter(Mandatory = $true, Position = 0)]
        [string] $Target,
        [Parameter(Mandatory = $true, Position = 1)]
        [bool] $IsDebug
    )
    $build_name = If ($IsDebug) { "Debug" } Else { "Release" }
    $library_location = "$build_path\$Target\$build_name"
    $output = "$PSScriptRoot\lib\$Target\$build_name"
    if (Test-Path $output) {
        Remove-Item -Path $output -Force -Recurse
    }
    New-Item -ItemType Directory -Force -Path ($output); Get-ChildItem -Recurse ($library_location) -Include ("webrtc.lib") | Copy-Item -Destination ($output)
}

function Copy-Includes {
    $includes_path = "$PSScriptRoot\include"
    if (Test-Path $includes_path) {
        Write-Output "Cleaning up old includes..."
        # if exists: empty contents and reuse the directory itself
        Get-ChildItem $includes_path -Recurse | Remove-Item -Recurse -Force
    }
    else {
        New-Item $includes_path -ItemType Directory -Force 
    }
    Write-Output "Copying Includes"
    xcopy /s "$(Get-Location)\*.h" "$includes_path" /Q
    # NOTE: We keep third_party because we need its third_party\abseil-cpp\absl at the very least
    # Remove-Item -Path "$includes_path\third_party" -Force -Recurse
}

if($do_checkout) {

    if ((Depot-Tools-Installed) -eq $false) {
        $download_path = "$(Get-Location)/depot_tools"
        $zip_path = Join-Path -Path $download_path -ChildPath "depot_tools.zip"
        New-Item -ItemType Directory -Path $download_path -Force | Out-Null
        Write-Output "Downloading depot tools to $zip_path..."
        (new-object System.Net.WebClient).DownloadFile('https://storage.googleapis.com/chrome-infra/depot_tools.zip', $zip_path);
        Write-Output "Extracting depot tools to $download_path..."
        Expand-Archive $zip_path -DestinationPath $download_path -Force
        Write-Output "Deleting $zip_path..."
        Remove-Item -Path $zip_path -Force -ErrorAction Ignore
        Write-Output $download_path
        $Env:Path += ";$(Get-Location)\depot_tools" # With pre-existing Depot Tools it is assumed path is OK; also it is recommended to have this path at the head of the list
    }

    if (!$express) {
        if (Test-Path $checkout_path) {
            Write-Output "Cleaning up last checkout..."
            Remove-Item -LiteralPath $checkout_path -Force -Recurse
            Write-Output "Done."
        }

        New-Item -ItemType Directory -Path $checkout_path
        Set-Location -Path $checkout_path
        Write-Output "Fetching WebRTC"

        $fetch_process = Start-Process "fetch" -ArgumentList "--nohooks webrtc" -PassThru -Wait -NoNewWindow
        if ($fetch_process.ExitCode -ne 0) {
            throw "Failed to fetch WebRTC."
        }

        Set-Location -Path "$checkout_path\src"
        Write-Output "Checking out remote header $webrtc_head..."

        $checkout = Start-Process "git" -ArgumentList "checkout -b $webrtc_head refs/remotes/branch-heads/$webrtc_head" -PassThru -Wait -NoNewWindow
        if ($checkout.ExitCode -ne 0) {
            throw "Failed to checkout remote WebRTC branch"
        }
    }
}

Write-Output "Syncing repo..."
Set-Location -Path "$checkout_path\src"

$Env:DEPOT_TOOLS_WIN_TOOLCHAIN=0 # Use of locally installed Visual Studio
$python_lastchange = Start-Process "python" -ArgumentList "build/util/lastchange.py -o build/util/LASTCHANGE" -PassThru -Wait -NoNewWindow
if ($python_lastchange.ExitCode -ne 0) {
    throw "Failed to generate lastchange"
}

if($do_patch) {
    $gclient = Start-Process "gclient" -ArgumentList "sync" -PassThru -Wait -NoNewWindow
    if ($gclient.ExitCode -ne 0) {
        throw "Failed to sync WebRTC code. $($gclient.ExitCode)"
    }
    #Write-Output "Applying webrtc patches..."
    #Set-Location -Path "$checkout_path\src"
    #Apply-Patch -Name "$PSScriptRoot\patches\webrtc-src\optimize.patch"
    #Apply-Patch -Name "$PSScriptRoot\patches\webrtc-src\usrsctp.patch"
    Write-Output "Applying webrtc-src-build patches..."
    Set-Location -Path "$checkout_path\src\build"
    Apply-Patch -Name "$PSScriptRoot\patches\webrtc-src-build\0001-Spitfire-C-CLI-build-customization.patch"
    Apply-Patch -Name "$PSScriptRoot\patches\webrtc-src-build\0002-Do-not-use-custom-in-tree-libc-for-Windows-clang-bui.patch"
    Write-Output "Done patching."
} else {
    $gclient = Start-Process "gclient" -ArgumentList "runhooks" -PassThru -Wait -NoNewWindow
    if ($gclient.ExitCode -ne 0) {
        throw "Failed to run gclient runhooks. $($gclient.ExitCode)"
    }
}

Set-Location -Path "$checkout_path\src"

if (Test-Path $build_path) {
    Write-Output "Cleaning up old builds..."
    Remove-Item -LiteralPath $build_path -Force -Recurse
    Write-Output "Done."
}

if ($do_x64) {
    if ($do_debug) {
        Write-Output "Building x64 Debug"
        Build-WebRTC -Target "x64" -IsDebug $true
        Write-Output "Copying x64 Debug Libraries"
        Copy-Libs -Target "x64" -IsDebug $true
    }
    if ($do_release) {
        Write-Output "Building x64 Release"
        Build-WebRTC -Target "x64" -IsDebug $false
        Write-Output "Copying x64 Releas Libraries"
        Copy-Libs -Target "x64" -IsDebug $false
    }
}

if ($do_x86) {
    if ($do_debug) {
        Write-Output "Building x86 Debug"
        Build-WebRTC -Target "x86" -IsDebug $true
        Write-Output "Copying x86 Debug Libraries"
        Copy-Libs -Target "x86" -IsDebug $true
    }
    if ($do_release) {
        Write-Output "Building x86 Release"
        Build-WebRTC -Target "x86" -IsDebug $false
        Write-Output "Copying x86 Release Libraries"
        Copy-Libs -Target "x86" -IsDebug $false
    }
}

Copy-Includes

Write-Output "WebRTC Built!"
