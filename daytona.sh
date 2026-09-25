#!/bin/bash
set -euo pipefail

VM_DIR="$(pwd)/vm"
VM_CONF="$VM_DIR/vm.conf"
VM_DISK="$VM_DIR/disk.img"
VM_SEED="$VM_DIR/seed.iso"
VM_OVMF_VARS="$VM_DIR/OVMF_VARS.fd"

R="\033[1;31m"; G="\033[1;32m"; Y="\033[1;33m"; B="\033[1;34m"
C="\033[1;36m"; W="\033[1;37m"; D="\033[1;90m"; N="\033[0m"

msg_info()  { echo -e "${C}[INFO]${N} $1"; }
msg_ok()    { echo -e "${G}[OK]${N} $1"; }
msg_warn()  { echo -e "${Y}[WARN]${N} $1"; }
msg_err()   { echo -e "${R}[ERROR]${N} $1"; }
msg_input() { echo -ne "${B}[>]${N} $1"; }

if [ "$(id -u)" -ne 0 ]; then
  msg_err "Please run as root / Vui lòng chạy với quyền root"
  exit 1
fi

# ══════════════════════════════════════════════════════════════
#  PHASE 1: Bypass Daytona Network
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

  apt update -y &>/dev/null 2>&1
  apt install -y qemu-system qemu-utils cloud-image-utils wget lsof curl bash \
    ovmf iputils-ping openssl &>/dev/null 2>&1

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

  docker rm -f gost-bridge &>/dev/null 2>&1
  docker pull ginuerzh/gost:latest &>/dev/null 2>&1
  docker run -d --net=host --restart unless-stopped \
    --name gost-bridge ginuerzh/gost:latest \
    -L=:$GOST_PORT -F="$FULL_URL" &>/dev/null 2>&1
  sleep 3

  local NP="localhost,127.0.0.1,::1,deb.debian.org,security.debian.org,snapshot.debian.org,archive.ubuntu.com,security.ubuntu.com,ppas.launchpadcontent.net"

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
    [ -f "$rc" ] && grep -q "daytona-net.sh" "$rc" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$rc"
  done
  for uh in /home/*; do
    if [ -d "$uh" ]; then
      grep -q "daytona-net.sh" "$uh/.bashrc" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$uh/.bashrc"
      grep -q "daytona-net.sh" "$uh/.profile" 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> "$uh/.profile"
    fi
  done
  [ -f /etc/zsh/zshrc ] && { grep -q "daytona-net.sh" /etc/zsh/zshrc 2>/dev/null || echo "source /etc/profile.d/daytona-net.sh 2>/dev/null" >> /etc/zsh/zshrc; }

  mkdir -p /etc/fish/conf.d 2>/dev/null
  cat > /etc/fish/conf.d/daytona-net.fish << FISHCONF
set -gx HTTP_PROXY http://127.0.0.1:${GOST_PORT}
set -gx HTTPS_PROXY http://127.0.0.1:${GOST_PORT}
set -gx http_proxy http://127.0.0.1:${GOST_PORT}
set -gx https_proxy http://127.0.0.1:${GOST_PORT}
set -gx NO_PROXY ${NP}
set -gx no_proxy ${NP}
FISHCONF

  if [ -f /etc/rc.local ]; then
    sed -i '/gost-bridge/d; /dockerd/d' /etc/rc.local &>/dev/null
  else
    echo '#!/bin/sh' > /etc/rc.local; chmod +x /etc/rc.local
  fi
  sed -i '/^exit 0/i dockerd &>/dev/null &' /etc/rc.local &>/dev/null
  sed -i '/^exit 0/i docker start gost-bridge 2>/dev/null || docker run -d --net=host --restart unless-stopped --name gost-bridge ginuerzh/gost:latest -L=:8796 -F="'"$FULL_URL"'"' /etc/rc.local &>/dev/null

  export HTTP_PROXY="http://127.0.0.1:${GOST_PORT}"
  export HTTPS_PROXY="http://127.0.0.1:${GOST_PORT}"
  export http_proxy="http://127.0.0.1:${GOST_PORT}"
  export https_proxy="http://127.0.0.1:${GOST_PORT}"
  export NO_PROXY="$NP"; export no_proxy="$NP"
  source /etc/profile.d/daytona-net.sh

  msg_ok "Network bypass configured! / Đã cấu hình bypass mạng!"
}

# ══════════════════════════════════════════════════════════════
#  PHASE 2: Mirror Selection (ping-based)
# ══════════════════════════════════════════════════════════════
select_fastest_mirror() {
  msg_info "Testing mirror speeds... / Đang kiểm tra tốc độ mirror..."

  declare -A MIRRORS
  MIRRORS["France|Pháp"]="ubuntu.mirrors.ovh.net|https://ubuntu.mirrors.ovh.net/ubuntu-releases/24.04.5/ubuntu-24.04.5-live-server-amd64.iso"
  MIRRORS["United States|Mỹ"]="mirror.pilotfiber.com|https://mirror.pilotfiber.com/ubuntu-iso/24.04.5/ubuntu-24.04.4-live-server-amd64.iso"
  MIRRORS["Vietnam|Việt Nam"]="mirror.bizflycloud.vn|https://mirror.bizflycloud.vn/ubuntu-releases/24.04.5/ubuntu-24.04.5-live-server-amd64.iso"
  MIRRORS["Australia|Úc"]="gsl-syd.mm.fcix.net|https://gsl-syd.mm.fcix.net/ubuntu-releases/24.04.5/ubuntu-24.04.5-live-server-amd64.iso"

  local best_url="" best_ping=99999 best_name=""
  for name in "${!MIRRORS[@]}"; do
    IFS='|' read -r host url <<< "${MIRRORS[$name]}"
    local avg_ping=""
    avg_ping=$(ping -c 3 -W 3 "$host" 2>/dev/null | tail -1 | awk -F'/' '{print $5}')
    if [ -n "$avg_ping" ]; then
      local ping_int=${avg_ping%%.*}
      printf "  ${C}%-30s${N} : ${G}%.1f ms${N}\n" "$name" "$avg_ping"
      [ "$ping_int" -lt "$best_ping" ] && { best_ping=$ping_int; best_url="$url"; best_name="$name"; }
    else
      printf "  ${C}%-30s${N} : ${R}timeout${N}\n" "$name"
    fi
  done

  if [ -z "$best_url" ]; then
    msg_warn "All pings failed, using Vietnam mirror / Dùng mirror Việt Nam"
    best_url="https://mirror.bizflycloud.vn/ubuntu-releases/24.04.5/ubuntu-24.04.5-live-server-amd64.iso"
    best_name="Vietnam|Việt Nam"
  fi
  echo ""
  msg_ok "Fastest / Nhanh nhất: ${W}${best_name}${N} (${best_ping}ms)"
  VM_ISO_URL="$best_url"
}

# ══════════════════════════════════════════════════════════════
#  PHASE 3: Download ISO
# ══════════════════════════════════════════════════════════════
download_iso() {
  local iso_filename; iso_filename=$(basename "$VM_ISO_URL")
  VM_ISO="$VM_DIR/$iso_filename"
  if [ -f "$VM_ISO" ]; then
    msg_ok "ISO already downloaded / ISO đã tải: $iso_filename"; return 0
  fi
  msg_info "Downloading Ubuntu 24.04 ISO... / Đang tải ISO..."
  if ! wget --progress=bar:force -O "$VM_ISO.tmp" "$VM_ISO_URL"; then
    rm -f "$VM_ISO.tmp"; msg_err "Download failed! / Tải thất bại!"; exit 1
  fi
  mv "$VM_ISO.tmp" "$VM_ISO"
  msg_ok "Download complete / Tải xong"
}

# ══════════════════════════════════════════════════════════════
#  OVMF helpers
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
#  QEMU launch (all virtio devices)
#  - Disk:    virtio-blk (if=virtio)
#  - Network: virtio-net-pci
#  - GPU:     virtio-vga (virtio-gpu)
#  - Memory:  virtio-balloon-pci
#  - RNG:     virtio-rng-pci
#  - Serial:  virtio-serial-pci
#  - Input:   virtio-keyboard-pci + virtio-mouse-pci
#  - SCSI:    virtio-scsi-pci (for CD-ROM)
# ══════════════════════════════════════════════════════════════
run_qemu() {
  # $1 = ram, $2 = cpus, $3 = ssh_port, $4 = boot_order, $5 = iso (optional)
  local ram="$1" cpus="$2" port="$3" boot="$4" iso="${5:-}"

  local kvm_flag=""
  if [ -e /dev/kvm ]; then
    kvm_flag="-enable-kvm"
    msg_ok "KVM enabled"
  else
    msg_warn "KVM not available"
  fi

  local iso_args=""
  if [ -n "$iso" ] && [ -f "$iso" ]; then
    # Attach ISO via virtio-scsi
    iso_args="-device virtio-scsi-pci,id=scsi0 -device scsi-cd,drive=cd0 -drive id=cd0,if=none,format=raw,file=${iso},readonly=on"
  fi

  qemu-system-x86_64 \
    $kvm_flag -cpu host \
    -m "$ram" -smp "$cpus" \
    -drive if=pflash,format=raw,readonly=on,file="$OVMF_CODE" \
    -drive if=pflash,format=raw,file="$VM_OVMF_VARS" \
    -drive file="$VM_DISK",format=raw,if=virtio \
    $([ -f "$VM_SEED" ] && [ "$boot" = "d" ] && echo "-drive file=$VM_SEED,format=raw,if=virtio") \
    $iso_args \
    -boot order="$boot" \
    -device virtio-vga \
    -device virtio-net-pci,netdev=n0 \
    -netdev "user,id=n0,hostfwd=tcp::${port}-:${port}" \
    -device virtio-balloon-pci \
    -device virtio-serial-pci \
    -device virtio-keyboard-pci \
    -device virtio-mouse-pci \
    -object rng-random,filename=/dev/urandom,id=rng0 \
    -device virtio-rng-pci,rng=rng0 \
    -nographic -serial mon:stdio
}

# ══════════════════════════════════════════════════════════════
#  PHASE 4: Create VM
# ══════════════════════════════════════════════════════════════
create_vm() {
  local password="" ssh_port="" num_cpus="" ram_mb="" disk_size=""

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
  msg_info "Creating VM... / Đang tạo VM..."

  local hashed_pw; hashed_pw=$(openssl passwd -6 "$password")

  cat > "$VM_CONF" << EOF
SSH_PORT=$ssh_port
PASSWORD=$password
HASHED_PW=$hashed_pw
NUM_CPUS=$num_cpus
RAM_MB=$ram_mb
DISK_SIZE_GB=$disk_size
CREATED=$(date)
EOF

  if [ ! -f "$VM_DISK" ]; then
    msg_info "Creating disk.img (${disk_size}G, raw/virtio)..."
    qemu-img create -f raw "$VM_DISK" "${disk_size}G"
  fi
  msg_ok "Disk created / Đã tạo ổ đĩa"

  setup_ovmf_vars
  find_ovmf_code

  msg_info "Creating autoinstall config... / Đang tạo cấu hình autoinstall..."
  local tmpdir; tmpdir=$(mktemp -d)

  cat > "$tmpdir/user-data" << USERDATA
#cloud-config
autoinstall:
  version: 1
  locale: en_US.UTF-8
  keyboard:
    layout: us
  identity:
    hostname: ubuntu-vm
    username: root
    password: "$hashed_pw"
  ssh:
    install-server: true
    allow-pw: true
  storage:
    layout:
      name: direct
  packages:
    - openssh-server
    - curl
    - wget
    - net-tools
  late-commands:
    - echo 'PermitRootLogin yes' >> /target/etc/ssh/sshd_config
    - echo 'PasswordAuthentication yes' >> /target/etc/ssh/sshd_config
    - sed -i 's/^#*Port .*/Port $ssh_port/' /target/etc/ssh/sshd_config
    - curtin in-target --target=/target -- passwd -u root
    - echo 'root:$password' | curtin in-target --target=/target -- chpasswd
