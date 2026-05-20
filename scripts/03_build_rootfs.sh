#!/usr/bin/env bash
# scripts/03_build_rootfs.sh
# Construye initramfs con BusyBox + Python3 + su real + PAM
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
BUSYBOX_SRC="$WORKSPACE_ROOT/kernel/busybox"
INITRAMFS_DIR="$WORKSPACE_ROOT/kernel/initramfs"
BUILD_DIR="$WORKSPACE_ROOT/kernel/build"
POC_SRC="$WORKSPACE_ROOT/copy_fail_exp.py"
JOBS="$(nproc)"
STUDENT_ID="${STUDENT_ID:-$(git -C "$WORKSPACE_ROOT" config user.name 2>/dev/null \
                | tr ' ' '-' | tr -cd '[:alnum:]-' | head -c 20)}"
STUDENT_ID="${STUDENT_ID:-unnamed}"
CYAN='\033[1;36m'; GREEN='\033[1;32m'; YELLOW='\033[1;33m'; RED='\033[1;31m'; NC='\033[0m'
copy_deps() {
  local bin="$1"
  ldd "$bin" 2>/dev/null \
    | awk '{for(i=1;i<=NF;i++) if ($i ~ /^\//) print $i}' \
    | sort -u \
    | while read -r lib; do
        mkdir -p "$INITRAMFS_DIR$(dirname "$lib")"
        cp -aL "$lib" "$INITRAMFS_DIR$lib"
        chmod 755 "$INITRAMFS_DIR$lib"
      done
}
echo -e "${CYAN}[1/8] Clonando BusyBox...${NC}"
if [ ! -d "$BUSYBOX_SRC" ]; then
  git clone --depth 1 https://git.busybox.net/busybox "$BUSYBOX_SRC"
fi
cd "$BUSYBOX_SRC"
echo -e "${CYAN}[2/8] Configurando BusyBox (static + sin TC)...${NC}"
make defconfig
sed -i 's/# CONFIG_STATIC is not set/CONFIG_STATIC=y/' .config
grep -q "^CONFIG_STATIC=y" .config || echo "CONFIG_STATIC=y" >> .config
sed -i 's/^CONFIG_TC=y/CONFIG_TC=n/' .config
sed -i 's/^CONFIG_FEATURE_TC_INGRESS=y/CONFIG_FEATURE_TC_INGRESS=n/' .config
echo -e "${CYAN}[3/8] Compilando BusyBox estático (~3-5 min)...${NC}"
make -j"$JOBS" 2>&1 | tail -3
if ! file busybox | grep -q "statically linked"; then
  echo -e "${RED}✗ BusyBox NO quedó estático${NC}"
  grep STATIC .config || true
  exit 1
fi
echo -e "${GREEN}  ✓ BusyBox compilado estáticamente${NC}"
echo -e "${CYAN}[4/8] Instalando BusyBox en initramfs...${NC}"
rm -rf "$INITRAMFS_DIR"
mkdir -p "$INITRAMFS_DIR"
make CONFIG_PREFIX="$INITRAMFS_DIR" install 2>&1 | tail -3
mkdir -p "$INITRAMFS_DIR"/{proc,sys,dev,tmp,etc,root,home/student,run}
mkdir -p "$INITRAMFS_DIR/usr/bin"
mkdir -p "$INITRAMFS_DIR/usr/lib"
mkdir -p "$INITRAMFS_DIR/usr/local/lib"
mkdir -p "$INITRAMFS_DIR/lib/x86_64-linux-gnu"
mkdir -p "$INITRAMFS_DIR/etc/pam.d"
mkdir -p "$INITRAMFS_DIR/etc/security"
cat > "$INITRAMFS_DIR/etc/passwd" << 'PASSWD'
root:x:0:0:root:/root:/bin/sh
student:x:1001:1001::/home/student:/bin/sh
PASSWD
cat > "$INITRAMFS_DIR/etc/group" << 'GROUP'
root:x:0:
student:x:1001:
GROUP
cat > "$INITRAMFS_DIR/init" << INITEOF
#!/bin/sh
mkdir -p /proc /sys /dev /etc /home/student
mount -t proc proc /proc 2>/dev/null || true
mount -t sysfs sysfs /sys 2>/dev/null || true
mount -t devtmpfs devtmpfs /dev 2>/dev/null || true
/bin/busybox ifconfig lo 127.0.0.1 up 2>/dev/null || true
/bin/busybox ifconfig eth0 10.0.2.15 netmask 255.255.255.0 up 2>/dev/null || true
/bin/busybox route add default gw 10.0.2.2 2>/dev/null || true
echo "nameserver 10.0.2.3" > /etc/resolv.conf
echo "nameserver 8.8.8.8" >> /etc/resolv.conf
hostname "copy-fail-${STUDENT_ID}"
echo ""
echo "  ╔═══════════════════════════════════════════════╗"
echo "  ║  Kernel vulnerable: $(uname -r)               ║"
echo "  ║  CVE-2026-31431 Copy Fail Lab                ║"
echo "  ╚═══════════════════════════════════════════════╝"
echo ""
exec /bin/busybox su - student
INITEOF
chmod +x "$INITRAMFS_DIR/init"
echo -e "${CYAN}[5/8] Inyectando Python3...${NC}"
PYBIN="$(readlink -f "$(command -v python3)")"
PYVER="$(python3 -c 'import sys; print(f"python{sys.version_info.major}.{sys.version_info.minor}")')"
echo "  → Python: $PYBIN ($PYVER)"
install -o root -g root -m 0755 "$PYBIN" "$INITRAMFS_DIR/usr/bin/python3"
ln -sf python3 "$INITRAMFS_DIR/usr/bin/python"
copy_deps "$PYBIN"
if [ -d "/usr/lib/$PYVER" ]; then
  cp -a "/usr/lib/$PYVER" "$INITRAMFS_DIR/usr/lib/"
