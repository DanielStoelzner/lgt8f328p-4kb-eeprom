# LGT8F328P Boards (4 KB EEPROM Option)

An Arduino Boards Manager package based on the [upstream LGT8fx 2.0.7 platform](https://github.com/dbuezas/lgt8fx/tree/v2.0.7).
It exposes the LGT8F328P board target with 4 KB reserved for EEPROM.

## Install

In Arduino IDE, add this URL under **Preferences → Additional Boards Manager
URLs**:

`https://raw.githubusercontent.com/DanielStoelzner/lgt8f328p-4kb-eeprom/master/package_lgt8f328p_4kb_eeprom_index.json`

Then open Boards Manager, search for **LGT8F328P Boards (4 KB EEPROM Option)**,
and install it. Select **LGT8F328P (4 KB EEPROM)** from the board menu and choose
the matching package variant. Burn its bootloader before uploading sketches.

For ISP programmer setup and wiring, refer to the upstream
[LarduinoISP guide](https://github.com/dbuezas/lgt8fx/blob/master/lgt8f/libraries/LarduinoISP/readme.md)
or the [LGTISP guide](https://github.com/SuperUserNameMan/LGTISP).

The package includes the LQFP32, LQFP48, Wemos LQFP32, and SSOP20 variants. Only
the LQFP32 variant has been hardware-tested; use the others at your own risk.

## PlatformIO

Burn the 4 KB EEPROM bootloader separately through Arduino IDE first. For normal
PlatformIO builds and serial uploads, continue using the standard `lgt8f328p`
board and add this to the applicable environment in `platformio.ini`:

```ini
board_upload.maximum_size = 23552
```

This prevents the application from overlapping the relocated bootloader. It
does not install, select, or modify the bootloader.

## Maintenance

`tools/Build-LGT-4KB-EEPROM-Bootloader.ps1` reproduces the relocated bootloader
from an installed upstream LGT8fx 2.0.7 package and validates the generated
image before replacing the package HEX.

## Source and license

This is a fork of [dbuezas/lgt8fx](https://github.com/dbuezas/lgt8fx),
based on its 2.0.7 release. The upstream license and attribution are retained.