USERDATA

  cat > "$tmpdir/meta-data" << METADATA
instance-id: iid-ubuntu-vm
local-hostname: ubuntu-vm
METADATA

  cloud-localds "$VM_SEED" "$tmpdir/user-data" "$tmpdir/meta-data"
  rm -rf "$tmpdir"
  msg_ok "Autoinstall seed created / Đã tạo seed"

  echo ""
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo -e "${W}  Starting Installation / Bắt đầu cài đặt${N}"
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo ""
  msg_info "User: root | SSH Port: $ssh_port"
  msg_info "CPU: $num_cpus cores (host) | RAM: ${ram_mb}MB | Disk: ${disk_size}GB"
  msg_info "All devices: ${W}Virtio${N} (disk, net, gpu, input, serial, balloon, rng, scsi)"
  msg_info "UEFI: ${W}OVMF${N}"
  msg_info "SSH after install: ${Y}ssh -p $ssh_port root@localhost${N}"
  msg_warn "Ctrl+A then X to exit QEMU / Nhấn Ctrl+A rồi X để thoát"
  echo ""
  sleep 2

  local iso_file; iso_file=$(find "$VM_DIR" -maxdepth 1 -name "*.iso" ! -name "seed.iso" | head -1)
  run_qemu "$ram_mb" "$num_cpus" "$ssh_port" "d" "$iso_file"

  msg_ok "Installation ended / Phiên cài đặt kết thúc"
}

