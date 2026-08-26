# BoneIO Black Debian Images

Narzędzia do budowy i flashowania obrazów Debian dla BoneIO Black (BeagleBone Black).

> **Szukasz instrukcji aktualizacji?** Zobacz [UPDATE.md](UPDATE.md)

---

## Budowa obrazów

### Wymagania

- PC z Linux (Ubuntu/Debian)
- Karta microSD (min. 8GB)
- BeagleBone Black z Debian 13

### Krok 0: Przygotowanie PC (jednorazowo)

Skrypty budujące obrazy (`generate_all_images.sh`, `create_rootfs_img.sh`,
`create_flasher_sd.sh`, `build_image_usb.sh`) potrzebują na PC: `util-linux`
(`losetup`, `partprobe`, `blkid`, `sfdisk`), `parted`, `cloud-guest-utils`
(`growpart`), `e2fsprogs`, `xz-utils`, opcjonalnie `uv` (auto-refresh cache
configów z `app_black`) oraz `pishrink.sh`.

```bash
sudo ./scripts/setup_pc.sh
```

Skrypt instaluje wszystkie powyższe (apt) i wypisuje raport co się udało.
Wymaga systemu opartego o `apt` (Ubuntu/Debian). Jeśli chcesz korzystać
z auto-refresh cache configów, sklonuj `app_black` obok tego repo (`../app_black`).

### Krok 1: Przygotowanie bazowego systemu (na BBB)

Włóż kartę SD ze świeżym Debian 13 do BBB i uruchom:

```bash
curl -H 'Cache-Control: no-cache' -fsSL \
  https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash
```

Skrypt automatycznie:
- Instaluje pakiety (docker, mosquitto, python-venv, etc.)
- Konfiguruje UFW, journald, Docker, Mosquitto
- Instaluje boneIO w virtualenv
- Buduje Device Tree Overlay
- Czyści system (logi, cache, klucze SSH, machine-id)
- Wyłącza BBB

### Krok 2: Tworzenie obrazu bazowego (na PC)

```bash
# Podłącz kartę SD z BBB do PC
sudo ./scripts/create_rootfs_img.sh /dev/sdX rootfs.img
```

Skrypt używa `dd` + `pishrink` do stworzenia minimalnego obrazu.

### Krok 3: Generowanie wariantów (na PC)

```bash
# Tylko obrazy do uruchamiania z SD
sudo ./scripts/generate_all_images.sh rootfs.img 1.0.2

# Z eMMC flasherami
sudo ./scripts/generate_all_images.sh rootfs.img 1.0.2 --emmc-flasher
```

Wyjście:
```
boneio-black-v1.0.2-32x10-sdcard.img.xz
boneio-black-v1.0.2-32x10-emmc-flasher.img.xz
boneio-black-v1.0.2-24x16-sdcard.img.xz
boneio-black-v1.0.2-24x16-emmc-flasher.img.xz
...
```

### Krok 4: Testowanie flashera

```bash
# Przygotuj kartę SD flashera ręcznie (do testów)
sudo ./scripts/create_flasher_sd.sh /dev/sdX rootfs.img
```

---

## Struktura repozytorium

| Plik | Opis |
|------|------|
| `scripts/setup_pc.sh` | Instaluje zależności budowania obrazów na PC (jednorazowo) |
| `scripts/setup_boneio.sh` | Główny skrypt konfiguracji systemu (uruchamiany na BBB) |
| `scripts/create_rootfs_img.sh` | Tworzenie `.img` z karty SD (`dd` + `pishrink`) |
| `scripts/create_flasher_sd.sh` | Przygotowanie karty SD jako flasher eMMC |
| `scripts/generate_all_images.sh` | Generator wariantów obrazów |
| `scripts/flasher/init-beagle-flasher-img` | Skrypt init flashera (`dd` na eMMC + naprawa fstab) |
| `scripts/flasher/init-beagle-flasher-original` | Oryginalny flasher BeagleBoard (rsync, referencja) |

## Jak działa flasher eMMC

1. Karta SD bootuje z `cmdline=init=/usr/sbin/init-beagle-flasher-img`
2. Flasher montuje pseudo-filesystemy i ładuje moduły MMC
3. `dd` kopiuje `/boneio-emmc.img` na eMMC (`/dev/mmcblk1`)
4. Po dd: `partprobe`, montuje rootfs eMMC i naprawia:
   - `/etc/fstab` — poprawne ścieżki urządzeń eMMC
   - `/boot/uEnv.txt` — wyłącza tryb flashera
   - `/etc/default/generic-sys-mods` — ustawia `ROOT_DRIVE`
5. **Auto-detekcja board version** (patrz sekcja `boneio.txt` poniżej):
   - Czyta `boneio.txt` z partycji boot SD (jeśli istnieje)
   - Lub probing I2C2 — DS2484 @ 0x18 = board v1.0
   - Ustawia overlay, moduły 1-Wire, wersję w `config.yaml`
6. Generuje klucze SSH, czyści flagi
7. Przy pierwszym bocie z eMMC: `bb-growpart` rozszerza partycję rootfs

## sysconf.txt (opcjonalnie)

Plik `/boot/firmware/sysconf.txt` pozwala na konfigurację przy pierwszym bocie:

```
user_name=boneio
user_password=Black
hostname=boneIOBlack
timezone=Europe/Warsaw
usb_enable_dhcp=yes
enable_ufw=yes
ufw_allow_ssh=yes
```

## boneio.txt — wersja płytki

Flasher automatycznie wykrywa wersję płytki BoneIO Black przez I2C probe
(szuka DS2484 na I2C2 @ 0x18). Jeśli chcesz **wymusić** wersję — np. flashujesz
sam BeagleBone bez podłączonej płytki input — stwórz plik `boneio.txt`
na partycji boot (FAT32) karty SD:

```bash
# /boot/firmware/boneio.txt
BOARD_VERSION=1.0
```

**Priorytet detekcji:**
1. `boneio.txt` na partycji boot SD (user override)
2. I2C probe DS2484 @ 0x18 (auto-detect)

**Obsługiwane wartości:**

| BOARD_VERSION | Overlay | 1-Wire | Config version |
|---------------|---------|--------|----------------|
| `0.8` (domyślny) | `BONEIO-BLACK-PINS.dtbo` | GPIO | 0.8 |
| `1.0` | `BONEIO-BLACK-PINS-v1.0.dtbo` | DS2484 (kernel) | 1.0 |

Gdy flasher wykryje board v1.0 (przez `boneio.txt` lub I2C), automatycznie:
- Zmienia overlay w `uEnv.txt`
- Instaluje `/etc/modules-load.d/onewire.conf` (ds2482 + w1-therm)
- Aktualizuje `version: 0.8` → `version: 1.0` w `config.yaml`

Przykładowy plik: [`scripts/flasher/boneio.txt.example`](scripts/flasher/boneio.txt.example)

