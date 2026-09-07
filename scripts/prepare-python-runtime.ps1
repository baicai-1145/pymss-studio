param(
    [ValidateSet("cuda", "default", "rocm", "mps", "mlx")]
    [string]$Variant = "cuda",
    [string]$Python = "python",
    [string]$RuntimeDir = "python-runtime",
    # Optional overrides. When omitted, the requirement and index URL are read from
    # python/runtime-manifest.json — the single source of truth shared with the
    # in-app installer (worker_bootstrap.py). Hardcoded copies here would drift.
    [string]$TorchVersion = "",
    [string]$TorchIndexUrl = "",
    [switch]$Minimal,
    [string]$InitialBackend = "",
    [string]$RuntimeEnvsDir = "",
    [switch]$RewriteRuntimeEnvConfigs,
    [switch]$TemplateRuntimeEnvConfigs
)

$ErrorActionPreference = "Stop"
$root = Resolve-Path (Join-Path $PSScriptRoot "..")
$runtime = Join-Path $root $RuntimeDir
$effectiveRuntimeEnvsDir = if ($RuntimeEnvsDir) { $RuntimeEnvsDir } else { Join-Path $runtime "runtime-envs" }
$manifestPath = Join-Path (Join-Path $root "python") "runtime-manifest.json"

function Invoke-NativeChecked {
    param(
        [Parameter(Mandatory = $true)]
        [string]$FilePath,
        [Parameter(Mandatory = $true)]
        [object[]]$Arguments
    )

    & $FilePath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$FilePath failed with exit code $LASTEXITCODE"
    }
}

function Invoke-Pip {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Python,
        [Parameter(Mandatory = $true)]
        [object[]]$Arguments
    )

    Write-Host "pip install $($Arguments -join ' ')"
    Invoke-NativeChecked -FilePath $Python -Arguments (@('-m', 'pip', 'install', '--no-cache-dir') + $Arguments)
}

function Get-Manifest {
    if (!(Test-Path -LiteralPath $manifestPath)) {
        throw "runtime manifest not found at $manifestPath"
    }
    return Get-Content -Raw $manifestPath | ConvertFrom-Json
}

function Resolve-BackendName {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Variant,
        [string]$InitialBackend
    )

    if ($InitialBackend) {
        return $InitialBackend
    }
    # The mps/mlx build variants correspond to the manifest's mlx backend:
    # a CPU torch build plus the mlx extra.
    $mapping = @{ cuda = "cuda"; default = "cpu"; rocm = "rocm"; mps = "mlx"; mlx = "mlx" }
    return $mapping[$Variant]
}

function Get-TorchIndexUrl {
    param(
        [string]$Override,
        [object]$TorchSpec
    )

    if (-not [string]::IsNullOrWhiteSpace($Override)) {
        return $Override
    }
    if ($TorchSpec -and $TorchSpec.PSObject.Properties['indexUrl']) {
        return [string]$TorchSpec.indexUrl
    }
    return ""
}