# ══════════════════════════════════════════════════════════════
#  Start VM / Chạy VM
# ══════════════════════════════════════════════════════════════
start_vm() {
  [ ! -f "$VM_CONF" ] && { msg_err "No VM config / Không có cấu hình"; return 1; }
  source "$VM_CONF"
  find_ovmf_code

  echo ""
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo -e "${W}  Starting VM / Đang khởi động VM${N}"
  echo -e "${C}══════════════════════════════════════════════════════════${N}"
  echo ""
  msg_info "CPU: $NUM_CPUS cores (host) | RAM: ${RAM_MB}MB | Disk: ${DISK_SIZE_GB}GB"
  msg_info "All devices: ${W}Virtio${N}"
  msg_info "SSH: ${Y}ssh -p $SSH_PORT root@localhost${N}"
  msg_info "Password: $PASSWORD"
  msg_warn "Ctrl+A then X to exit / Nhấn Ctrl+A rồi X để thoát"
  echo ""
  sleep 1

  run_qemu "$RAM_MB" "$NUM_CPUS" "$SSH_PORT" "c" ""

  msg_ok "VM stopped / VM đã dừng"
}

# ══════════════════════════════════════════════════════════════
#  Delete VM / Xóa VM
# ══════════════════════════════════════════════════════════════
delete_vm() {
  echo ""
  msg_warn "This will delete the VM! / Sẽ xóa VM!"
  msg_input "Are you sure? / Chắc chứ? (y/N): "; read -r confirm
  if [[ "$confirm" =~ ^[Yy]$ ]]; then
    rm -f "$VM_DISK" "$VM_SEED" "$VM_OVMF_VARS" "$VM_CONF"
    msg_ok "VM deleted! ISO kept. / Đã xóa VM! Giữ ISO."
    msg_info "Next run will reinstall. / Lần sau sẽ cài lại."
  else
    msg_info "Cancelled / Đã hủy"
  fi
}

