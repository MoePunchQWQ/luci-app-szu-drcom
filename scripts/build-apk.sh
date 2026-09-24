#!/bin/sh
# Build an installable .apk (Alpine / OpenWrt apk-tools) for luci-app-szu-drcom
# without an OpenWrt SDK or the abuild toolchain.
#
# The package is PKGARCH=all (shell + Lua only, nothing to cross-compile), so a
# plain tar/gzip pass is enough.
#
# Two containers are supported:
#
#   v2 (default)  two concatenated gzip streams: the first carries .PKGINFO and
#                 the hook scripts, the second carries the files. Every file in
#                 the data segment gets an APK-TOOLS.checksum.SHA1 pax header,
#                 because apk-tools 3.x (OpenWrt 25.12+, Alpine 3.23+) rejects
#                 v2 packages without one with "file format is obsolete".
#                 With those headers the same file installs on apk-tools 2.x
#                 and 3.x alike.
#   v3 (--v3)     the new ADB-based container; needs apk-tools 3.x with the
#                 "apk mkpkg" subcommand on the build host.
#
# Three details the format is unforgiving about, all verified against real
# Alpine packages and against apk-tools 2.14.6 / 3.0.8:
#   * datahash is the sha256 of the data segment exactly as stored, i.e. of the
#     gzipped bytes, not of the decompressed tarball;
#   * the control segment must NOT carry the tar end-of-archive marker, or apk
#     stops parsing before it reaches the data segment (abuild does this with
#     "abuild-tar --cut");
#   * GNU tar can only write pax keywords into a *global* header, which apk
#     ignores, so the per-file checksum headers need python3. Without python3
#     the script still builds, but the result is refused by apk-tools 3.x.
#
# Usage:  sh scripts/build-apk.sh [-o OUTDIR] [-a ARCH] [--v2|--v3] [-h]

set -eu

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT=""
FORMAT="v2"
ARCH="noarch"

PKG_NAME="luci-app-szu-drcom"
ORIGIN="$PKG_NAME"
LICENSE="MIT"
MAINTAINER="szu-drcom contributors <moepunch39@outlook.com>"
URL="https://github.com/MoePunchQWQ/luci-app-szu-drcom"
DESCRIPTION="SZU Dr.COM ePortal campus network client with a LuCI panel"
# Edit (or override from the environment) this list if your firmware names a
# package differently:  DEPENDS="" sh scripts/build-apk.sh
DEPENDS="${DEPENDS-uci luci-base luci-lua-runtime}"

usage() {
	cat <<EOF
Usage: sh scripts/build-apk.sh [options]

Options:
  -o DIR     output directory (default: ./dist)
  -a ARCH    package architecture (default: $ARCH)
  --v2       build the apk v2 container (default)
  --v3       build the apk v3 container (needs apk-tools 3.x 'apk mkpkg')
  -h         show this help
EOF
}

while [ $# -gt 0 ]; do
	case "$1" in
	-o) OUT="$2"; shift 2 ;;
	-a) ARCH="$2"; shift 2 ;;
	--v2) FORMAT="v2"; shift ;;
	--v3) FORMAT="v3"; shift ;;
	-h|--help) usage; exit 0 ;;
	*) echo "unknown option: $1" >&2; usage >&2; exit 2 ;;
	esac
done

[ -n "$OUT" ] || OUT="$ROOT/dist"

VERSION="$(sed -n 's/^PKG_VERSION:=\(.*\)$/\1/p' "$ROOT/Makefile" | head -n 1)"
RELEASE="$(sed -n 's/^PKG_RELEASE:=\(.*\)$/\1/p' "$ROOT/Makefile" | head -n 1)"
[ -n "$VERSION" ] || { echo "cannot read PKG_VERSION from Makefile" >&2; exit 1; }
[ -n "$RELEASE" ] || RELEASE=1
# apk spells the OpenWrt release as -rN, e.g. 1.0.0-r4
PKGVER="$VERSION-r$RELEASE"

