param(
    [string]$ArduinoPackagesPath = (Join-Path $env:LOCALAPPDATA 'Arduino15\packages'),
    [string]$PlatformVersion = '2.0.7'
)

$ErrorActionPreference = 'Stop'
$platformPath = Join-Path $ArduinoPackagesPath "lgt8fx\hardware\avr\$PlatformVersion"
$bootloaderDirectory = Join-Path $platformPath 'bootloaders\lgt8fx8p'
$sourceFile = Join-Path $bootloaderDirectory 'optiboot.c'
$stockHex = Join-Path $bootloaderDirectory 'optiboot_lgt8f328p.hex'
$stockElf = Join-Path $bootloaderDirectory 'optiboot_lgt8f328p.elf'
$repositoryRoot = Split-Path -Parent $PSScriptRoot
$outputDirectory = Join-Path $repositoryRoot 'lgt8f\bootloaders\lgt8fx8p_4kb'
$outputHex = Join-Path $outputDirectory 'optiboot_lgt8f328p_4kb.hex'
$toolDirectory = Join-Path $ArduinoPackagesPath 'arduino\tools\avr-gcc'
$objdump = Get-ChildItem -LiteralPath $toolDirectory -Directory -ErrorAction SilentlyContinue |
    Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'bin\avr-objdump.exe') } |
    Sort-Object Name -Descending |
    ForEach-Object { Join-Path $_.FullName 'bin\avr-objdump.exe' } |
    Select-Object -First 1

foreach ($requiredPath in @($sourceFile, $stockHex, $stockElf, $objdump)) {
    if (-not $requiredPath -or -not (Test-Path -LiteralPath $requiredPath -PathType Leaf)) {
        throw "Required LGT8fx $PlatformVersion bootloader source/artifact/tool was not found: $requiredPath"
    }
}

# Only the platform's known reset-vector references may change for relocation.
$source = Get-Content -LiteralPath $sourceFile -Raw
if ([regex]::Matches($source, '\.word\s+0x3a00').Count -ne 1 -or
    [regex]::Matches($source, 'buff\[3\]\s*=\s*0x3a;').Count -ne 1) {
    throw 'Unexpected Optiboot source: expected exactly two reset-vector references to 0x7400.'
}

# Relocation preserves every relative branch, but would break absolute code jumps.
$disassembly = & $objdump -d $stockElf
if ($LASTEXITCODE -ne 0) { throw "avr-objdump failed with exit code $LASTEXITCODE" }
$absoluteControlTransfers = @($disassembly | Where-Object {
    $_ -match '^\s*[0-9a-fA-F]+:\s+(?:[0-9a-fA-F]{2}\s+)+\s*(?:call|jmp)\b'
})
if ($absoluteControlTransfers.Count -gt 0) {
    throw 'The stock bootloader contains absolute CALL/JMP instructions; it cannot be safely relocated by this tool.'
}
$flashReadInstructions = @($disassembly | Where-Object { $_ -match '\blpm\b|\belpm\b' })
if ($flashReadInstructions.Count -ne 1 -or $source -notmatch 'lpm %0,Z\\n"\s*:\s*"=r"\s*\(ch\)\s*:\s*"z"\s*\(address\)') {
    throw 'Unexpected program-memory read in the stock bootloader; relocation safety could not be verified.'
}

# Read and checksum-validate the stock Intel HEX into an address-to-byte map.
$image = @{}
$linearBase = 0
$startAddressRecord = $null
$startAddressType = $null
foreach ($line in Get-Content -LiteralPath $stockHex) {
    if ($line -notmatch '^:([0-9A-Fa-f]{2})([0-9A-Fa-f]{4})([0-9A-Fa-f]{2})([0-9A-Fa-f]*)$') {
        throw "Malformed Intel HEX record: $line"
    }
    $count = [Convert]::ToInt32($Matches[1], 16)
    $recordAddress = [Convert]::ToInt32($Matches[2], 16)
    $recordType = [Convert]::ToInt32($Matches[3], 16)
    $payloadHex = $Matches[4]
    if ($payloadHex.Length -ne (($count + 1) * 2)) { throw "Invalid record length: $line" }
    $recordBytes = [Collections.Generic.List[int]]::new()
    for ($i = 0; $i -lt $count; $i++) {
        $recordBytes.Add([Convert]::ToInt32($payloadHex.Substring($i * 2, 2), 16))
    }
    $checksum = [Convert]::ToInt32($payloadHex.Substring($count * 2, 2), 16)
    $sum = $count + (($recordAddress -shr 8) -band 0xff) + ($recordAddress -band 0xff) + $recordType + $checksum
    foreach ($byte in $recordBytes) { $sum += $byte }
    if (($sum -band 0xff) -ne 0) { throw "Intel HEX checksum mismatch: $line" }

    switch ($recordType) {
        0 {
            for ($i = 0; $i -lt $count; $i++) {
                $sourceAddress = $linearBase + $recordAddress + $i
                if ($sourceAddress -le 3) {
                    $destinationAddress = $sourceAddress
                } elseif ($sourceAddress -ge 0x7400 -and $sourceAddress -lt 0x7800) {
                    $destinationAddress = $sourceAddress - 0x1800
                } else {
                    throw ('Unexpected stock bootloader data at 0x{0:X4}.' -f $sourceAddress)
                }
                if ($image.ContainsKey($destinationAddress)) { throw ('Duplicate HEX address 0x{0:X4}.' -f $destinationAddress) }
                $image[$destinationAddress] = $recordBytes[$i]
            }
        }
        1 { break }
        4 {
            if ($count -ne 2) { throw "Invalid extended linear address record: $line" }
            $linearBase = (($recordBytes[0] -shl 8) -bor $recordBytes[1]) -shl 16
        }
        3 {
            if ($count -ne 4) { throw "Invalid start segment address record: $line" }
            $startAddress = (($recordBytes[0] -shl 8) -bor $recordBytes[1]) * 16 +
                (($recordBytes[2] -shl 8) -bor $recordBytes[3])
            if ($startAddress -ne 0x7400) { throw ('Unexpected HEX start address 0x{0:X4}.' -f $startAddress) }
            $startAddressRecord = @(0, 0, 0x5c, 0)
            $startAddressType = 3
        }
        5 {
            if ($count -ne 4) { throw "Invalid start linear address record: $line" }
            $startAddress = ($recordBytes[0] -shl 24) -bor ($recordBytes[1] -shl 16) -bor
                ($recordBytes[2] -shl 8) -bor $recordBytes[3]
            if ($startAddress -ne 0x7400) { throw ('Unexpected HEX start address 0x{0:X8}.' -f $startAddress) }
            $startAddressRecord = @(0, 0, 0x5c, 0)
            $startAddressType = 5
        }
        default { throw "Unsupported Intel HEX record type $recordType." }
    }
}

