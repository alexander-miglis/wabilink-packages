#!/bin/bash
# Installs WabiLink on a Mac from the package site - the newest version, for this Mac's
# processor (Apple silicon or Intel), its checksum checked:
#
#   curl -fsSL https://alexander-miglis.github.io/wabilink-packages/install-macos.sh | sudo bash            the server, as a service
#   curl -fsSL https://alexander-miglis.github.io/wabilink-packages/install-macos.sh | bash -s client       the WabiLink app
#   curl -fsSL https://alexander-miglis.github.io/wabilink-packages/install-macos.sh | bash -s admin        the admin tool
#
# Run again, it updates what it installed. The server's data (accounts, shares, settings)
# is kept: it is in /Library/Application Support/WabiLink, not where the program goes.
set -euo pipefail

site="https://alexander-miglis.github.io/wabilink-packages"
what="${1:-server}"

fail() {
	echo "error: $*" >&2
	exit 1
}

[ "$(uname -s)" = Darwin ] || fail "this installs WabiLink on a Mac; on Linux use $site/install.sh"
major="$(sw_vers -productVersion | cut -d. -f1)"
[ "$major" -ge 13 ] || fail "WabiLink needs macOS 13 (Ventura) or later; this Mac has $(sw_vers -productVersion)"

# Apple silicon says so even when this shell runs under Rosetta, where uname -m says x86_64.
if [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ]; then
	arch=arm64
else
	arch=x64
fi

case "$what" in
	server) stem=wabilink-server; kind=tar.gz ;;
	client) stem=wabilink-client; kind=zip; app="WabiLink.app" ;;
	admin) stem=wabilink-admin; kind=zip; app="WabiLink Admin.app" ;;
	*) fail "'$what' is not something to install: server, client or admin" ;;
esac
if [ "$what" = server ] && [ "$(id -u)" != 0 ]; then
	fail "the server is installed as a service, which needs sudo: curl -fsSL $site/install-macos.sh | sudo bash"
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# The newest download of this kind, by the list of checksums every release publishes.
curl -fsSL "$site/files/SHA256SUMS" -o "$work/SHA256SUMS" || fail "the package site cannot be reached ($site)"
name="$(grep -oE "$stem-[^ ]+-macos-$arch\\.${kind//./\\.}" "$work/SHA256SUMS" | sort | tail -1 || true)"
[ -n "$name" ] || fail "the package site has no $stem for macOS ($arch) just now"
echo "Downloading $name..."
curl -fL --progress-bar "$site/files/$name" -o "$work/$name" || fail "the download did not finish; run this again"
expected="$(grep -E "  $name\$" "$work/SHA256SUMS" | cut -d' ' -f1)"
actual="$(shasum -a 256 "$work/$name" | cut -d' ' -f1)"
[ "$expected" = "$actual" ] || fail "the download is not what was published (its checksum differs); run this again"

if [ "$what" != server ]; then
	# The app into Applications, the old one replaced.
	[ -w /Applications ] || fail "this account cannot add apps to Applications: run it as an administrator, or with sudo"
	rm -rf "/Applications/$app"
	ditto -x -k "$work/$name" /Applications
	xattr -dr com.apple.quarantine "/Applications/$app" 2>/dev/null || true
	echo
	echo "$app is in Applications. Open it from there (or Launchpad)."
	exit 0
fi

# The server: stopped while its program is replaced - a running program's file is not
# written over - then installed as a service again, with the desktop agent.
console="$(stat -f %u /dev/console 2>/dev/null || echo 0)"
launchctl bootout system/com.wabilink.server 2>/dev/null || true
if [ "$console" != 0 ]; then
	launchctl bootout "gui/$console/com.wabilink.desktop-agent" 2>/dev/null || true
fi
rm -rf /usr/local/wabilink-server
mkdir -p /usr/local /usr/local/bin
tar -xzf "$work/$name" -C /usr/local
xattr -dr com.apple.quarantine /usr/local/wabilink-server 2>/dev/null || true
ln -sf /usr/local/wabilink-server/wabilink-server /usr/local/bin/wabilink-server
/usr/local/wabilink-server/wabilink-server install-launchd

echo
echo "wabilink-server $(/usr/local/wabilink-server/wabilink-server version) is installed, running, and starts at every boot."
