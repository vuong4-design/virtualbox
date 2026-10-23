<#
.SYNOPSIS
    So sánh fingerprint identity theo schema cho T3 (thay cho mask hex).

.DESCRIPTION
    Comparator của kế hoạch §4.7.4.1: parse JSON collector thành field có kiểu,
    canonicalize (thứ tự key, lowercase hex, bỏ padding cuối chuỗi), so semantic
    equality và in diff theo từng field. Không mask giá trị identity.

    Field volatile (timestamp, uptime, session id, địa chỉ) được so riêng và
    KHÔNG làm fail kết quả; mọi khác biệt khác đều fail. Danh sách volatile nằm
    trong script (có review) và có thể thêm bằng -VolatileField.

    Exit code: 0 = khớp, 1 = lệch identity, 2 = lỗi tham số/đầu vào.

.PARAMETER Reference
    Đường dẫn JSON collector tham chiếu (boot 1).

.PARAMETER Candidate
    Một hoặc nhiều JSON collector cần so (boot 2, boot 3, build cloak).

.PARAMETER ReportPath
    Ghi report JSON. Mặc định report chỉ chứa hash rút gọn của giá trị, không
    chứa giá trị thô (an toàn khi upload artifact).

.PARAMETER IncludeValues
    Hiện giá trị canonical trong console/report. Chỉ dùng khi debug cục bộ.

.PARAMETER VolatileField
    Thêm tên field volatile (khớp chính xác, không phân biệt hoa thường).

.PARAMETER SelfTest
    Chạy bộ test dương/âm dựng sẵn của comparator rồi thoát.

.EXAMPLE
    .\compare-identity.ps1 -Reference boot1.json -Candidate boot2.json, boot3.json

.EXAMPLE
    .\compare-identity.ps1 -SelfTest
#>
[CmdletBinding()]
param(
    [string] $Reference,

    [string[]] $Candidate,

    [string] $ReportPath,

    [switch] $IncludeValues,

    [string[]] $VolatileField,

    [switch] $SelfTest
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$script:CloakVolatileFields = @(
    'timestamp',
    'uptime',
    'sessionid',
    'session',
    'address',
    'ramaddress',
    'loadaddress'
)

$script:CloakArrayKeyFields = @('bdf', 'leaf', 'index', 'slot', 'name', 'id', 'key', 'table', 'device')

$script:CloakSelfTestFailed = $false

function Get-CloakScalarCanonical {
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return $null
    }
    if ($Value -is [string]) {
        $Text = $Value.TrimEnd([char] 0, ' ')
        if ($Text -match '^(?:0[xX])?[0-9a-fA-F]+$') {
            return $Text.ToLowerInvariant()
        }
        return $Text
    }
    if ($Value -is [bool]) {
        if ($Value) { return 'true' }
        return 'false'
    }
    if ($Value -is [int] -or $Value -is [long] -or $Value -is [double] -or $Value -is [decimal] -or $Value -is [single]) {
        return [System.Convert]::ToString($Value, [System.Globalization.CultureInfo]::InvariantCulture)
    }
    return $null
}

function Test-CloakComposite {
    param([AllowNull()] $Value)

    if ($null -eq $Value) {
        return $false
    }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        return $true
    }
    if ($Value -is [System.Collections.IList]) {
        return $true
    }
    return $false
}

