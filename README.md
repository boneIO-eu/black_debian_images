# BoneIO Black Debian Images

Narzędzia do budowy i flashowania obrazów Debian dla BoneIO Black (BeagleBone Black).

> **Szukasz instrukcji aktualizacji?** Zobacz [UPDATE.md](UPDATE.md)

---

## Budowa obrazów

### Wymagania

- PC z Linux (Ubuntu/Debian)
- Karta microSD (min. 8GB)
- BeagleBone Black z Debian 13
- `pishrink.sh` — [github.com/Drewsif/PiShrink](https://github.com/Drewsif/PiShrink)

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
5. Przy pierwszym bocie z eMMC: `pishrink` auto-expand rozszerza partycję rootfs

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
