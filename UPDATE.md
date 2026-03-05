# BoneIO Black — Aktualizacja oprogramowania

## Aktualizacja aplikacji boneIO (bez zmiany obrazu)

Zaloguj się na urządzenie przez SSH i uruchom:

```bash
ssh boneio@<adres_ip>
# Domyślne hasło: Black

# Aktualizacja boneIO do najnowszej wersji
~/boneio/venv/bin/pip install --upgrade boneio

# Restart usługi
sudo systemctl restart BoneIO
```

## Aktualizacja Device Tree Overlay

```bash
cd /opt/source/black-pins-overlay
git pull
./build_boneio_black_pins.sh
sudo reboot
```

## Pełna aktualizacja obrazu (eMMC flasher)

Wymaga karty microSD (min. 8GB) i komputera z Linux.

1. Pobierz obraz flashera dla swojego wariantu sprzętowego:
   ```
   boneio-black-vX.Y.Z-<wariant>-emmc-flasher.img.xz
   ```

2. Wgraj obraz na kartę SD (na PC):
   ```bash
   xzcat boneio-black-vX.Y.Z-<wariant>-emmc-flasher.img.xz | sudo dd of=/dev/sdX bs=4M status=progress
   sync
   ```
   > **Uwaga:** Zamień `/dev/sdX` na właściwe urządzenie karty SD (np. `/dev/sdb`). Sprawdź poleceniem `lsblk`.

3. Flashowanie eMMC:
   - Wyłącz zasilanie BoneIO Black
   - Włóż kartę SD
   - Przytrzymaj przycisk BOOT i włącz zasilanie
   - Diody LED będą migać (animacja cylon) — trwa flashowanie
   - Po zakończeniu **wszystkie 4 diody LED zaświecą się** na stałe
   - Wyjmij kartę SD
   - Urządzenie wyłączy się automatycznie

4. Pierwszy boot po flashowaniu:
   - Włącz zasilanie (bez karty SD)
   - System automatycznie: rozszerzy partycję, wygeneruje klucze SSH, ustawi hostname
   - Pierwszy start trwa dłużej (~2-3 minuty) i zawiera 1-2 automatyczne restarty
   - Po zakończeniu urządzenie jest gotowe do użycia

## Domyślne dane dostępowe

| Usługa | Login | Hasło |
|--------|-------|-------|
| SSH | `boneio` | `Black` |
| MQTT | `boneio` | `boneio123` |
| MQTT | `homeassistant` | `boneio123` |

## Porty sieciowe

| Port | Usługa |
|------|--------|
| 22 | SSH |
| 1883 | MQTT (Mosquitto) |
| 8090 | BoneIO Web |
| 8091 | Nginx proxy (Node-RED) |