function ConvertTo-CloakJsonText {
    param([AllowNull()] [string] $Text)

    if ($null -eq $Text) {
        return 'null'
    }
    $Builder = New-Object System.Text.StringBuilder
    [void] $Builder.Append('"')
    foreach ($Character in $Text.ToCharArray()) {
        $Code = [int] $Character
        if ($Character -eq '\') { [void] $Builder.Append('\\') }
        elseif ($Character -eq '"') { [void] $Builder.Append('\"') }
        elseif ($Code -lt 0x20) { [void] $Builder.AppendFormat('\u{0:X4}', $Code) }
        else { [void] $Builder.Append($Character) }
    }
    [void] $Builder.Append('"')
    return $Builder.ToString()
}

function Get-CloakCanonicalForm {
    param([AllowNull()] $Value)

    if (Test-CloakComposite $Value) {
        if ($Value -is [System.Management.Automation.PSCustomObject]) {
            $Builder = New-Object System.Text.StringBuilder
            [void] $Builder.Append('{')
            $Names = @($Value.PSObject.Properties | Where-Object { $_.MemberType -eq 'NoteProperty' } | ForEach-Object { $_.Name })
            [array]::Sort($Names, [System.StringComparer]::Ordinal)
            $First = $true
            foreach ($Name in $Names) {
                if (-not $First) { [void] $Builder.Append(',') }
                $First = $false
                [void] $Builder.Append((ConvertTo-CloakJsonText $Name))
                [void] $Builder.Append(':')
                [void] $Builder.Append((Get-CloakCanonicalForm $Value.$Name))
            }
            [void] $Builder.Append('}')
            return $Builder.ToString()
        }

        $Items = @()
        foreach ($Item in $Value) {
            $Items += (Get-CloakCanonicalForm $Item)
        }
        [array]::Sort($Items, [System.StringComparer]::Ordinal)
        return '[' + ($Items -join ',') + ']'
    }

    return ConvertTo-CloakJsonText (Get-CloakScalarCanonical $Value)
}

function Get-CloakValueHash {
    param([string] $Canonical)

    $Sha = [System.Security.Cryptography.SHA256]::Create()
    try {
        $Digest = $Sha.ComputeHash([System.Text.Encoding]::UTF8.GetBytes($Canonical))
    }
    finally {
        $Sha.Dispose()
    }
    $Hex = ([BitConverter]::ToString($Digest)).Replace('-', '').ToLowerInvariant()
    return 'sha256:' + $Hex.Substring(0, 16)
}

function Add-CloakDifference {
    param(
        [System.Collections.Generic.List[object]] $Differences,
        [System.Collections.Generic.List[object]] $VolatileDifferences,
        [string] $Path,
        [string] $Kind,
        [bool] $Volatile,
        [AllowNull()] [string] $ReferenceCanonical,
        [AllowNull()] [string] $CandidateCanonical,
        [bool] $IncludeValues
    )

    $ReferenceHash = '<missing>'
    if ($null -ne $ReferenceCanonical) { $ReferenceHash = Get-CloakValueHash $ReferenceCanonical }
    $CandidateHash = '<missing>'
    if ($null -ne $CandidateCanonical) { $CandidateHash = Get-CloakValueHash $CandidateCanonical }

    $Entry = [pscustomobject] @{
        Path           = $Path
        Kind           = $Kind
        Volatile       = $Volatile
        ReferenceHash  = $ReferenceHash
        CandidateHash  = $CandidateHash
        ReferenceValue = $null
        CandidateValue = $null
    }
    if ($IncludeValues) {
        $Entry.ReferenceValue = $ReferenceCanonical
        $Entry.CandidateValue = $CandidateCanonical
    }

    if ($Volatile) {
        [void] $VolatileDifferences.Add($Entry)
    }
    else {
        [void] $Differences.Add($Entry)
    }
}

function Compare-CloakNode {
    param(
        [AllowNull()] $Reference,
        [AllowNull()] $Candidate,
        [string] $Path,
        [bool] $IsVolatile,
        [System.Collections.Generic.List[object]] $Differences,
        [System.Collections.Generic.List[object]] $VolatileDifferences,
        [string[]] $VolatileFields,
        [bool] $IncludeValues,
        [int] $Depth
    )

    if ($Depth -gt 64) {
        throw "document nesting is too deep at $Path"
    }

    $ReferenceComposite = Test-CloakComposite $Reference
    $CandidateComposite = Test-CloakComposite $Candidate
    if ($ReferenceComposite -ne $CandidateComposite) {
        Add-CloakDifference $Differences $VolatileDifferences $Path 'type' $IsVolatile `
            (Get-CloakCanonicalForm $Reference) (Get-CloakCanonicalForm $Candidate) $IncludeValues
        return
    }

    if (-not $ReferenceComposite) {
        $ReferenceCanonical = Get-CloakScalarCanonical $Reference
        $CandidateCanonical = Get-CloakScalarCanonical $Candidate
        if ($ReferenceCanonical -ne $CandidateCanonical) {
            Add-CloakDifference $Differences $VolatileDifferences $Path 'value' $IsVolatile `
                $ReferenceCanonical $CandidateCanonical $IncludeValues
        }
        return
    }

    if (-not ($Reference -is [System.Management.Automation.PSCustomObject])) {
        Compare-CloakArray $Reference $Candidate $Path $IsVolatile $Differences $VolatileDifferences $VolatileFields $IncludeValues $Depth
        return
    }

    $Names = @{}
    foreach ($Property in $Reference.PSObject.Properties) { $Names[$Property.Name] = $true }
    foreach ($Property in $Candidate.PSObject.Properties) { $Names[$Property.Name] = $true }
    $SortedNames = @($Names.Keys)
    [array]::Sort($SortedNames, [System.StringComparer]::Ordinal)

    foreach ($Name in $SortedNames) {
        $ChildVolatile = $IsVolatile -or ($VolatileFields -contains $Name.ToLowerInvariant())
        $ChildPath = $Path + '.' + $Name
        $ReferenceHas = $null -ne $Reference.PSObject.Properties[$Name]
        $CandidateHas = $null -ne $Candidate.PSObject.Properties[$Name]
        if ($ReferenceHas -and $CandidateHas) {
            Compare-CloakNode $Reference.$Name $Candidate.$Name $ChildPath $ChildVolatile `
                $Differences $VolatileDifferences $VolatileFields $IncludeValues ($Depth + 1)
        }
        elseif ($CandidateHas) {
            Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'added' $ChildVolatile `
                $null (Get-CloakCanonicalForm $Candidate.$Name) $IncludeValues
        }
        else {
            Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'removed' $ChildVolatile `
                (Get-CloakCanonicalForm $Reference.$Name) $null $IncludeValues
        }
    }
}

function Get-CloakArrayPairingKey {
    param([AllowNull()] $Value)

    if (-not (Test-CloakComposite $Value)) { return $null }
    if ($Value -is [System.Management.Automation.PSCustomObject]) {
        foreach ($FieldName in $script:CloakArrayKeyFields) {
            $Property = $Value.PSObject.Properties[$FieldName]
            if ($Property -and -not (Test-CloakComposite $Property.Value)) {
                $Canonical = Get-CloakScalarCanonical $Property.Value
                if ($null -ne $Canonical -and $Canonical -ne '') { return $Canonical }
            }
        }
    }
    return $null
}

function Compare-CloakArray {
    param(
        [System.Collections.IList] $Reference,
        [System.Collections.IList] $Candidate,
        [string] $Path,
        [bool] $IsVolatile,
        [System.Collections.Generic.List[object]] $Differences,
        [System.Collections.Generic.List[object]] $VolatileDifferences,
        [string[]] $VolatileFields,
        [bool] $IncludeValues,
        [int] $Depth
    )

    $CanPair = $true
    $ReferenceByKey = @{}
    $CandidateByKey = @{}
    foreach ($Element in $Reference) {
        $Key = Get-CloakArrayPairingKey $Element
        if ($null -eq $Key -or $ReferenceByKey.ContainsKey($Key)) { $CanPair = $false; break }
        $ReferenceByKey[$Key] = $Element
    }
    if ($CanPair) {
        foreach ($Element in $Candidate) {
            $Key = Get-CloakArrayPairingKey $Element
            if ($null -eq $Key -or $CandidateByKey.ContainsKey($Key)) { $CanPair = $false; break }
            $CandidateByKey[$Key] = $Element
        }
    }

    if ($CanPair) {
        $Keys = @{}
        foreach ($Key in $ReferenceByKey.Keys) { $Keys[$Key] = $true }
        foreach ($Key in $CandidateByKey.Keys) { $Keys[$Key] = $true }
        $SortedKeys = @($Keys.Keys)
        [array]::Sort($SortedKeys, [System.StringComparer]::Ordinal)
        foreach ($Key in $SortedKeys) {
            $ChildPath = $Path + '[' + $Key + ']'
            if ($ReferenceByKey.ContainsKey($Key) -and $CandidateByKey.ContainsKey($Key)) {
                Compare-CloakNode $ReferenceByKey[$Key] $CandidateByKey[$Key] $ChildPath $IsVolatile `
                    $Differences $VolatileDifferences $VolatileFields $IncludeValues ($Depth + 1)
            }
            elseif ($CandidateByKey.ContainsKey($Key)) {
                Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'added' $IsVolatile `
                    $null (Get-CloakCanonicalForm $CandidateByKey[$Key]) $IncludeValues
            }
            else {
                Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'removed' $IsVolatile `
                    (Get-CloakCanonicalForm $ReferenceByKey[$Key]) $null $IncludeValues
            }
        }
        return
    }

    $ReferenceCounts = @{}
    foreach ($Element in $Reference) {
        $Canonical = Get-CloakCanonicalForm $Element
        if ($ReferenceCounts.ContainsKey($Canonical)) { $ReferenceCounts[$Canonical]++ } else { $ReferenceCounts[$Canonical] = 1 }
    }
    $CandidateCounts = @{}
    foreach ($Element in $Candidate) {
        $Canonical = Get-CloakCanonicalForm $Element
        if ($CandidateCounts.ContainsKey($Canonical)) { $CandidateCounts[$Canonical]++ } else { $CandidateCounts[$Canonical] = 1 }
    }

    $AllCounts = @{}
    foreach ($Key in $ReferenceCounts.Keys) { $AllCounts[$Key] = $true }
    foreach ($Key in $CandidateCounts.Keys) { $AllCounts[$Key] = $true }
    $SortedCounts = @($AllCounts.Keys)
    [array]::Sort($SortedCounts, [System.StringComparer]::Ordinal)
    foreach ($Key in $SortedCounts) {
        $ReferenceCount = 0
        if ($ReferenceCounts.ContainsKey($Key)) { $ReferenceCount = $ReferenceCounts[$Key] }
        $CandidateCount = 0
        if ($CandidateCounts.ContainsKey($Key)) { $CandidateCount = $CandidateCounts[$Key] }
        $Delta = $ReferenceCount - $CandidateCount
        for ($Index = 0; $Index -lt [Math]::Abs($Delta); $Index++) {
            $ChildPath = $Path + '[]'
            if ($Delta -gt 0) {
                Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'removed' $IsVolatile $Key $null $IncludeValues
            }
            else {
                Add-CloakDifference $Differences $VolatileDifferences $ChildPath 'added' $IsVolatile $null $Key $IncludeValues
            }
        }
    }
}