function Install-BackendPackages {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Python,
        [Parameter(Mandatory = $true)]
        [object]$Manifest,
        [Parameter(Mandatory = $true)]
        [string]$Backend,
        [string]$TorchVersionOverride,
        [string]$TorchIndexUrlOverride
    )

    $spec = $Manifest.backends.$Backend
    if (!$spec) {
        throw "backend '$Backend' is not defined in the runtime manifest"
    }
    $torch = $spec.torch

    if ($torch.PSObject.Properties['rocmRequirements'] -and $torch.rocmRequirements) {
        # ROCm wheels are version-pinned URLs from AMD; the manifest is authoritative.
        Invoke-Pip -Python $Python -Arguments @($torch.rocmRequirements)
        Invoke-Pip -Python $Python -Arguments (@('--no-deps') + @($torch.requirements))
    } else {
        $torchRequirement = if (-not [string]::IsNullOrWhiteSpace($TorchVersionOverride)) {
            "torch==$TorchVersionOverride"
        } elseif ($torch.PSObject.Properties['requirement'] -and $torch.requirement) {
            [string]$torch.requirement
        } else {
            "torch"
        }
        $indexUrl = Get-TorchIndexUrl -Override $TorchIndexUrlOverride -TorchSpec $torch
        if ($indexUrl) {
            Invoke-Pip -Python $Python -Arguments @($torchRequirement, '--index-url', $indexUrl)
        } else {
            Invoke-Pip -Python $Python -Arguments @($torchRequirement)
        }
    }

    # Common dependencies come from the manifest (pymss/pymss-core excluded; they are
    # installed below with dependency resolution). Requirement strings carry the same
    # version bounds the in-app installer uses, so build-time and user-side installs
    # resolve identically.
    $commonPackages = @(
        $Manifest.common.PSObject.Properties |
            Where-Object { $_.Name -notin @("pymss", "pymss-core") } |
            ForEach-Object { [string]$_.Value }
    )
    if ($commonPackages.Count -gt 0) {
        Invoke-Pip -Python $Python -Arguments (@('--only-binary=:all:', '--prefer-binary') + $commonPackages)
    }

    if ($spec.PSObject.Properties['extras'] -and $spec.extras) {
        foreach ($extra in $spec.extras) {
            Invoke-Pip -Python $Python -Arguments @([string]$extra)
        }
    }

    # pymss/pymss-core install with full dependency resolution (a --no-deps install silently
    # drops dependencies the core package gains between releases), constrained to the torch
    # build installed above so pip can never swap the multi-GB accelerator package.
    $pymssRequirement = [string]$Manifest.common.pymss
    $pymssCoreRequirement = [string]$Manifest.common.'pymss-core'
    $torchVersionOutput = & $Python -c "from importlib.metadata import version; print(version('torch'))"
    if ($LASTEXITCODE -ne 0) {
        throw "failed to read the installed torch version for the pymss constraint"
    }
    $torchVersion = ([string]($torchVersionOutput | Select-Object -Last 1)).Trim()
    if (!$torchVersion) {
        throw "empty torch version while preparing the pymss constraint"
    }
    $constraintsFile = Join-Path ([System.IO.Path]::GetTempPath()) "pymss-build-constraints-$PID.txt"
    [System.IO.File]::WriteAllText($constraintsFile, "torch==$torchVersion`n", [System.Text.UTF8Encoding]::new($false))
    try {
        Invoke-Pip -Python $Python -Arguments @('--upgrade', '--only-binary=:all:', '--prefer-binary', '--constraint', $constraintsFile, $pymssRequirement, $pymssCoreRequirement)
    } finally {
        Remove-Item -LiteralPath $constraintsFile -Force -ErrorAction SilentlyContinue
    }
}

function Rewrite-WindowsRuntimeEnvConfigs {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvsDir,
        [Parameter(Mandatory = $true)]
        [string]$PythonRuntimeDir,
        [switch]$Template
    )

    $resolvedEnvsDir = Resolve-Path -LiteralPath $EnvsDir
    $resolvedRuntimeDir = if ($Template) { "__PYMSS_STUDIO_PYTHON_RUNTIME__" } else { (Resolve-Path -LiteralPath $PythonRuntimeDir).Path }
    $pythonExe = Join-Path $resolvedRuntimeDir "python.exe"
    if (!$Template -and !(Test-Path -LiteralPath $pythonExe)) {
        throw "python.exe not found at $pythonExe"
    }

    Get-ChildItem -LiteralPath $resolvedEnvsDir -Directory | ForEach-Object {
        $cfg = Join-Path $_.FullName "pyvenv.cfg"
        if (Test-Path -LiteralPath $cfg) {
            $envDir = if ($Template) { "__PYMSS_STUDIO_RUNTIME_ENV__" } else { $_.FullName }
            $content = @(
                "home = $resolvedRuntimeDir"
                "include-system-site-packages = false"
                "executable = $pythonExe"
                "command = $pythonExe -m venv $envDir"
                ""
            ) -join "`r`n"

            [System.IO.File]::WriteAllText($cfg, $content, [System.Text.UTF8Encoding]::new($false))
            if ($Template) {
                Write-Host "Templated $cfg"
            } else {
                Write-Host "Rewrote $cfg"
            }
        }
    }
}