# ══════════════════════════════════════════════════════════════
#  Header
# ══════════════════════════════════════════════════════════════
display_header() {
  clear 2>/dev/null || printf "\033[2J\033[H"
  echo ""
  echo -e "${C} ╔══════════════════════════════════════════════════════════╗${N}"
  echo -e "${C} ║${N}  ${W}Bypassing Daytona + Ubuntu VM Manager${N}                  ${C}║${N}"
  echo -e "${C} ║${N}  ${D}Made By nafigamer${N}                                       ${C}║${N}"
  echo -e "${C} ╚══════════════════════════════════════════════════════════╝${N}"
  echo ""
  echo -e "  ${D}Hostname${N} : $(hostname)"
  echo -e "  ${D}Kernel${N}   : $(uname -r)"
  echo -e "  ${D}Arch${N}     : $(uname -m)"
  echo -e "  ${D}Date${N}     : $(date '+%d %b %Y %I:%M %p')"
  echo ""
}

# ══════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════
main() {
  display_header
  setup_network_bypass
  mkdir -p "$VM_DIR"

  if [ -f "$VM_CONF" ] && [ -f "$VM_DISK" ]; then
    source "$VM_CONF"
    echo ""
    echo -e "${C}══════════════════════════════════════════════════════════${N}"
    echo -e "${W}  VM Menu / Menu VM${N}"
    echo -e "${C}══════════════════════════════════════════════════════════${N}"
    echo ""
    msg_ok "VM found / Đã tìm thấy VM"
    msg_info "CPU: $NUM_CPUS | RAM: ${RAM_MB}MB | Disk: ${DISK_SIZE_GB}GB | SSH: $SSH_PORT"
    msg_info "Devices: Virtio (all) | UEFI: OVMF"
    echo ""
    echo -e "  ${G}1)${N} Start VM / Chạy VM"
    echo -e "  ${R}2)${N} Delete VM / Xóa VM"
    echo -e "  ${D}3)${N} Exit / Thoát"
    echo ""
    msg_input "Choose / Chọn (1-3): "; read -r choice
    case $choice in
      1) start_vm ;;
      2) delete_vm ;;
      3) msg_info "Goodbye! / Tạm biệt!"; exit 0 ;;
      *) msg_err "Invalid / Không hợp lệ"; exit 1 ;;
    esac
  else
    msg_info "No VM found, starting fresh install... / Không tìm thấy VM, cài mới..."
    echo ""
    select_fastest_mirror
    download_iso
    create_vm
  fi
}

main "$@"
