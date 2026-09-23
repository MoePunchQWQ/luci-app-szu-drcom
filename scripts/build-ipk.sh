#!/bin/sh
# Build an installable .ipk for luci-app-szu-drcom without an OpenWrt SDK.
#
# The package is PKGARCH=all (shell + Lua only, nothing to cross-compile), so a
# plain tar/gzip pass is enough. The result is the legacy ipk layout that opkg
# understands: a tar.gz holding ./debian-binary, ./data.tar.gz, ./control.tar.gz
#
# Usage:  sh scripts/build-ipk.sh [output-dir]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="${1:-$ROOT/dist}"
PKG_NAME="luci-app-szu-drcom"

VERSION="$(sed -n 's/^PKG_VERSION:=\(.*\)$/\1/p' "$ROOT/Makefile" | head -n 1)"
RELEASE="$(sed -n 's/^PKG_RELEASE:=\(.*\)$/\1/p' "$ROOT/Makefile" | head -n 1)"
[ -n "$VERSION" ] || { echo "cannot read PKG_VERSION from Makefile" >&2; exit 1; }
[ -n "$RELEASE" ] || RELEASE=1

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

DATA="$WORK/data"
CTL="$WORK/control"
mkdir -p "$DATA" "$CTL" "$OUT"

stage() { # stage <src> <dest-in-ipk> <mode>
	mkdir -p "$DATA/$(dirname "$2")"
	cp "$ROOT/$1" "$DATA/$2"
	chmod "$3" "$DATA/$2"
}

# ---------------------------------------------------------------- data.tar.gz
stage files/usr/bin/szu-drcom                              usr/bin/szu-drcom                               0755
stage files/etc/init.d/drcom_szu                           etc/init.d/drcom_szu                            0755
stage files/etc/config/drcom_szu                           etc/config/drcom_szu                            0644
stage files/usr/lib/lua/luci/controller/szu_drcom.lua      usr/lib/lua/luci/controller/szu_drcom.lua       0644
stage files/usr/lib/lua/luci/view/szu_drcom/status.htm     usr/lib/lua/luci/view/szu_drcom/status.htm      0644
stage files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json   usr/share/rpcd/acl.d/luci-app-szu-drcom.json    0644

# ------------------------------------------------------------- control.tar.gz
cat >"$CTL/control" <<EOF
Package: $PKG_NAME
Version: $VERSION-$RELEASE
Depends: libc, curl, uci, luci-base, luci-lua-runtime, libuci-lua
Section: net
Architecture: all
Maintainer: szu-drcom contributors
Description: SZU Dr.COM ePortal campus network client with a LuCI panel.
 Supports one-click login/logout, an auto reconnect daemon, live status
 and logs.
Source: https://github.com/szu-drcom/luci-app-szu-drcom
EOF

echo "/etc/config/drcom_szu" >"$CTL/conffiles"

cat >"$CTL/postinst" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
chmod 600 /etc/config/drcom_szu 2>/dev/null
rm -rf /tmp/luci-indexcache /tmp/luci-modulecache 2>/dev/null
if [ -x /etc/init.d/uhttpd ]; then
	/etc/init.d/uhttpd restart >/dev/null 2>&1 || true
fi
exit 0
EOF

cat >"$CTL/prerm" <<'EOF'
#!/bin/sh
[ -n "$IPKG_INSTROOT" ] && exit 0
if [ -x /etc/init.d/drcom_szu ]; then
	/etc/init.d/drcom_szu stop >/dev/null 2>&1 || true
	/etc/init.d/drcom_szu disable >/dev/null 2>&1 || true
fi
exit 0
EOF

chmod 0755 "$CTL/postinst" "$CTL/prerm"

# ------------------------------------------------------------------- assemble
echo "2.0" >"$WORK/debian-binary"

tar -czf "$WORK/control.tar.gz" -C "$CTL" --owner=0 --group=0 \
	./control ./conffiles ./postinst ./prerm
tar -czf "$WORK/data.tar.gz" -C "$DATA" --owner=0 --group=0 ./

IPK="$OUT/${PKG_NAME}_${VERSION}-${RELEASE}_all.ipk"
tar -czf "$IPK" -C "$WORK" --owner=0 --group=0 \
	./debian-binary ./data.tar.gz ./control.tar.gz

echo "built: $IPK"
echo "size : $(wc -c <"$IPK") bytes"
