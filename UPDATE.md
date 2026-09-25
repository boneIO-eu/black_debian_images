# BoneIO Black — Aktualizacja oprogramowania

## Aktualizacja aplikacji boneIO (bez zmiany obrazu)

Zaloguj się na urządzenie przez SSH i uruchom:

```bash
ssh boneio@<adres_ip>
# Hasło to hasło admina z kreatora pierwszego uruchomienia — patrz "Dane dostępowe" niżej.

# Aktualizacja boneIO do wskazanej wersji
~/boneio/venv/bin/pip install --upgrade "boneio==1.6.0.dev15"

# Restart usługi
sudo systemctl restart BoneIO
```

> **Dlaczego wersja jest wpisana wprost, a nie `--upgrade boneio`.**
> Seria 1.6 jest publikowana jako pre-release (`1.6.0.devN`), a `pip install
> --upgrade boneio` bierze najnowsze wydanie **stabilne** — czyli zostawia
> urządzenie na linii 1.5 i nic o tym nie mówi. Podstaw numer wersji, którą
> chcesz wgrać.

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

## Dane dostępowe

Obrazy od 1.6 **nie mają już haseł wspólnych dla całej serii**. Ta tabela
podawała wcześniej `Black` i `boneio123`, identyczne na każdym wysłanym
urządzeniu — znajomość jednego sterownika oznaczała znajomość wszystkich.

| Usługa | Login | Hasło |
|--------|-------|-------|
| SSH | `boneio` | to samo, co hasło administratora z kreatora pierwszego uruchomienia; do tego czasu logowanie hasłem jest zablokowane |
| MQTT | `boneio` | losowe, per urządzenie — panel zna je sam, Ty nie musisz |
| MQTT | `homeassistant`, `mqtt` | losowe, do podmiany na własne w **Ustawienia → MQTT** |

Panel może zmienić wszystkie trzy hasła MQTT bez podawania hasła systemowego,
więc nic nie tracisz na tym, że ich nie znasz.

Hasło SSH ustawia się **raz**, w kreatorze. Późniejsza zmiana hasła w panelu go
nie zmienia — do tego służy `passwd` po zalogowaniu przez SSH, który pyta o
obecne hasło. Konto `boneio` może zostać rootem, więc to hasło chroni całe
urządzenie.

Urządzenia zaktualizowane ze starszych obrazów mogą nadal mieć `Black`. Sekcja
bezpieczeństwa w panelu to wykrywa; zmień je przez `passwd`.

## Porty sieciowe

| Port | Usługa |
|------|--------|
| 22 | SSH |
| 1883 | MQTT (Mosquitto) |
| 8443 | **panel boneIO po HTTPS** (Caddy) — tu wchodzisz |
| 8090 | panel boneIO, czysty HTTP — od 1.6 **nie jest wystawiony na LAN** |
| 8091 | Caddy, czysty HTTP (Node-RED) |

Świeży obraz 1.6 ma `web: expose: proxy`, więc na 8090 odpowiada tylko
loopback, mostek Dockera i kabel USB. Z sieci wchodzisz na
`https://<adres_ip>:8443` — certyfikat jest self-signed, więc przeglądarka
ostrzeże raz. Przez kabel USB: `http://192.168.7.2:8090`. Żeby wrócić do
starego zachowania, ustaw `expose: all` w **Ustawienia → Serwer web**.