function Get-CloakComparisonResult {
    param(
        $Reference,
        $Candidate,
        [string[]] $VolatileFields,
        [bool] $IncludeValues
    )

    $ReferenceVersion = [string] $Reference.schemaVersion
    $CandidateVersion = [string] $Candidate.schemaVersion
    if ($ReferenceVersion -ne $CandidateVersion) {
        throw "schemaVersion mismatch: reference '$ReferenceVersion' vs candidate '$CandidateVersion'"
    }

    $Differences = New-Object System.Collections.Generic.List[object]
    $VolatileDifferences = New-Object System.Collections.Generic.List[object]
    Compare-CloakNode $Reference $Candidate '$' $false $Differences $VolatileDifferences $VolatileFields $IncludeValues 0

    $Status = 'match'
    if ($Differences.Count -gt 0) { $Status = 'mismatch' }
    elseif ($VolatileDifferences.Count -gt 0) { $Status = 'match-with-volatile' }

    return [pscustomobject] @{
        Status              = $Status
        Differences         = $Differences
        VolatileDifferences = $VolatileDifferences
    }
}

function Read-CloakDocument {
    param([string] $Path)

    if (-not (Test-Path -LiteralPath $Path)) {
        throw "collector document not found: $Path"
    }
    $Text = Get-Content -LiteralPath $Path -Raw -Encoding UTF8
    try {
        $Document = $Text | ConvertFrom-Json
    }
    catch {
        throw "invalid JSON in '$Path': $($_.Exception.Message)"
    }
    if ($null -eq $Document -or -not ($Document -is [System.Management.Automation.PSCustomObject])) {
        throw "top-level JSON value of '$Path' must be an object"
    }
    if ($null -eq $Document.PSObject.Properties['schemaVersion']) {
        throw "missing schemaVersion in '$Path'"
    }
    return $Document
}

