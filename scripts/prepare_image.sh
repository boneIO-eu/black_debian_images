#!/bin/bash
## RUN sudo ./prepare_image.sh
# Check if script is run with sudo/root privileges
if [[ $EUID -ne 0 ]]; then
   echo "ERROR: This script must be run with sudo privileges!" 
   echo "Usage: sudo $0"
   exit 1
fi

echo "--- START: Preparing Debian 13 image ---"

# --- 0. UTF-8 CONFIGURATION ---
echo "0/5: Configuring UTF-8 locale..."
sed -i 's/# en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen en_US.UTF-8
update-locale LANG=en_US.UTF-8 LC_ALL=en_US.UTF-8

# --- 1. ONE-TIME HOSTNAME SETUP ---
echo "1/5: Installing one-time hostname setup service..."

cat << 'EOF' > /usr/local/bin/set-hostname-once.sh
#!/bin/bash
MAC=$(cat /sys/class/net/eth0/address 2>/dev/null)
if [ -n "$MAC" ] && [ "$MAC" != "none" ]; then
    MAC_CLEAN=$(echo $MAC | tr -d ':')
    ID=${MAC_CLEAN: -6}
    NEW_HOSTNAME="blk$ID"
    hostnamectl set-hostname "$NEW_HOSTNAME"
    sed -i "s/127.0.1.1.*/127.0.1.1\t$NEW_HOSTNAME/g" /etc/hosts
fi
# Disable service after execution
systemctl disable set-hostname-once.service
EOF
chmod +x /usr/local/bin/set-hostname-once.sh

cat << 'EOF' > /etc/systemd/system/set-hostname-once.service
[Unit]
Description=Set hostname based on MAC (runs once)
After=network-pre.target
Before=network.target

[Service]
Type=oneshot
ExecStart=/usr/local/bin/set-hostname-once.sh
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF

systemctl enable set-hostname-once.service
echo "   Service set-hostname-once.service installed"

# --- 2. APT CLEANUP ---
echo "2/5: Cleaning packages and APT cache..."
apt-get autoremove -y
apt-get clean

# --- 3. SYSTEM CLEANUP ---
echo "3/5: Removing unique identifiers and logs..."

# Clean systemd logs
journalctl --vacuum-time=0d

# Clean Machine ID (important for DHCP)
truncate -s 0 /etc/machine-id
rm -f /var/lib/dbus/machine-id
ln -sf /etc/machine-id /var/lib/dbus/machine-id

# Remove DHCP leases
rm -rf /var/lib/dhcp/*
rm -rf /var/lib/NetworkManager/*.lease

# Remove SSH host keys and force regeneration on boot
rm -f /etc/ssh/ssh_host_*
touch /etc/bbb.io/ssh_regenerate

# Clean text logs and tmp directories
find /var/log -type f -exec truncate -s 0 {} \;
rm -rf /tmp/*
rm -rf /var/tmp/*

# Clear Caddy certificates (so new device generates fresh certs with correct hostname)
CADDY_DATA_DIR="/home/boneio/docker/nodered/caddy/data"
CADDY_CONFIG_DIR="/home/boneio/docker/nodered/caddy/config"
if [ -d "$CADDY_DATA_DIR" ]; then
    rm -rf "$CADDY_DATA_DIR"/*
    echo "   Cleared Caddy data directory"
fi
if [ -d "$CADDY_CONFIG_DIR" ]; then
    rm -rf "$CADDY_CONFIG_DIR"/*
    echo "   Cleared Caddy config directory"
fi

# --- 4. FINALIZATION ---
echo "4/5: Shutting down system..."
echo "--------------------------------------------------------"
echo "DONE! Hostname will be set to blk[MAC] on first boot."
echo "System will shut down in 3 seconds. Then remove the card and create image."
echo "--------------------------------------------------------"

sleep 3
# Clear bash history
history -c
rm -f /root/.bash_history
rm -f /home/*/.bash_history
poweroff