foreach ($address in 0, 1, 2, 3) {
    if (-not $image.ContainsKey($address)) { throw ('Missing reset stub byte at 0x{0:X4}.' -f $address) }
}
if ($image[0] -ne 0x0c -or $image[1] -ne 0x94 -or $image[2] -ne 0x00 -or $image[3] -ne 0x3a) {
    throw 'The stock reset stub is not the expected JMP to 0x7400.'
}
$textByteCount = @($image.Keys | Where-Object { [int]$_ -ge 0x5c00 -and [int]$_ -lt 0x5ffe }).Count
if ($textByteCount -ne 0x3e4) { throw "Unexpected bootloader code size: $textByteCount bytes; expected 996." }
if (-not $image.ContainsKey(0x5c00) -or -not $image.ContainsKey(0x5e3a) -or -not $image.ContainsKey(0x5e3b)) {
    throw 'The relocated bootloader is missing expected code or version bytes.'
}
if ($image[0x5e3a] -ne 0xea -or $image[0x5e3b] -ne 0xe3) {
    throw 'The stock bootloader reset-vector patch instruction was not found at the expected address.'
}

# The reset stub and the page-programming reset-vector patch must both target 0x5c00.
$image[3] = 0x2e
$image[0x5e3a] = 0xee # LDI r30, 0x2e (low opcode byte)
$image[0x5e3b] = 0xe2 # LDI r30, 0x2e (high opcode byte)

# Emit fresh, checksummed Intel HEX records, preserving sparse address regions.
$addresses = [int[]]@($image.Keys | ForEach-Object { [int]$_ } | Sort-Object)
$hexLines = [Collections.Generic.List[string]]::new()
$index = 0
while ($index -lt $addresses.Length) {
    $startAddress = $addresses[$index]
    $data = [Collections.Generic.List[int]]::new()
    while ($index -lt $addresses.Length -and $addresses[$index] -eq ($startAddress + $data.Count) -and $data.Count -lt 16) {
        $data.Add($image[$addresses[$index]])
        $index++
    }
    $sum = $data.Count + (($startAddress -shr 8) -band 0xff) + ($startAddress -band 0xff)
    $record = ':{0:X2}{1:X4}00' -f $data.Count, $startAddress
    foreach ($byte in $data) {
        $sum += $byte
        $record += '{0:X2}' -f $byte
    }
    $record += '{0:X2}' -f ((-$sum) -band 0xff)
    $hexLines.Add($record)
}
if ($null -ne $startAddressRecord) {
    $sum = 4 + $startAddressType
    $record = ':{0:X2}0000{1:X2}' -f 4, $startAddressType
    foreach ($byte in $startAddressRecord) {
        $sum += $byte
        $record += '{0:X2}' -f $byte
    }
    $record += '{0:X2}' -f ((-$sum) -band 0xff)
    $hexLines.Add($record)
}
$hexLines.Add(':00000001FF')

New-Item -ItemType Directory -Path $outputDirectory -Force | Out-Null
[IO.File]::WriteAllLines($outputHex, $hexLines, [Text.Encoding]::ASCII)
$relocatedDisassembly = & $objdump -D -b ihex -m avr5 $outputHex
if ($LASTEXITCODE -ne 0) { throw "Could not disassemble the relocated bootloader (exit code $LASTEXITCODE)." }
if (-not ($relocatedDisassembly | Where-Object { $_ -match '^\s*0:\s+0c 94 00 2e\s+jmp\s+0x5c00\b' })) {
    throw 'The relocated bootloader reset stub does not jump to 0x5c00.'
}
if (-not ($relocatedDisassembly | Where-Object { $_ -match '^\s*5e3a:\s+ee e2\s+ldi\s+r30, 0x2E\b' })) {
    throw 'The relocated bootloader page-programming reset-vector patch is incorrect.'
}
Write-Host "Created relocated bootloader: $outputHex"
Write-Host 'It is based on the installed LGT8fx platform HEX, with only reset-vector addresses changed.'