function Remove-RocmOffloadArchLauncher {
    param(
        [Parameter(Mandatory = $true)]
        [string]$EnvironmentDir
    )

    # ROCm's pip console-script wrapper embeds the build interpreter path. The SDK can use the
    # relocatable native tool shipped under _rocm_sdk_core when this wrapper is absent from Scripts.
    $launcher = Join-Path $EnvironmentDir "Scripts\offload-arch.exe"
    $sitePackages = Join-Path $EnvironmentDir "Lib\site-packages"
    $sdkPackage = Get-ChildItem -LiteralPath $sitePackages -Directory -Filter "_rocm_sdk_core*" | Select-Object -First 1
    if (!$sdkPackage) {
        throw "ROCm SDK core package was not found in $sitePackages"
    }
    $nativeTools = Join-Path $sdkPackage.FullName "lib\llvm\bin"
    $runtimeBin = Join-Path $sdkPackage.FullName "bin"
    if (!(Test-Path -LiteralPath (Join-Path $nativeTools "offload-arch.exe"))) {
        throw "ROCm native offload-arch tool was not found in $nativeTools"
    }
    if (!(Test-Path -LiteralPath $runtimeBin)) {
        throw "ROCm runtime DLL directory was not found in $runtimeBin"
    }
    if (Test-Path -LiteralPath $launcher) {
        Remove-Item -LiteralPath $launcher -Force
        Write-Host "Removed relocatability-breaking ROCm launcher $launcher"
    }
    return @($nativeTools, $runtimeBin)
}

if ($RewriteRuntimeEnvConfigs -or $TemplateRuntimeEnvConfigs) {
    Rewrite-WindowsRuntimeEnvConfigs -EnvsDir $RuntimeEnvsDir -PythonRuntimeDir $RuntimeDir -Template:$TemplateRuntimeEnvConfigs
    exit 0
}

$manifest = Get-Manifest