function Write-CloakComparison {
    param(
        [string] $ReferencePath,
        [string] $CandidatePath,
        $Result,
        [bool] $IncludeValues
    )

    Write-Host ("==> '{0}' vs '{1}': {2}" -f $ReferencePath, $CandidatePath, $Result.Status)
    Write-Host ("    differences: {0} (volatile: {1})" -f $Result.Differences.Count, $Result.VolatileDifferences.Count)
    $AllDifferences = New-Object System.Collections.Generic.List[object]
    foreach ($Difference in $Result.Differences) { $AllDifferences.Add($Difference) }
    foreach ($Difference in $Result.VolatileDifferences) { $AllDifferences.Add($Difference) }
    foreach ($Difference in $AllDifferences) {
        $Line = "    [{0}] {1}" -f $Difference.Path, $Difference.Kind
        if ($Difference.Volatile) { $Line += ' (volatile)' }
        if ($IncludeValues) {
            $Line += " reference=$($Difference.ReferenceValue) candidate=$($Difference.CandidateValue)"
        }
        else {
            $Line += " reference=$($Difference.ReferenceHash) candidate=$($Difference.CandidateHash)"
        }
        Write-Host $Line
    }
}

function Get-CloakSelfTestReference {
    return @'
{
  "schemaVersion": 1,
  "buildHash": "FC03B2E6",
  "smbios": {
    "manufacturer": "OEM Systems",
    "productName": "TestVM",
    "serialNumber": "VM0001",
    "acpiOemId": "VBOX"
  },
  "cpuid": {
    "leaves": [
      { "leaf": "0x00000000", "eax": "0x0000000B", "ebx": "0x756E6547" },
      { "leaf": "0x00000001", "eax": "0x000306A9", "ebx": "0x00100800" }
    ]
  },
  "pci": {
    "pciOrder": [ "00:02.0", "00:03.0" ],
    "devices": [
      { "bdf": "00:02.0", "vendorId": "80EE", "deviceId": "BEEF", "address": "0xF0000000" },
      { "bdf": "00:03.0", "vendorId": "80EE", "deviceId": "CAFE", "address": "0xF1000000" }
    ]
  },
  "collector": {
    "timestamp": "2026-01-01T00:00:00Z",
    "sessionId": 42,
    "uptime": 120
  }
}
'@
}