# Deterministic output: byte-wise sort order and a stable build date.
LC_ALL=C
export LC_ALL
BUILD_DATE="${SOURCE_DATE_EPOCH:-$(date +%s)}"

WORK="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/build-apk.$$")"
mkdir -p "$WORK"
trap 'rm -rf "$WORK"' EXIT INT TERM

DATA="$WORK/data"
CTL="$WORK/control"
mkdir -p "$DATA" "$CTL" "$OUT"

die() { echo "error: $*" >&2; exit 1; }
warn() { echo "warning: $*" >&2; }

command -v tar >/dev/null  || die "tar is required"
command -v gzip >/dev/null || die "gzip is required"

# ------------------------------------------------------------------- helpers

# Hash tools: coreutils -> busybox -> macOS -> openssl
find_hash_tool() { # find_hash_tool <sha1|sha256> -> command, or empty
	alg="$1"
	num=256
	[ "$alg" = sha1 ] && num=1
	for c in "${alg}sum" "shasum -a $num" "openssl dgst -$alg"; do
		set -- $c
		if command -v "$1" >/dev/null 2>&1; then
			echo "$c"
			return
		fi
	done
}

digest() { # digest <sha1|sha256> <file> -> hex
	tool="$(find_hash_tool "$1")"
	[ -n "$tool" ] || die "no $1 tool found"
	case "$tool" in
	"openssl dgst -"*) openssl dgst -"$1" "$2" | sed -n 's/.*= //p' ;;
	"shasum -a "*)     shasum -a "$(echo "$tool" | cut -d' ' -f3)" "$2" | cut -d' ' -f1 ;;
	*)                 "$tool" "$2" | cut -d' ' -f1 ;;
	esac
}

# Files must be recorded as root:root. GNU tar and bsdtar spell that
# differently, so probe once and remember whichever works.
OWNER_FLAGS=""
: >"$WORK/probe.txt"
for cand in "--owner=0 --group=0 --numeric-owner" \
            "--uid=0 --gid=0 --uname=root --gname=root"; do
	# shellcheck disable=SC2086
	if tar -cf "$WORK/probe.tar" $cand -C "$WORK" ./probe.txt 2>/dev/null; then
		OWNER_FLAGS="$cand"
		break
	fi
done
[ -n "$OWNER_FLAGS" ] ||
	warn "tar cannot force root ownership here; run as root or under fakeroot" \
	     "if the package installs with the wrong owner"

# A 512-byte all-zero block, used to spot tar padding.
: >"$WORK/zero512"
dd if=/dev/zero of="$WORK/zero512" bs=512 count=1 2>/dev/null ||
	warn "/dev/zero unavailable; cannot trim the tar end-of-archive marker"

# Drop the trailing all-zero blocks of a tar archive, i.e. its padding and
# end-of-archive marker, so another segment can be appended after it.
strip_eof() { # strip_eof <src> <dst>
	if [ ! -s "$WORK/zero512" ]; then
		cp "$1" "$2"
		return 0
	fi
	blocks=$(( $(wc -c <"$1") / 512 ))
	last=$((blocks - 1))
	while [ "$last" -ge 0 ]; do
		dd if="$1" bs=512 skip="$last" count=1 2>/dev/null |
			cmp -s - "$WORK/zero512" || break
		last=$((last - 1))
	done
	dd if="$1" of="$2" bs=512 count=$((last + 1)) 2>/dev/null
}

# python3 is only needed for the per-file checksum headers; see the note on top.
PY=""
for p in python3 python; do
	if command -v "$p" >/dev/null 2>&1; then PY="$p"; break; fi
done

# ----------------------------------------------------------------- data tree

: >"$WORK/files.manifest"

stage() { # stage <src> <dest-in-pkg> <mode>
	mkdir -p "$DATA/$(dirname "$2")"
	cp "$ROOT/$1" "$DATA/$2"
	chmod "$3" "$DATA/$2"
	printf '%s\t%s\n' "$2" "$3" >>"$WORK/files.manifest"
	FILES="$FILES $2"
}