fi
if compgen -G "/usr/local/lib/python*" >/dev/null 2>&1; then
  cp -a /usr/local/lib/python* "$INITRAMFS_DIR/usr/local/lib/" 2>/dev/null || true
fi
echo -e "${GREEN}  ✓ Python3 listo${NC}"
echo -e "${CYAN}[6/8] Inyectando shell real...${NC}"
SHREAL="$(command -v dash || readlink -f /bin/sh)"
rm -f "$INITRAMFS_DIR/bin/sh"
install -o root -g root -m 0755 "$SHREAL" "$INITRAMFS_DIR/bin/sh"
copy_deps "$SHREAL"
echo -e "${GREEN}  ✓ Shell: $SHREAL${NC}"
echo -e "${CYAN}[7/8] Inyectando su real + PAM...${NC}"
rm -f "$INITRAMFS_DIR/usr/bin/su" "$INITRAMFS_DIR/bin/su"
install -o root -g root -m 4755 /usr/bin/su "$INITRAMFS_DIR/usr/bin/su"
copy_deps /usr/bin/su
ln -sf /usr/bin/su "$INITRAMFS_DIR/bin/su"
# PAM
cp -a /etc/pam.d/su "$INITRAMFS_DIR/etc/pam.d/su" 2>/dev/null || true
cp -a /etc/pam.d/common-* "$INITRAMFS_DIR/etc/pam.d/" 2>/dev/null || true
cp -a /etc/login.defs "$INITRAMFS_DIR/etc/login.defs" 2>/dev/null || true
cp -a /etc/security/* "$INITRAMFS_DIR/etc/security/" 2>/dev/null || true
cp -a /lib/x86_64-linux-gnu/security "$INITRAMFS_DIR/lib/x86_64-linux-gnu/" 2>/dev/null || true
# Forzar SUID si no quedó
if ! stat -c "%a" "$INITRAMFS_DIR/usr/bin/su" | grep -q '4755'; then
  echo -e "${YELLOW}⚠ /usr/bin/su no tiene SUID, forzando...${NC}"
  chown root:root "$INITRAMFS_DIR/usr/bin/su"
  chmod 4755 "$INITRAMFS_DIR/usr/bin/su"
fi
echo -e "${GREEN}  ✓ su real: $(ls -l "$INITRAMFS_DIR/usr/bin/su")${NC}"
# PoC
if [ -f "$POC_SRC" ]; then
  install -o 1001 -g 1001 -m 0755 "$POC_SRC" "$INITRAMFS_DIR/home/student/copy_fail_exp.py"
  sed -i '1s|^.*$|#!/usr/bin/python3|' "$INITRAMFS_DIR/home/student/copy_fail_exp.py"
  echo -e "${GREEN}  ✓ PoC copiado${NC}"
else
  echo -e "${YELLOW}  ⚠ copy_fail_exp.py no encontrado en raíz del repo${NC}"
fi
echo -e "${CYAN}[8/8] Empaquetando initramfs...${NC}"
find "$INITRAMFS_DIR" -type d -exec chmod 755 {} \;
find "$INITRAMFS_DIR" -type f \( -name "*.so" -o -name "*.so.*" -o -name "ld-linux*" \) -exec chmod 755 {} \;
cd "$INITRAMFS_DIR"
find . | cpio -o -H newc 2>/dev/null | gzip > "$BUILD_DIR/initramfs.cpio.gz"
SIZE=$(du -sh "$BUILD_DIR/initramfs.cpio.gz" | cut -f1)
echo -e "${GREEN}✓ initramfs listo (${SIZE})${NC}"
echo -e "${GREEN}  STUDENT_ID: ${STUDENT_ID}${NC}"