function Assert-CloakSelfTest {
    param(
        [string] $Name,
        [string] $ReferenceJson,
        [string] $CandidateJson,
        [bool] $ExpectMatch,
        [int] $ExpectDifferences,
        [int] $ExpectVolatile,
        [string] $ExpectPathLike = ''
    )

    try {
        $ReferenceDocument = $ReferenceJson | ConvertFrom-Json
        $CandidateDocument = $CandidateJson | ConvertFrom-Json
        $Result = Get-CloakComparisonResult -Reference $ReferenceDocument -Candidate $CandidateDocument `
            -VolatileFields $script:CloakVolatileFields -IncludeValues $true
    }
    catch {
        Write-Host "FAIL [$Name] unexpected error: $($_.Exception.Message)"
        $script:CloakSelfTestFailed = $true
        return
    }

    $ActualMatch = $Result.Differences.Count -eq 0
    if ($ActualMatch -ne $ExpectMatch) {
        Write-Host "FAIL [$Name] expected match=$ExpectMatch, got match=$ActualMatch"
        $script:CloakSelfTestFailed = $true
        return
    }
    if ($Result.Differences.Count -ne $ExpectDifferences) {
        Write-Host "FAIL [$Name] expected $ExpectDifferences differences, got $($Result.Differences.Count)"
        $script:CloakSelfTestFailed = $true
        return
    }
    if ($Result.VolatileDifferences.Count -ne $ExpectVolatile) {
        Write-Host "FAIL [$Name] expected $ExpectVolatile volatile differences, got $($Result.VolatileDifferences.Count)"
        $script:CloakSelfTestFailed = $true
        return
    }
    if ($ExpectPathLike) {
        $Matched = $false
        foreach ($Difference in $Result.Differences) {
            if ($Difference.Path.Contains($ExpectPathLike)) { $Matched = $true }
        }
        if (-not $Matched) {
            Write-Host "FAIL [$Name] no difference path contains '$ExpectPathLike'"
            $script:CloakSelfTestFailed = $true
            return
        }
    }
    Write-Host "PASS [$Name]"
}

function Assert-CloakSelfTestThrows {
    param(
        [string] $Name,
        [string] $ReferenceJson,
        [string] $CandidateJson
    )

    try {
        $ReferenceDocument = $ReferenceJson | ConvertFrom-Json
        $CandidateDocument = $CandidateJson | ConvertFrom-Json
        $null = Get-CloakComparisonResult -Reference $ReferenceDocument -Candidate $CandidateDocument `
            -VolatileFields $script:CloakVolatileFields -IncludeValues $true
    }
    catch {
        Write-Host "PASS [$Name] ($($_.Exception.Message))"
        return
    }
    Write-Host "FAIL [$Name] expected schema error, comparison succeeded"
    $script:CloakSelfTestFailed = $true
}

