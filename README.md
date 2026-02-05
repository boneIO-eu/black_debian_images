# BoneIO Black Debian Images

Este repozytorium zawiera narzędzia do budowy i flashowania obrazów Debian dla BoneIO Black.

## Quick Start

### 1. Przygotowanie świeżego BBB (na urządzeniu)

```bash
curl -fsSL https://raw.githubusercontent.com/boneIO-eu/black_debian_images/main/scripts/setup_boneio.sh | sudo bash
```

Skrypt automatycznie:
- Instaluje wszystkie pakiety (docker, mosquitto, python-venv, etc.)
- Konfiguruje UFW, journald, Docker
- Instaluje boneIO w venv
- Buduje Device Tree Overlay
- Czyści system i wyłącza BBB

### 2. Tworzenie obrazu (na PC)

```bash
# Podłącz kartę SD z BBB do PC
sudo ./scripts/create_rootfs_img.sh /dev/sdb rootfs.img
```

### 3. Generowanie wariantów (na PC)

```bash
# Tylko obrazy SDCARD
sudo ./scripts/generate_all_images.sh rootfs.img 1.0.2

# Z eMMC flasherami
sudo ./scripts/generate_all_images.sh rootfs.img 1.0.2 --emmc-flasher
```

**Wyjście:**
```
boneio-black-v1.0.2-32x10-sdcard.img.xz
boneio-black-v1.0.2-32x10-emmc-flasher.img.xz
boneio-black-v1.0.2-24x16-sdcard.img.xz
...
```

### 4. Flashowanie eMMC (produkcja)

```bash
# Wgraj flasher na kartę SD
xzcat boneio-black-v1.0.2-32x10-emmc-flasher.img.xz | sudo dd of=/dev/sdb bs=4M status=progress

# Włóż do BBB, przytrzymaj boot, włącz zasilanie
# ~5 minut, wszystkie 4 LED świecą = gotowe
```

---

## Struktura skryptów

| Skrypt | Opis |
|--------|------|
| `setup_boneio.sh` | Główny skrypt instalacyjny (curl) |
| `prepare_image.sh` | Finalizacja obrazu (hostname, cleanup) |
| `create_rootfs_img.sh` | Tworzenie .img z karty SD |
| `create_flasher_sd.sh` | Tworzenie karty flasher |
| `generate_all_images.sh` | Generator wszystkich wariantów |
| `flasher/init-beagle-flasher-img` | Init script dla flashera (xzcat+dd) |

---

## sysconf.txt (opcjonalnie)

```
user_name=boneio
user_password=Black
hostname=boneIOBlack
timezone=Europe/Warsaw
usb_enable_dhcp=yes
enable_ufw=yes
ufw_allow_ssh=yes
```

## Porty

| Port | Usługa |
|------|--------|
| 1883 | MQTT (Mosquitto) |
| 8090 | BoneIO Web |
| 8091 | Nginx proxy (Node-RED) |