# ---------------------------------------------------------------------------
# InitialBackend mode: create minimal bootstrap + initial backend env
# ---------------------------------------------------------------------------
if ($InitialBackend) {
    Write-Host "=== InitialBackend mode: base runtime + $InitialBackend environment ==="

    # Step 1: Create minimal bootstrap runtime
    if (Test-Path -LiteralPath $runtime) {
        Remove-Item -LiteralPath $runtime -Recurse -Force
    }
    $pythonExe = (Get-Command $Python).Source
    $pythonHome = Split-Path -Parent $pythonExe
    Write-Host "Copying bootstrap Python from $pythonHome"
    robocopy $pythonHome $runtime /E /XD __pycache__ /XF *.pyc | Out-Host
    if ($LASTEXITCODE -gt 7) { throw "robocopy failed with exit code $LASTEXITCODE" }
    $global:LASTEXITCODE = 0
    $runtimePython = Join-Path $runtime "python.exe"
    if (!(Test-Path -LiteralPath $runtimePython)) {
        throw "python.exe was not copied to $runtime"
    }
    $sitePackages = Join-Path $runtime "Lib\site-packages"
    if (Test-Path -LiteralPath $sitePackages) {
        Remove-Item -LiteralPath $sitePackages -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
    Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'ensurepip', '--upgrade')
    Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel')
    Write-Host "Bootstrap runtime created at $runtime"

    # Step 2: Create venv for the initial backend
    $envsDir = if ([System.IO.Path]::IsPathRooted($effectiveRuntimeEnvsDir)) { $effectiveRuntimeEnvsDir } else { Join-Path $root $effectiveRuntimeEnvsDir }
    $envDir = Join-Path $envsDir $InitialBackend
    if (Test-Path -LiteralPath $envDir) {
        Remove-Item -LiteralPath $envDir -Recurse -Force
    }
    Write-Host "Creating venv at $envDir"
    Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'venv', $envDir)
    $envPython = Join-Path $envDir "Scripts\python.exe"
    if (!(Test-Path -LiteralPath $envPython)) {
        throw "venv python.exe was not created at $envPython"
    }
    & (Join-Path $PSScriptRoot "prune-python-runtime.ps1") -RuntimeDir $runtime -KeepVenv
    Invoke-NativeChecked -FilePath $envPython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel')

    # Step 3: Install packages for the backend (requirements resolved from the manifest)
    Install-BackendPackages -Python $envPython -Manifest $manifest -Backend $InitialBackend -TorchVersionOverride $TorchVersion -TorchIndexUrlOverride $TorchIndexUrl
    $rocmToolDirs = if ($InitialBackend -eq "rocm") { Remove-RocmOffloadArchLauncher -EnvironmentDir $envDir } else { @() }
    & (Join-Path $PSScriptRoot "prune-python-runtime.ps1") -RuntimeDir $envDir -KeepScripts
    Invoke-NativeChecked -FilePath $envPython -Arguments @('-m', 'pip', '--version')

    # Step 4: Verify the environment
    $previousDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
    $previousPath = $env:PATH
    try {
        $env:PYTHONDONTWRITEBYTECODE = "1"
        if ($rocmToolDirs.Count -gt 0) {
            $env:PATH = ($rocmToolDirs + $previousPath) -join ";"
        }
        Invoke-NativeChecked -FilePath $envPython -Arguments @('-c', "import importlib.util, pymss, pymss.graph, torch, librosa, av, yaml, tqdm; print('pymss', getattr(pymss, '__version__', 'unknown'), pymss.__file__); print('torch', torch.__version__, 'cuda', torch.version.cuda, 'cuda_available', torch.cuda.is_available()); print('librosa', librosa.__version__); print('av', av.__version__); print('mlx', importlib.util.find_spec('mlx') is not None)")

        # Step 5: Read manifest version and write state files
        $manifestVersion = $manifest.manifestVersion

        # Probe torch info from the env
        $probeOutput = @(Invoke-NativeChecked -FilePath $envPython -Arguments @('-c', "import torch, json, platform; print(json.dumps({'torchVersion': torch.__version__, 'torchBackend': 'rocm' if getattr(torch.version, 'hip', None) else 'cuda' if getattr(torch.version, 'cuda', None) else 'cpu', 'acceleratorAvailable': torch.cuda.is_available(), 'pythonVersion': platform.python_version()}))"))
    } finally {
        if ($null -eq $previousDontWriteBytecode) {
            Remove-Item Env:\PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
        } else {
            $env:PYTHONDONTWRITEBYTECODE = $previousDontWriteBytecode
        }
        $env:PATH = $previousPath
    }
    $probeJson = $probeOutput |
        ForEach-Object { $_.ToString().Trim() } |
        Where-Object { $_ -match '^\s*\{.*\}\s*$' } |
        Select-Object -Last 1
    if ([string]::IsNullOrWhiteSpace($probeJson)) {
        throw "Runtime probe did not produce a JSON result"
    }
    $probed = $probeJson | ConvertFrom-Json
    $now = (Get-Date).ToUniversalTime().ToString("yyyy-MM-ddTHH:mm:ssZ")

    $envState = @{
        backend = $InitialBackend
        manifestVersion = $manifestVersion
        installedAt = $now
        pythonVersion = $probed.pythonVersion
        torchVersion = $probed.torchVersion
        torchBackend = $probed.torchBackend
        acceleratorAvailable = $probed.acceleratorAvailable
    } | ConvertTo-Json -Depth 4
    $envStatePath = Join-Path $envDir "pymss-runtime-state.json"
    Set-Content -Path $envStatePath -Value $envState -Encoding UTF8
    Write-Host "Wrote environment state to $envStatePath"

    # Use relative pythonPath (relative to runtime-envs dir) so it works on any machine
    $relativePythonPath = Join-Path $InitialBackend "Scripts\python.exe"
    $activeState = @{
        backend = $InitialBackend
        manifestVersion = $manifestVersion
        installedAt = $now
        pythonVersion = $probed.pythonVersion
        torchVersion = $probed.torchVersion
        torchBackend = $probed.torchBackend
        acceleratorAvailable = $probed.acceleratorAvailable
        pythonPath = $relativePythonPath
        activatedAt = $now
    } | ConvertTo-Json -Depth 4
    $activeRuntimePath = Join-Path $envsDir "active-runtime.json"
    Set-Content -Path $activeRuntimePath -Value $activeState -Encoding UTF8
    Write-Host "Wrote active runtime to $activeRuntimePath"

    & (Join-Path $PSScriptRoot "prune-python-runtime.ps1") -RuntimeDir $envDir -KeepScripts
    Invoke-NativeChecked -FilePath $envPython -Arguments @('-m', 'pip', '--version')
    Write-Host "=== InitialBackend complete: $InitialBackend environment ready ==="
    exit 0
}

