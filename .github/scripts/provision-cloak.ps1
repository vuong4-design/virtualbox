[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$VM,

    [ValidateNotNullOrEmpty()]
    [string]$VBoxManage = 'VBoxManage',

    [switch]$Force,

    [switch]$Verify,

    [string]$SeedHex
)

$ErrorActionPreference = 'Stop'

function Get-Sha256Hex {
    param(
        [Parameter(Mandatory = $true)]
        [byte[]]$Data
    )

    $sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $digest = $sha.ComputeHash($Data)
    }
    finally {
        $sha.Dispose()
    }
    return ([BitConverter]::ToString($digest)).Replace('-', '')
}

$vboxManageCommand = Get-Command $VBoxManage -ErrorAction SilentlyContinue
if (-not $vboxManageCommand) {
    throw "VBoxManage not found: $VBoxManage"
}

$info = & $VBoxManage showvminfo $VM --machinereadable 2>&1
if ($LASTEXITCODE -ne 0) {
    throw "Failed to query VM '$VM': $info"
}

$stateLine = $info | Where-Object { $_ -match '^VMState="([^"]+)"$' } | Select-Object -First 1
if (-not $stateLine) {
    throw "VMState not found for '$VM'"
}
$state = [regex]::Match($stateLine, '^VMState="([^"]+)"$').Groups[1].Value
if ($state -ne 'poweroff') {
    throw "VM '$VM' must be powered off before provisioning (state: $state)"
}

$key = 'VBoxInternal/Cloak/Seed'
$hashKey = 'VBoxInternal/Cloak/SeedHash'
$existingRaw = & $VBoxManage getextradata $VM $key 2>&1
$existing = $null
if ($LASTEXITCODE -eq 0 -and $existingRaw -match '^Value: (.+)$') {
    $existing = $Matches[1]
}

if ($Verify) {
    $verifyHashRaw = & $VBoxManage getextradata $VM $hashKey 2>&1
    $storedHash = $null
    if ($LASTEXITCODE -eq 0 -and $verifyHashRaw -match '^Value: ([0-9a-fA-F]{64})$') {
        $storedHash = $Matches[1].ToUpperInvariant()
    }
    if (-not $existing) {
        throw "Cloak seed is not provisioned for '$VM'"
    }
    if ($existing -notmatch '^string:([0-9a-fA-F]{64})$') {
        throw "Cloak seed value is malformed for '$VM'"
    }
    $verifyHex = $Matches[1].ToLowerInvariant()
    $verifyBytes = New-Object byte[] 32
    for ($i = 0; $i -lt $verifyBytes.Length; $i++) {
        $verifyBytes[$i] = [System.Convert]::ToByte($verifyHex.Substring($i * 2, 2), 16)
    }
    try {
        $computedHash = Get-Sha256Hex -Data $verifyBytes
    }
    finally {
        [System.Array]::Clear($verifyBytes, 0, $verifyBytes.Length)
    }
    if (-not $storedHash) {
        throw "Cloak seed hash is missing for '$VM'; re-provision with -Force"
    }
    if ($storedHash -ne $computedHash) {
        throw "Cloak seed hash mismatch for '$VM'; re-provision with -Force"
    }
    Write-Output "Cloak seed verified for '$VM' (sha256=$($computedHash.Substring(0, 16))..., stored hash matches)."
    exit 0
}

if ($existing -and -not $Force) {
    throw "Cloak seed already provisioned for '$VM'; use -Force to re-seed"
}

if ($SeedHex) {
    if ($SeedHex -notmatch '^[0-9a-fA-F]{64}$') {
        throw 'SeedHex must contain exactly 64 hexadecimal characters'
    }
    $hex = $SeedHex.ToLowerInvariant()
    $bytes = New-Object byte[] 32
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        $bytes[$i] = [System.Convert]::ToByte($hex.Substring($i * 2, 2), 16)
    }
}
else {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try {
        $rng.GetBytes($bytes)
    }
    finally {
        $rng.Dispose()
    }
    $hex = -join ($bytes | ForEach-Object { $_.ToString('x2') })
}

$seedHash = $null
try {
    $seedHash = Get-Sha256Hex -Data $bytes
}
finally {
    [System.Array]::Clear($bytes, 0, $bytes.Length)
}
if (-not $seedHash) {
    throw 'Failed to hash cloak seed'
}

& $VBoxManage setextradata $VM $key ("string:" + $hex)
if ($LASTEXITCODE -ne 0) {
    throw "Failed to provision cloak seed for '$VM'"
}

& $VBoxManage setextradata $VM $hashKey $seedHash
if ($LASTEXITCODE -ne 0) {
    throw "Failed to provision cloak seed hash for '$VM'"
}

$readBackRaw = & $VBoxManage getextradata $VM $key 2>&1
if ($LASTEXITCODE -ne 0 -or $readBackRaw -notmatch '^Value: string:([0-9a-fA-F]{64})$') {
    throw "Failed to read back cloak seed for '$VM'"
}
if ($Matches[1].ToLowerInvariant() -ne $hex) {
    throw "Cloak seed readback mismatch for '$VM'"
}

$readBackHashRaw = & $VBoxManage getextradata $VM $hashKey 2>&1
if ($LASTEXITCODE -ne 0 -or $readBackHashRaw -notmatch '^Value: ([0-9a-fA-F]{64})$') {
    throw "Failed to read back cloak seed hash for '$VM'"
}
if ($Matches[1].ToUpperInvariant() -ne $seedHash) {
    throw "Cloak seed hash readback mismatch for '$VM'"
}

Write-Output "Cloak seed and seed hash provisioned for '$VM'."
