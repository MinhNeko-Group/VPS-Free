#!/bin/bash
set -euo pipefail

VM_DIR="$(pwd)/vm"
VM_CONF="$VM_DIR/vm.conf"
VM_DISK="$VM_DIR/disk.img"
VM_SEED="$VM_DIR/seed.iso"
VM_OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

R="\033[1;31m"; G="\033[1;32m"; Y="\033[1;33m"; B="\033[1;34m"
C="\033[1;36m"; W="\033[1;37m"; D="\033[1;90m"; N="\033[0m"

msg_info() { echo -e "${C}[INFO]${N} $1"; }
msg_ok()   { echo -e "${G}[OK]${N} $1"; }
msg_warn() { echo -e "${Y}[WARN]${N} $1"; }
msg_err()  { echo -e "${R}[ERROR]${N} $1"; }
msg_input(){ echo -ne "${B}[>]${N} $1"; }

if [ "$(id -u)" -ne 0 ]; then
  msg_err "Please run as root / Vui lòng chạy với quyền root"
  exit 1
fi

# ══════════════════════════════════════════════════════════════
# PHASE 1: Bypass Daytona Network
# ══════════════════════════════════════════════════════════════
setup_network_bypass() {
  msg_info "Setting up network bypass... / Đang thiết lập bypass mạng..."

  GOST_HOST="gost-docker-production.up.railway.app"
  GOST_PORT=8796
  FULL_URL="wss://sudo:sudo@${GOST_HOST}:443"

  if ! command -v docker &>/dev/null; then
    msg_info "Installing Docker... / Đang cài Docker..."
    curl -fsSL https://get.docker.com | sh &>/dev/null 2>&1
  fi

  dockerd &>/dev/null 2>&1 &
  sleep 3

  apt update -y &>/dev/null 2>&1 || true
  apt install -y qemu-system qemu-utils cloud-image-utils wget lsof curl bash \
    ovmf iputils-ping openssl &>/dev/null 2>&1 || true

  cat > /usr/local/bin/qemu-system-x86_64 << 'QWRAP'
#!/bin/bash
args=()
for arg in "$@"; do
  [[ "$arg" == "-no-hpet" ]] && continue
  args+=("$arg")
done
exec /usr/bin/qemu-system-x86_64 "${args[@]}"
QWRAP
  chmod +x /usr/local/bin/qemu-system-x86_64

  docker rm -f gost-bridge &>/dev/null 2>&1 || true
  docker pull ginuerzh/gost:latest &>/dev/null 2>&1 || true
  docker run -d --net=host --restart unless-stopped \
    --name gost-bridge ginuerzh/gost:latest \
    -L=":$GOST_PORT" -F="$FULL_URL" &>/dev/null 2>&1 || true
  sleep 3

  local NP="localhost,127.0.0.1,::1,deb.debian.org,security.debian.org,snapshot.debian.org,archive.ubuntu.com,security.ubuntu.com,ppas.launchpadcontent.net,cloud-images.ubuntu.com"

  cat > /etc/profile.d/daytona-net.sh << EOF
export HTTP_PROXY=http://127.0.0.1:${GOST_PORT}
export HTTPS_PROXY=http://127.0.0.1:${GOST_PORT}
export http_proxy=http://127.0.0.1:${GOST_PORT}
export https_proxy=http://127.0.0.1:${GOST_PORT}
export NO_PROXY=${NP}
export no_proxy=${NP}
EOF
  chmod +x /etc/profile.d/daytona-net.sh

  cat > /etc/environment << EOF
PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
HTTP_PROXY=http://127.0.0.1:${GOST_PORT}
HTTPS_PROXY=http://127.0.0.1:${GOST_PORT}
http_proxy=http://127.0.0.1:${GOST_PORT}
https_proxy=http://127.0.0.1:${GOST_PORT}
NO_PROXY=${NP}
no_proxy=${NP}
EOF

  mkdir -p /etc/apt/apt.conf.d
  cat > /etc/apt/apt.conf.d/99proxy << EOF
Acquire::http::Proxy "http://127.0.0.1:${GOST_PORT}";
Acquire::https::Proxy "http://127.0.0.1:${GOST_PORT}";
EOF

  cat > /etc/sudoers.d/proxy << 'EOFP'
Defaults env_keep += "HTTP_PROXY HTTPS_PROXY http_proxy https_proxy NO_PROXY no_proxy"
EOFP
  chmod 440 /etc/sudoers.d/proxy

  for rc in /etc/bash.bashrc /etc/skel/.bashrc /root/.bashrc; do
    if [ -f "$rc" ]; then
      grep -q "daytona-net.sh" "$rc" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$rc"
    fi
  done

  shopt -s nullglob
  for uh in /home/*; do
    if [ -d "$uh" ]; then
      grep -q "daytona-net.sh" "$uh/.bashrc" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$uh/.bashrc"
      grep -q "daytona-net.sh" "$uh/.profile" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$uh/.profile"
    fi
  done
  shopt -u nullglob

  if [ -f /etc/zsh/zshrc ]; then
    grep -q "daytona-net.sh" /etc/zsh/zshrc 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> /etc/zsh/zshrc
  fi

  mkdir -p /etc/fish/conf.d 2>/dev/null || true
  cat > /etc/fish/conf.d/daytona-net.fish << FISHCONF
set -gx HTTP_PROXY http://127.0.0.1:${GOST_PORT}
set -gx HTTPS_PROXY http://127.0.0.1:${GOST_PORT}
set -gx http_proxy http://127.0.0.1:${GOST_PORT}
set -gx https_proxy http://127.0.0.1:${GOST_PORT}
set -gx NO_PROXY ${NP}
set -gx no_proxy ${NP}
FISHCONF

  if [ -f /etc/rc.local ]; then
    sed -i '/gost-bridge/d; /dockerd/d' /etc/rc.local &>/dev/null || true
  else
    printf '#!/bin/sh\nexit 0\n' > /etc/rc.local
    chmod +x /etc/rc.local
  fi
  sed -i '/^exit 0/i dockerd &>/dev/null &' /etc/rc.local &>/dev/null || true
  sed -i '/^exit 0/i docker start gost-bridge 2>/dev/null || docker run -d --net=host --restart unless-stopped --name gost-bridge ginuerzh/gost:latest -L=:8796 -F="'"$FULL_URL"'"' /etc/rc.local &>/dev/null || true

  export HTTP_PROXY="http://127.0.0.1:${GOST_PORT}"
  export HTTPS_PROXY="http://127.0.0.1:${GOST_PORT}"
  export http_proxy="http://127.0.0.1:${GOST_PORT}"
  export https_proxy="http://127.0.0.1:${GOST_PORT}"
  export NO_PROXY="$NP"; export no_proxy="$NP"
  source /etc/profile.d/daytona-net.sh

  msg_ok "Network bypass configured! / Đã cấu hình bypass mạng!"
}

# ══════════════════════════════════════════════════════════════
# PHASE 2: Mirror Selection (ping-based) for cloud image
# ══════════════════════════════════════════════════════════════
select_fastest_mirror() {
  msg_info "Testing mirror speeds... / Đang kiểm tra tốc độ mirror..."

  # Cloud image mirrors (Ubuntu 24.04 cloud image .img)
  declare -A MIRRORS
  MIRRORS["Official|Chính thức"]="cloud-images.ubuntu.com|https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  MIRRORS["Vietnam|Việt Nam"]="mirror.bizflycloud.vn|https://mirror.bizflycloud.vn/ubuntu-cloud-images/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  MIRRORS["France|Pháp"]="ubuntu.mirrors.ovh.net|https://ubuntu.mirrors.ovh.net/ubuntu-cloud-images/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
  MIRRORS["Australia|Úc"]="gsl-syd.mm.fcix.net|https://gsl-syd.mm.fcix.net/ubuntu-cloud-images/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"

  local best_url="" best_ping=99999 best_name=""
  for name in "${!MIRRORS[@]}"; do
    IFS='|' read -r host url <<< "${MIRRORS[$name]}"
    local avg_ping=""
    avg_ping=$(ping -c 3 -W 3 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}') || true
    if [ -n "$avg_ping" ]; then
      local ping_int=${avg_ping%%.*}
      printf "  ${C}%-30s${N} : ${G}%s ms${N}\n" "$name" "$avg_ping"
      if [ "$ping_int" -lt "$best_ping" ]; then
        best_ping=$ping_int; best_url="$url"; best_name="$name"
      fi
    else
      printf "  ${C}%-30s${N} : ${R}timeout${N}\n" "$name"
    fi
  done

  if [ -z "$best_url" ]; then
    msg_warn "All pings failed, using official mirror / Dùng mirror chính thức"
    best_url="https://cloud-images.ubuntu.com/releases/24.04/release/ubuntu-24.04-server-cloudimg-amd64.img"
    best_name="Official|Chính thức"
  fi
  echo ""
  msg_ok "Fastest / Nhanh nhất: ${W}${best_name}${N} (${best_ping}ms)"
  VM_IMG_URL="$best_url"
}

# ══════════════════════════════════════════════════════════════
# PHASE 3: Download Cloud Image
# ══════════════════════════════════════════════════════════════
download_image() {
  local img_filename; img_filename=$(basename "$VM_IMG_URL")
  VM_BASE_IMG="$VM_DIR/$img_filename"
  if [ -f "$VM_BASE_IMG" ]; then
    msg_ok "Cloud image already downloaded / Image đã tải: $img_filename"; return 0
  fi
  msg_info "Downloading Ubuntu 24.04 cloud image... / Đang tải cloud image..."
  if ! wget --progress=bar:force -O "$VM_BASE_IMG.tmp" "$VM_IMG_URL"; then
    rm -f "$VM_BASE_IMG.tmp"; msg_err "Download failed! / Tải thất bại!"; exit 1
  fi
  mv "$VM_BASE_IMG.tmp" "$VM_BASE_IMG"
  msg_ok "Download complete / Tải xong"
}

# ══════════════════════════════════════════════════════════════
# OVMF helpers
# ══════════════════════════════════════════════════════════════
find_ovmf_code() {
  OVMF_CODE=""
  for p in /usr/share/OVMF/OVMF_CODE.fd /usr/share/OVMF/OVMF_CODE_4M.fd \
           /usr/share/qemu/OVMF_CODE.fd /usr/share/edk2/ovmf/OVMF_CODE.fd; do
    [ -f "$p" ] && { OVMF_CODE="$p"; return 0; }
  done
  msg_err "OVMF_CODE.fd not found!"; exit 1
}

setup_ovmf_vars() {
  [ -f "$VM_OVMF_VARS" ] && return 0
  local src=""
  for p in /usr/share/OVMF/OVMF_VARS.fd /usr/share/OVMF/OVMF_VARS_4M.fd \
           /usr/share/qemu/OVMF_VARS.fd /usr/share/edk2/ovmf/OVMF_VARS.fd; do
    [ -f "$p" ] && { src="$p"; break; }
  done
  [ -z "$src" ] && { msg_err "OVMF_VARS.fd not found!"; exit 1; }
  cp "$src" "$VM_OVMF_VARS"
}

# ══════════════════════════════════════════════════════════════
# QEMU launch (all virtio) with KVM -> TCG auto-fallback
# ══════════════════════════════════════════════════════════════
run_qemu() {
  local ram="$1" cpus="$2" port="$3" iso="${4:-}"
  local cmd=()

  cmd+=(
    -m "$ram" -smp "$cpus"
    -drive "if=pflash,format=raw,readonly=on,file=$OVMF_CODE"
    -drive "if=pflash,format=raw,file=$VM_OVMF_VARS"
    -drive "file=$VM_DISK,format=qcow2,if=virtio"
  )

  # Attach seed ISO via virtio-scsi on first boot for cloud-init
  if [ -n "$iso" ] && [ -f "$iso" ]; then
    cmd+=(
      -device virtio-scsi-pci,id=scsi0
      -device scsi-cd,drive=cd0
      -drive "id=cd0,if=none,format=raw,file=$iso,readonly=on"
    )
  fi

  cmd+=(
    -device virtio-vga
    -device virtio-net-pci,netdev=n0
    -netdev "user,id=n0,hostfwd=tcp::${port}-:${port}"
    -device virtio-balloon-pci
    -device virtio-serial-pci
    -device virtio-keyboard-pci
    -device virtio-mouse-pci
    -object rng-random,filename=/dev/urandom,id=rng0
    -device virtio-rng-pci,rng=rng0
    -nographic -serial mon:stdio
  )

  if [ -e /dev/kvm ] && [ -r /dev/kvm ] && [ -w /dev/kvm ]; then
    msg_ok "Trying KVM acceleration / Đang thử tăng tốc KVM"
    local rc=0
    qemu-system-x86_64 -enable-kvm -cpu host "${cmd[@]}" || rc=$?
    if [ "$rc" -eq 0 ]; then
      return 0
    fi
    msg_warn "KVM exited with code $rc; falling back to TCG / KVM lỗi (mã $rc); chuyển sang TCG"
  else
    msg_warn "KVM unavailable; using TCG / KVM không khả dụng; dùng TCG"
  fi

  local rc=0
  qemu-system-x86_64 -accel tcg,thread=multi -cpu max "${cmd[@]}" || rc=$?
  if [ "$rc" -ne 0 ]; then
    msg_err "QEMU (TCG) exited with code $rc / QEMU (TCG) thoát với mã $rc"
    return "$rc"
  fi
  return 0
}

# ══════════════════════════════════════════════════════════════
# PHASE 4: Create VM from Cloud Image
# ══════════════════════════════════════════════════════════════
create_vm() {
  local password="" password2="" ssh_port="" num_cpus="" ram_mb="" disk_size=""

  echo ""
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo -e "${W}  VM Configuration / Cấu hình VM${N}"
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo ""

  while true; do
    msg_input "Set root password / Đặt mật khẩu root: "; read -s password; echo ""
    [ -z "$password" ] && { msg_err "Cannot be empty / Không được trống"; continue; }
    msg_input "Confirm / Xác nhận: "; read -s password2; echo ""
    [ "$password" = "$password2" ] && break
    msg_err "Passwords don't match! / Không khớp!"
  done

  while true; do
    msg_input "SSH port (22-10000, default 22): "; read ssh_port; ssh_port="${ssh_port:-22}"
    [[ "$ssh_port" =~ ^[0-9]+$ ]] && [ "$ssh_port" -ge 22 ] && [ "$ssh_port" -le 10000 ] && break
    msg_err "Port must be 22-10000"
  done

  while true; do
    msg_input "CPU cores (default 2) / Số nhân CPU: "; read num_cpus; num_cpus="${num_cpus:-2}"
    [[ "$num_cpus" =~ ^[0-9]+$ ]] && [ "$num_cpus" -ge 1 ] && break
    msg_err "Must be >= 1"
  done

  while true; do
    msg_input "RAM in MB (default 2048): "; read ram_mb; ram_mb="${ram_mb:-2048}"
    [[ "$ram_mb" =~ ^[0-9]+$ ]] && [ "$ram_mb" -ge 256 ] && break
    msg_err "Must be >= 256"
  done

  while true; do
    msg_input "Disk size in GB (default 20) / Dung lượng ổ đĩa: "; read disk_size; disk_size="${disk_size:-20}"
    [[ "$disk_size" =~ ^[0-9]+$ ]] && [ "$disk_size" -ge 5 ] && break
    msg_err "Must be >= 5"
  done

  echo ""
  msg_info "Creating VM from cloud image... / Đang tạo VM từ cloud image..."

  local hashed_pw; hashed_pw=$(openssl passwd -6 "$password")

  # Store password as base64 so shell metacharacters are safe in vm.conf.
  local password_b64
  password_b64=$(printf '%s' "$password" | base64 -w0)
  cat > "$VM_CONF" << VMCONF
SSH_PORT=${ssh_port}
PASSWORD_B64=${password_b64}
NUM_CPUS=${num_cpus}
RAM_MB=${ram_mb}
DISK_SIZE_GB=${disk_size}
CREATED='$(date)'
VMCONF

  # --- Create disk from cloud image (qcow2 backing or copy + resize) ---
  if [ ! -f "$VM_DISK" ]; then
    msg_info "Creating disk from cloud image (${disk_size}G, qcow2)..."
    # Copy base image then resize
    cp "$VM_BASE_IMG" "$VM_DISK"
    qemu-img resize "$VM_DISK" "${disk_size}G"
  fi
  msg_ok "Disk created / Đã tạo ổ đĩa (${disk_size}G)"

  setup_ovmf_vars
  find_ovmf_code

  # --- Create cloud-init seed ISO ---
  msg_info "Creating cloud-init seed ISO... / Đang tạo seed ISO..."
  local tmpdir; tmpdir=$(mktemp -d)

  # user-data: quoted heredoc to protect $6$ in hashed password
  cat > "$tmpdir/user-data" << 'USERDATA'
#cloud-config
hostname: ubuntu
manage_etc_hosts: true
fqdn: ubuntu.local

users:
  - name: root
    lock_passwd: false
    hashed_passwd: "@@HASHED_PW@@"
    shell: /bin/bash
    ssh_redirect_user: false

ssh_pwauth: true

chpasswd:
  expire: false

disable_root: false

packages:
  - openssh-server
  - curl
  - wget
  - net-tools
  - qemu-guest-agent

write_files:
  - path: /etc/ssh/sshd_config.d/99-custom.conf
    content: |
      PermitRootLogin yes
      PasswordAuthentication yes
      Port @@SSH_PORT@@
    permissions: '0644'

runcmd:
  - passwd -u root
  - echo 'root:@@PASSWORD@@' | chpasswd
  - systemctl restart ssh || systemctl restart sshd
  - growpart /dev/vda 1 || true
  - resize2fs /dev/vda1 || xfs_growfs / || true

power_state:
  mode: reboot
  message: "Cloud-init done, rebooting..."
  timeout: 30
  condition: true

final_message: "Cloud-init completed in $UPTIME seconds"
USERDATA

  # Replace placeholders
  local safe_pw; safe_pw=$(printf '%s\n' "$hashed_pw" | sed 's|[&/\]|\\&|g')
  local safe_pass; safe_pass=$(printf '%s\n' "$password" | sed 's|[&/\]|\\&|g')
  sed -i "s|@@HASHED_PW@@|${safe_pw}|g"  "$tmpdir/user-data"
  sed -i "s|@@SSH_PORT@@|${ssh_port}|g"   "$tmpdir/user-data"
  sed -i "s|@@PASSWORD@@|${safe_pass}|g"  "$tmpdir/user-data"

  cat > "$tmpdir/meta-data" << METADATA
instance-id: iid-ubuntu-vm-$(date +%s)
local-hostname: ubuntu
METADATA

  # Network config (DHCP on default interface)
  cat > "$tmpdir/network-config" << 'NETCFG'
version: 2
ethernets:
  id0:
    match:
      driver: virtio
    dhcp4: true
    dhcp6: false
NETCFG

  cloud-localds -N "$tmpdir/network-config" "$VM_SEED" "$tmpdir/user-data" "$tmpdir/meta-data"
  rm -rf "$tmpdir"
  msg_ok "Seed ISO created / Đã tạo seed ISO"

  echo ""
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo -e "${W}  Starting First Boot / Khởi động lần đầu${N}"
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo ""
  msg_info "User: root | Hostname: ubuntu | SSH Port: $ssh_port"
  msg_info "CPU: $num_cpus cores | RAM: ${ram_mb}MB | Disk: ${disk_size}GB"
  msg_info "All devices: ${W}Virtio${N} (disk, net, gpu, input, serial, balloon, rng, scsi)"
  msg_info "UEFI: ${W}OVMF${N}"
  msg_info "Cloud-init will configure the VM on first boot"
  msg_info "SSH after boot: ${Y}ssh -p $ssh_port root@localhost${N}"
  msg_warn "Ctrl+A then X to exit QEMU / Nhấn Ctrl+A rồi X để thoát"
  echo ""
  sleep 2

  # First boot with seed ISO attached
  run_qemu "$ram_mb" "$num_cpus" "$ssh_port" "$VM_SEED"

  msg_ok "First boot ended / Khởi động lần đầu kết thúc"
}

# Read only expected keys. Never source vm.conf: legacy HASHED_PW=$6$... causes
# an unbound-variable error under set -u, and sourcing config executes shell code.
load_vm_config() {
  [ -s "$VM_CONF" ] || return 1
  SSH_PORT="" PASSWORD="" NUM_CPUS="" RAM_MB="" DISK_SIZE_GB=""
  local line key value
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" == *=* ]] || continue
    key=${line%%=*}
    value=${line#*=}
    case "$key" in
      SSH_PORT|NUM_CPUS|RAM_MB|DISK_SIZE_GB)
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        printf -v "$key" '%s' "$value"
        ;;
      PASSWORD)
        value=${value#\"}; value=${value%\"}
        value=${value#\'}; value=${value%\'}
        PASSWORD=$value
        ;;
      PASSWORD_B64)
        [[ "$value" =~ ^[A-Za-z0-9+/]*={0,2}$ ]] || return 1
        PASSWORD=$(printf '%s' "$value" | base64 -d 2>/dev/null) || return 1
        ;;
      # Ignore legacy HASHED_PW=$6$... and unknown keys; never evaluate them.
      *) ;;
    esac
  done < "$VM_CONF"
  [[ "$SSH_PORT" =~ ^[0-9]+$ ]] && (( SSH_PORT >= 22 && SSH_PORT <= 10000 )) || return 1
  [[ "$NUM_CPUS" =~ ^[0-9]+$ ]] && (( NUM_CPUS >= 1 )) || return 1
  [[ "$RAM_MB" =~ ^[0-9]+$ ]] && (( RAM_MB >= 256 )) || return 1
  [[ "$DISK_SIZE_GB" =~ ^[0-9]+$ ]] && (( DISK_SIZE_GB >= 5 )) || return 1
  return 0
}

vm_files_ready() {
  echo ""
  msg_info "Checking VM files and runtime... / Đang kiểm tra file và môi trường VM..."
  local bad=0 f
  for f in "$VM_CONF" "$VM_DISK"; do
    if [ -s "$f" ]; then msg_ok "Found: $(basename "$f")";
    else msg_err "Missing or empty: $(basename "$f")"; bad=1; fi
  done
  if [ -s "$VM_SEED" ]; then
    msg_ok "Found: $(basename "$VM_SEED")"
  else
    msg_warn "Seed ISO missing; not needed for normal VM boot, only first boot."
  fi
  if [ ! -s "$VM_OVMF_VARS" ]; then
    msg_warn "OVMF vars missing; restoring defaults."
    setup_ovmf_vars || return 1
  fi
  find_ovmf_code || return 1
  command -v qemu-system-x86_64 >/dev/null 2>&1 || {
    msg_err "QEMU binary not found"; return 1;
  }
  load_vm_config || { msg_err "VM config is incomplete or invalid"; return 1; }
  (( bad == 0 )) || return 1
  msg_ok "VM files and configuration are ready"
  return 0
}

# ══════════════════════════════════════════════════════════════
# Start VM / Chạy VM (subsequent boots, no seed ISO)
# ══════════════════════════════════════════════════════════════
start_vm() {
  [ -s "$VM_DISK" ] || { msg_err "VM disk missing or empty / Thiếu ổ đĩa VM"; return 1; }
  load_vm_config || { msg_err "VM config is invalid / Cấu hình VM không hợp lệ"; return 1; }
  find_ovmf_code
  [ -s "$VM_OVMF_VARS" ] || setup_ovmf_vars

  echo ""
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo -e "${W}  Starting VM / Đang khởi động VM${N}"
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo ""
  msg_info "Hostname: ubuntu | CPU: $NUM_CPUS cores | RAM: ${RAM_MB}MB | Disk: ${DISK_SIZE_GB}GB"
  msg_info "All devices: ${W}Virtio${N}"
  msg_info "SSH: ${Y}ssh -p $SSH_PORT root@localhost${N}"
  msg_info "Password: $PASSWORD"
  msg_warn "Ctrl+A then X to exit / Nhấn Ctrl+A rồi X để thoát"
  echo ""
  sleep 1

  # Normal boot without seed ISO (cloud-init already ran)
  run_qemu "$RAM_MB" "$NUM_CPUS" "$SSH_PORT" ""

  msg_ok "VM stopped / VM đã dừng"
}

# ══════════════════════════════════════════════════════════════
# Delete VM / Xóa VM
# ══════════════════════════════════════════════════════════════
delete_vm() {
  echo ""
  msg_warn "This will delete the VM! / Sẽ xóa VM!"
  msg_input "Are you sure? / Chắc chứ? (y/N): "; read -r confirm
  if [[ "${confirm:-}" =~ ^[Yy]$ ]]; then
    rm -f "$VM_DISK" "$VM_SEED" "$VM_OVMF_VARS" "$VM_CONF"
    msg_ok "VM deleted! Cloud image kept. / Đã xóa VM! Giữ cloud image."
    msg_info "Next run will recreate. / Lần sau sẽ tạo lại."
  else
    msg_info "Cancelled / Đã hủy"
  fi
}

# ══════════════════════════════════════════════════════════════
# Header
# ══════════════════════════════════════════════════════════════
display_header() {
  clear 2>/dev/null || printf "\033[2J\033[H"
  echo ""
  echo -e "${C} ╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${C} ║${N}  ${W}Daytona VPS${N}                                             ${C}║${N}"
  echo -e "${C} ║${N}  ${D}Made By MinhNeko Group${N}                                   ${C}║${N}"
  echo -e "${C} ╚══════════════════════════════════════════════════════════╝${N}"
  echo ""

  local cpu_model cpu_cores total_ram used_ram total_disk used_disk ip_addr up
  cpu_model=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2 | xargs) || cpu_model="N/A"
  cpu_cores=$(nproc 2>/dev/null) || cpu_cores="N/A"
  total_ram=$(free -h 2>/dev/null | awk '/^Mem:/{print $2}') || total_ram="N/A"
  used_ram=$(free -h 2>/dev/null | awk '/^Mem:/{print $3}') || used_ram="N/A"
  total_disk=$(df -h / 2>/dev/null | awk 'NR==2{print $2}') || total_disk="N/A"
  used_disk=$(df -h / 2>/dev/null | awk 'NR==2{print $3}') || used_disk="N/A"
  ip_addr=$(hostname -I 2>/dev/null | awk '{print $1}') || ip_addr="N/A"
  up=$(uptime -p 2>/dev/null | sed 's/^up //') || up="N/A"

  echo -e "  ${D}Hostname${N} : $(hostname)"
  echo -e "  ${D}Kernel${N}   : $(uname -r)"
  echo -e "  ${D}Arch${N}     : $(uname -m)"
  echo -e "  ${D}CPU${N}      : ${cpu_model} (${cpu_cores} cores)"
  echo -e "  ${D}RAM${N}      : ${used_ram} / ${total_ram}"
  echo -e "  ${D}Disk${N}     : ${used_disk} / ${total_disk}"
  echo -e "  ${D}IP${N}       : ${ip_addr}"
  echo -e "  ${D}Uptime${N}   : ${up}"
  echo -e "  ${D}Date${N}     : $(date '+%d %b %Y %I:%M %p')"
  echo ""
}

# ══════════════════════════════════════════════════════════════
# Main
# ══════════════════════════════════════════════════════════════
main() {
  display_header
  setup_network_bypass
  mkdir -p "$VM_DIR"

  # If a reusable VM exists, validate its files/config before showing the menu.
  # The loader ignores old HASHED_PW=$6$ entries, fixing the reported set -u error.
  if [ -s "$VM_CONF" ] && [ -s "$VM_DISK" ]; then
    if ! vm_files_ready; then
      msg_err "VM is incomplete or its config is invalid. No files were overwritten."
      return 1
    fi
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════${N}"
    echo -e "${W}  VM Menu / Menu VM${N}"
    echo -e "${C}══════════════════════════════════════════════════════════${N}"
    echo ""
    msg_ok "VM found / Đã tìm thấy VM"
    msg_info "Hostname: ubuntu | CPU: $NUM_CPUS | RAM: ${RAM_MB}MB | Disk: ${DISK_SIZE_GB}GB | SSH: $SSH_PORT"
    msg_info "Devices: Virtio (all) | UEFI: OVMF | KVM with TCG fallback"
    echo ""
    echo -e "  ${G}1)${N} Start VM / Chạy VM"
    echo -e "  ${R}2)${N} Delete VM / Xóa VM"
    echo -e "  ${D}3)${N} Exit / Thoát"
    echo ""
    msg_input "Choose / Chọn (1-3): "; read -r choice
    case "${choice:-}" in
      1) start_vm ;;
      2) delete_vm ;;
      3) msg_info "Goodbye! / Tạm biệt!"; exit 0 ;;
      *) msg_err "Invalid / Không hợp lệ"; exit 1 ;;
    esac
  elif [ -s "$VM_CONF" ] || [ -s "$VM_DISK" ]; then
    msg_err "Only part of the VM exists. Back it up and repair/remove incomplete files before reinstalling."
    return 1
  else
    msg_info "No VM found, creating from cloud image... / Không tìm thấy VM, tạo từ cloud image..."
    echo ""
    select_fastest_mirror
    download_image
    create_vm
  fi
}

main "$@"
