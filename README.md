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
(`growpart`), `e2fsprogs`, `xz-utils`, `uv` (generowanie cache configów
z `app_black`) oraz `pishrink.sh`.

```bash
sudo ./scripts/setup_pc.sh
```

Skrypt instaluje wszystkie powyższe (apt) i wypisuje raport co się udało.
Wymaga systemu opartego o `apt` (Ubuntu/Debian). Jeśli chcesz korzystać
z `generate_all_images.sh`, sklonuj `app_black` obok tego repo (`../app_black`).

Cache configów (`config.yaml.cache.pkl` obok szablonów w
`../app_black/boneio/factory_config/`) jest generowany, nie trzymany
w repo. `generate_all_images.sh` przelicza go na świeżo przy każdym budowaniu
i **przerywa build**, jeśli się nie uda albo jeśli `schema.yaml` w `app_black`
różni się od tego, który instaluje obraz — w obu przypadkach sterownik odrzuciłby
cache i walidował config przy pierwszym starcie (20-30 s na BBB). Jeśli świadomie
godzisz się na wolny pierwszy start, dodaj `--allow-cold-cache`.

### Configi per wersja płyty

Szablony configów nie mieszkają w tym repo. Są w `app_black`, w
`boneio/factory_config/<rewizja>/<wariant>/`, i jadą z paczką boneIO —
z tych samych plików korzysta reset fabryczny w aplikacji, więc obraz i reset
nie mogą się rozjechać, a zmiana formatu configu dociera z aktualizacją apki.

`setup_boneio.sh` kopiuje wszystkie rewizje z zainstalowanej paczki do
`~/.cache/boneio_configs/<rewizja>/<wariant>/`; `boneio-board-setup` wybiera
z nich jeden przy pierwszym starcie.

Domyślną rewizję wybiera `BOARD_CONFIG_VERSION` (domyślnie **1.1**), ustawiana
w kilku miejscach — przy podbiciu wersji trzeba ruszyć wszystkie:

| Plik | Zmienna |
| --- | --- |
| `scripts/generate_all_images.sh` | `BOARD_CONFIG_VERSION` |
| `scripts/create_flasher_sd.sh` | `BOARD_CONFIG_VERSION` |
| `scripts/setup_boneio.sh` | `BOARD_CONFIG_VERSION` |
| `scripts/flasher/init-beagle-flasher-img` | `DETECTED_V1_VERSION` |

Trzy pierwsze da się nadpisać z env na jeden build:

```bash
BOARD_CONFIG_VERSION=1.0 sudo ./scripts/generate_all_images.sh rootfs.img 1.6.0
```

Flasher eMMC stempluje wykrytą płytę osobno: probe I2C odróżnia tylko 1.x od
0.x, więc płyta wykryta po DS2484 dostaje `DETECTED_V1_VERSION`, chyba że
`boneio.txt` mówi inaczej.

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

## boneio.txt — wersja płytki i typ sterownika

Jest jeden obraz dla wszystkich sterowników. Przy pierwszym starcie świeżego
systemu — czy karta uruchamia sterownik, czy flashuje eMMC —
`boneio-board-setup` dopasowuje go do płytki: wybiera config
(`~/.cache/boneio_configs/<wersja>/<typ>/`), ustawia overlay pinów w `uEnv.txt`
(jeden restart, jeśli się zmienił), na 1.x włącza moduły 1-Wire i wykrywa płytkę
przekaźników sterowaną stanem niskim. Robi to raz; wpisów w `boneio.txt` nie
trzeba potem usuwać.

Wersję wykrywa przez I2C probe (DS2484 na I2C2 @ 0x18: jest → 1.1, brak → 0.8).
Typ sterownika podaje stacja produkcyjna; bez niego sterownik startuje bez wyjść,
a kreator pierwszego uruchomienia pyta, jaki to sterownik. Oba można wpisać w
`boneio.txt` na partycji boot (FAT32) karty SD:

```bash
# /boot/firmware/boneio.txt
BOARD_VERSION=1.0
DEVICE_TYPE=32x10
```

**Priorytet detekcji:**
1. `boneio.txt` na partycji boot SD (user override)
2. I2C probe DS2484 @ 0x18 (auto-detect)

**Obsługiwane wartości:**

| BOARD_VERSION | Overlay | 1-Wire | Config |
|---------------|---------|--------|--------|
| `0.8` (brak DS2484) | `BONEIO-BLACK-PINS-v0.4-v0.8.dtbo` | GPIO | `0.8/<typ>` (ina219) |
| `1.0` | `BONEIO-BLACK-PINS-v1.0.dtbo` | DS2484 (kernel) | `1.0/<typ>` |
| `1.1` (wykryty DS2484) | `BONEIO-BLACK-PINS-v1.0.dtbo` | DS2484 (kernel) | `1.1/<typ>` (buzzer) |

| DEVICE_TYPE | Config |
|-------------|--------|
| `32x10`, `24x16`, `cover`, `cover_mix` | `<wersja>/<typ>` |
| brak | `<wersja>/base` (bez wyjść), typ wybierany w kreatorze |


Ten plik jest już na każdej karcie — **na partycji FAT `BOOT`**, czyli tej,
którą widać po włożeniu karty do dowolnego PC (także Windows/macOS). Wszystkie
ustawienia są obecne i zakomentowane; odkomentuj to, czego potrzebujesz. Sam
plik nic nie zmienia, dopóki wszystko jest zakomentowane.

Flasher montuje tę partycję jako `/boot/firmware` i czyta ją w pierwszej
kolejności. `/boot/boneio.txt` w rootfs jest drugą opcją, ale rootfs jest ext4 —
z Windows/macOS go nie otworzysz, więc nie trzymamy tam tego pliku.

Wzorzec w repo: [`scripts/flasher/boneio.txt.example`](scripts/flasher/boneio.txt.example)