function Invoke-CloakSelfTest {
    $Base = Get-CloakSelfTestReference

    Assert-CloakSelfTest -Name 'identical documents match' -ReferenceJson $Base -CandidateJson $Base `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 0

    $DeviceIdChanged = $Base.Replace('"deviceId": "BEEF"', '"deviceId": "BEE0"')
    Assert-CloakSelfTest -Name 'PCI device ID change fails' -ReferenceJson $Base -CandidateJson $DeviceIdChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.devices[00:02.0].deviceId'

    $OrderChanged = $Base.Replace('"pciOrder": [ "00:02.0", "00:03.0" ]', '"pciOrder": [ "00:03.0", "00:02.0" ]')
    Assert-CloakSelfTest -Name 'array order only passes' -ReferenceJson $Base -CandidateJson $OrderChanged `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 0

    $VolatileChanged = $Base.Replace('"timestamp": "2026-01-01T00:00:00Z"', '"timestamp": "2026-01-02T00:00:00Z"')
    $VolatileChanged = $VolatileChanged.Replace('"sessionId": 42', '"sessionId": 43')
    $VolatileChanged = $VolatileChanged.Replace('"uptime": 120', '"uptime": 200')
    Assert-CloakSelfTest -Name 'volatile fields only pass' -ReferenceJson $Base -CandidateJson $VolatileChanged `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 3

    $SessionOnly = $Base.Replace('"sessionId": 42', '"sessionId": 43')
    Assert-CloakSelfTest -Name 'session id is volatile' -ReferenceJson $Base -CandidateJson $SessionOnly `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 1

    $HexCase = $Base.Replace('"vendorId": "80EE"', '"vendorId": "80ee"')
    Assert-CloakSelfTest -Name 'hex case is canonical' -ReferenceJson $Base -CandidateJson $HexCase `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 0

    $PaddedOemId = $Base.Replace('"acpiOemId": "VBOX"', '"acpiOemId": "VBOX  "')
    Assert-CloakSelfTest -Name 'ACPI OEM ID padding is canonical' -ReferenceJson $Base -CandidateJson $PaddedOemId `
        -ExpectMatch $true -ExpectDifferences 0 -ExpectVolatile 0

    $AddedDevice = $Base.Replace(
        '{ "bdf": "00:03.0", "vendorId": "80EE", "deviceId": "CAFE", "address": "0xF1000000" }' + "`n    ]",
        '{ "bdf": "00:03.0", "vendorId": "80EE", "deviceId": "CAFE", "address": "0xF1000000" },' + "`n      { `"bdf`": `"00:04.0`", `"vendorId`": `"1AF4`", `"deviceId`": `"1000`", `"address`": `"0xF2000000`" }" + "`n    ]")
    Assert-CloakSelfTest -Name 'added PCI device fails' -ReferenceJson $Base -CandidateJson $AddedDevice `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '00:04.0'

    $BuildHashChanged = $Base.Replace('"buildHash": "FC03B2E6"', '"buildHash": "AAAA0000"')
    Assert-CloakSelfTest -Name 'build hash change fails' -ReferenceJson $Base -CandidateJson $BuildHashChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.buildHash'

    $CpuidChanged = $Base.Replace('"eax": "0x000306A9"', '"eax": "0x000306AA"')
    Assert-CloakSelfTest -Name 'CPUID leaf change fails' -ReferenceJson $Base -CandidateJson $CpuidChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.leaves[0x00000001].eax'

    $SerialChanged = $Base.Replace('"serialNumber": "VM0001"', '"serialNumber": "VM0002"')
    Assert-CloakSelfTest -Name 'DMI serial change fails' -ReferenceJson $Base -CandidateJson $SerialChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.serialNumber'

    $OemChanged = $Base.Replace('"acpiOemId": "VBOX"', '"acpiOemId": "VB0X"')
    Assert-CloakSelfTest -Name 'ACPI OEM ID change fails' -ReferenceJson $Base -CandidateJson $OemChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.acpiOemId'

    $TypeChanged = $Base.Replace('"serialNumber": "VM0001"', '"serialNumber": { "value": "VM0001" }')
    Assert-CloakSelfTest -Name 'scalar to object type change fails' -ReferenceJson $Base -CandidateJson $TypeChanged `
        -ExpectMatch $false -ExpectDifferences 1 -ExpectVolatile 0 -ExpectPathLike '.serialNumber'

    $SchemaChanged = $Base.Replace('"schemaVersion": 1', '"schemaVersion": 2')
    Assert-CloakSelfTestThrows -Name 'schemaVersion mismatch is an input error' -ReferenceJson $Base -CandidateJson $SchemaChanged
}

if ($SelfTest) {
    Invoke-CloakSelfTest
    if ($script:CloakSelfTestFailed) {
        Write-Host 'Comparator self-test FAILED'
        exit 1
    }
    Write-Host 'Comparator self-test passed'
    exit 0
}

try {
    if (-not $Reference) {
        throw '-Reference is required (or use -SelfTest)'
    }
    if (-not $Candidate -or $Candidate.Count -eq 0) {
        throw 'at least one -Candidate is required'
    }

    $VolatileFields = $script:CloakVolatileFields
    if ($VolatileField) {
        $VolatileFields = @($VolatileFields + ($VolatileField | ForEach-Object { $_.ToLowerInvariant() }))
    }

    $ReferenceDocument = Read-CloakDocument $Reference
    $ReportCandidates = New-Object System.Collections.Generic.List[object]
    $Failed = $false

    foreach ($CandidatePath in $Candidate) {
        $CandidateDocument = Read-CloakDocument $CandidatePath
        $Result = Get-CloakComparisonResult -Reference $ReferenceDocument -Candidate $CandidateDocument `
            -VolatileFields $VolatileFields -IncludeValues ([bool] $IncludeValues)
        Write-CloakComparison -ReferencePath $Reference -CandidatePath $CandidatePath -Result $Result -IncludeValues ([bool] $IncludeValues)
        if ($Result.Status -eq 'mismatch') { $Failed = $true }

        $ReportCandidates.Add([pscustomobject] @{
            path                = $CandidatePath
            status              = $Result.Status
            differences         = $Result.Differences.ToArray()
            volatileDifferences = $Result.VolatileDifferences.ToArray()
        }) | Out-Null
    }

    if ($ReportPath) {
        $ReportStatus = 'match'
        if ($Failed) { $ReportStatus = 'mismatch' }
        $Report = [pscustomobject] @{
            reportFormatVersion = 1
            schemaVersion       = [string] $ReferenceDocument.schemaVersion
            buildHash           = [string] $ReferenceDocument.buildHash
            reference           = $Reference
            includeValues       = [bool] $IncludeValues
            status              = $ReportStatus
            candidates          = $ReportCandidates.ToArray()
        }
        $ResolvedReport = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
        $ReportDirectory = Split-Path -Parent $ResolvedReport
        if ($ReportDirectory -and -not (Test-Path -LiteralPath $ReportDirectory)) {
            New-Item -ItemType Directory -Path $ReportDirectory -Force | Out-Null
        }
        [System.IO.File]::WriteAllText($ResolvedReport, ($Report | ConvertTo-Json -Depth 16), [System.Text.UTF8Encoding]::new($false))
        Write-Host "Comparator report: $ResolvedReport"
    }

    if ($Failed) {
        exit 1
    }
    exit 0
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 2
}