FILES=""
stage files/usr/bin/szu-drcom                             usr/bin/szu-drcom                             0755
stage files/etc/init.d/drcom_szu                          etc/init.d/drcom_szu                          0755
stage files/etc/config/drcom_szu                          etc/config/drcom_szu                          0600
stage files/usr/lib/lua/luci/controller/szu_drcom.lua     usr/lib/lua/luci/controller/szu_drcom.lua     0644
stage files/usr/lib/lua/luci/view/szu_drcom/status.htm    usr/lib/lua/luci/view/szu_drcom/status.htm    0644
stage files/usr/share/rpcd/acl.d/luci-app-szu-drcom.json  usr/share/rpcd/acl.d/luci-app-szu-drcom.json  0644

# Directory records have to come before the files inside them, parents first.
DIRS="$(for f in $FILES; do
	d=$(dirname "$f")
	while [ "$d" != "." ]; do echo "$d"; d=$(dirname "$d"); done
done | sort -u | awk '{print length($0), $0}' | sort -n -k1,1 -k2 | cut -d' ' -f2-)"

# Top level of the tree, used by the tar fallback.
TOPLEVEL="$(for f in $FILES; do echo "${f%%/*}"; done | sort -u)"

# Installed size: an estimate apk uses for its free-space check. abuild fills
# this with the summed size of the package's files, so do the same.
SIZE=0
for f in $FILES; do
	SIZE=$((SIZE + $(wc -c <"$DATA/$f")))
done

# ------------------------------------------------------------- hook scripts

# The hook bodies come from the Makefile's Package/$(PKG_NAME)/postinst and
# /prerm defines -- the single source of truth shared with the SDK build and
# with build-ipk.sh, so no copy can drift.
extract_hook() { # extract_hook <postinst|prerm>
	sed -n "/^define Package\/\$(PKG_NAME)\/$1\$/,/^endef\$/p" "$ROOT/Makefile" |
		sed '1d;$d' |
		sed 's/\$\$/$/g'
}

# apk hooks differ from opkg's in two ways: there is no IPKG_INSTROOT (image
# builds) concept to guard on, and a hook must never trip `set -e`, so the
# body runs best-effort under an explicit `set +e`.
write_apk_hook() { # write_apk_hook <postinst|prerm> <path>
	{
		printf '%s\n' '#!/bin/sh' \
			'# Body generated from the Makefile; edit it there.' \
			'set +e'
		extract_hook "$1" | sed '1d;/IPKG_INSTROOT/d'
	} >"$2"
}

write_apk_hook postinst "$CTL/.post-install"
# Upgrading an installed package runs .post-upgrade only; reuse the same body
# so permissions and the LuCI menu cache are refreshed on every upgrade too.
write_apk_hook postinst "$CTL/.post-upgrade"
write_apk_hook prerm "$CTL/.pre-deinstall"
# After the files are gone the menu must be rebuilt, so run the cache-clearing
# body once more (its config chmod is a guarded no-op by then).
write_apk_hook postinst "$CTL/.post-deinstall"

chmod 0755 "$CTL"/.post-install "$CTL"/.post-upgrade \
           "$CTL"/.pre-deinstall "$CTL"/.post-deinstall

APK="$OUT/${PKG_NAME}-${PKGVER}.apk"

# -------------------------------------------------------------------- v3 path

if [ "$FORMAT" = "v3" ]; then
	command -v apk >/dev/null ||
		die "--v3 needs apk-tools 3.x on the build host (the 'apk mkpkg' subcommand)"

	set -- -F "$DATA" -o "$APK" \
		-I "name:$PKG_NAME" -I "version:$PKGVER" -I "arch:$ARCH" \
		-I "description:$DESCRIPTION" -I "url:$URL" \
		-I "license:$LICENSE" -I "origin:$ORIGIN" \
		-I "maintainer:$MAINTAINER" -I "build-time:$BUILD_DATE"
	for d in $DEPENDS; do
		set -- "$@" -I "depends:$d"
	done
	for s in post-install post-upgrade pre-deinstall post-deinstall; do
		set -- "$@" -s "$s:$CTL/.$s"
	done

	apk mkpkg "$@" || die "apk mkpkg failed; try again without --v3"

	echo "built: $APK (apk v3)"
	echo "size : $(wc -c <"$APK") bytes"
	exit 0
fi

# -------------------------------------------------------------- v2: data part

if [ -n "$PY" ]; then
	# Build the data segment with python: tarfile can attach a pax header to
	# each file, which is the only way apk-tools 3.x accepts a v2 package.
	cat >"$WORK/mkdata.py" <<'PYEOF'
import hashlib, io, os, sys, tarfile

root, out = sys.argv[1], sys.argv[2]
buf = io.BytesIO()
tf = tarfile.open(fileobj=buf, mode="w", format=tarfile.PAX_FORMAT)
for line in sys.stdin:
    rel, mode = line.rstrip("\n").split("\t")
    ti = tf.gettarinfo(os.path.join(root, rel), arcname=rel)
    ti.mode = int(mode, 8)
    ti.uid = ti.gid = 0
    ti.uname = ti.gname = "root"
    ti.mtime = 0
    if ti.isreg():
        with open(os.path.join(root, rel), "rb") as fh:
            blob = fh.read()
        ti.size = len(blob)
        ti.pax_headers = {"APK-TOOLS.checksum.SHA1": hashlib.sha1(blob).hexdigest()}
        tf.addfile(ti, io.BytesIO(blob))
    else:
        tf.addfile(ti)
tf.close()
with open(out, "wb") as fh:
    fh.write(buf.getvalue())
PYEOF
	{
		for d in $DIRS; do printf '%s\t0755\n' "$d"; done
		cat "$WORK/files.manifest"
	} | "$PY" "$WORK/mkdata.py" "$DATA" "$WORK/data.tar" ||
		die "python could not build the data archive"
else
	warn "python3 not found: building without per-file checksum headers."
	warn "the package will install on apk-tools 2.x but be refused by 3.x"
	warn "(OpenWrt 25.12+, Alpine 3.23+); install python3 or use --v3."
	# shellcheck disable=SC2086
	tar -cf "$WORK/data.tar" $OWNER_FLAGS -C "$DATA" $TOPLEVEL
fi

gzip -9 <"$WORK/data.tar" >"$WORK/data.tar.gz"

# datahash is the sha256 of the data segment exactly as stored on disk, i.e. of
# the gzipped bytes, not of the decompressed tarball.
DATAHASH="$(digest sha256 "$WORK/data.tar.gz")"

# ----------------------------------------------------------- v2: control part

{
	echo "# Generated by scripts/build-apk.sh"
	echo "pkgname = $PKG_NAME"
	echo "pkgver = $PKGVER"
	echo "arch = $ARCH"
	echo "size = $SIZE"
	echo "origin = $ORIGIN"
	echo "pkgdesc = $DESCRIPTION"
	echo "url = $URL"
	echo "license = $LICENSE"
	echo "maintainer = $MAINTAINER"
	echo "builddate = $BUILD_DATE"
	echo "datahash = $DATAHASH"
	for d in $DEPENDS; do
		echo "depend = $d"
	done
} >"$CTL/.PKGINFO"

# Names are stored bare (".PKGINFO"), not as "./.PKGINFO" -- apk matches the
# entry name exactly.
# shellcheck disable=SC2086
tar -cf "$WORK/control.tar" $OWNER_FLAGS -C "$CTL" \
	.PKGINFO .post-install .post-upgrade .pre-deinstall .post-deinstall
strip_eof "$WORK/control.tar" "$WORK/control.cut"

gzip -9 <"$WORK/control.cut" >"$WORK/control.tar.gz"

# -------------------------------------------------------------------- assemble

cat "$WORK/control.tar.gz" "$WORK/data.tar.gz" >"$APK"

echo "built: $APK (apk v2)"
echo "size : $(wc -c <"$APK") bytes"
echo
echo "install with:"
echo "  apk add --allow-untrusted $APK"