# ---------------------------------------------------------------------------
# Standard mode (existing behavior)
# ---------------------------------------------------------------------------
if (Test-Path -LiteralPath $runtime) {
    Remove-Item -LiteralPath $runtime -Recurse -Force
}

$pythonExe = (Get-Command $Python).Source
$pythonHome = Split-Path -Parent $pythonExe
Write-Host "Copying portable Python runtime from $pythonHome"
robocopy $pythonHome $runtime /E /XD __pycache__ /XF *.pyc | Out-Host
if ($LASTEXITCODE -gt 7) { throw "robocopy failed with exit code $LASTEXITCODE" }
$global:LASTEXITCODE = 0

$runtimePython = Join-Path $runtime "python.exe"
if (!(Test-Path -LiteralPath $runtimePython)) {
    throw "python.exe was not copied to $runtime"
}

Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'pip', 'install', '--upgrade', 'pip', 'setuptools', 'wheel')
if ($Minimal) {
    $sitePackages = Join-Path $runtime "Lib\site-packages"
    if (Test-Path -LiteralPath $sitePackages) {
        Remove-Item -LiteralPath $sitePackages -Recurse -Force
    }
    New-Item -ItemType Directory -Force -Path $sitePackages | Out-Null
    Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'ensurepip', '--upgrade')
    Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'pip', '--version')
    Write-Host "Prepared minimal Python runtime without inference dependencies"
    exit 0
}
Install-BackendPackages -Python $runtimePython -Manifest $manifest -Backend (Resolve-BackendName -Variant $Variant) -TorchVersionOverride $TorchVersion -TorchIndexUrlOverride $TorchIndexUrl

& (Join-Path $PSScriptRoot "prune-python-runtime.ps1") -RuntimeDir $runtime -KeepVenv
Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'pip', '--version')
$previousDontWriteBytecode = $env:PYTHONDONTWRITEBYTECODE
$env:PYTHONDONTWRITEBYTECODE = "1"
Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-c', "import importlib.util, pymss, pymss.graph, torch, librosa, av, yaml, tqdm; print('pymss', getattr(pymss, '__version__', 'unknown'), pymss.__file__); print('torch', torch.__version__, 'cuda', torch.version.cuda, 'cuda_available', torch.cuda.is_available()); print('librosa', librosa.__version__); print('av', av.__version__); print('mlx', importlib.util.find_spec('mlx') is not None)")
if ($null -eq $previousDontWriteBytecode) {
    Remove-Item Env:\PYTHONDONTWRITEBYTECODE -ErrorAction SilentlyContinue
} else {
    $env:PYTHONDONTWRITEBYTECODE = $previousDontWriteBytecode
}
& (Join-Path $PSScriptRoot "prune-python-runtime.ps1") -RuntimeDir $runtime -KeepVenv
Invoke-NativeChecked -FilePath $runtimePython -Arguments @('-m', 'pip', '--version')
