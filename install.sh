#!/bin/sh
# Installs the WabiLink server from its package repository, and keeps it updated with
# the system's own updates:
#
#   curl -fsSL https://alexander-miglis.github.io/wabilink-packages/install.sh | sudo sh
#
# Adds the repository and its signing key - dnf on Fedora, RHEL and their kin, apt on
# Debian, Ubuntu and Raspberry Pi OS - then installs wabilink-server with what its optional
# parts use (ssh, the desktop server's X11 and PipeWire libraries, SVT-AV1 where the system
# has 2.0 or later). Run again, it updates all of that. Nothing is started: see what it
# prints at the end.
set -eu

site="https://alexander-miglis.github.io/wabilink-packages"

if [ "$(id -u)" != 0 ]; then
	echo "Run it as root: curl -fsSL $site/install.sh | sudo sh" >&2
	exit 1
fi

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	else
		wget -qO "$2" "$1"
	fi
}

if command -v dnf >/dev/null 2>&1 || command -v yum >/dev/null 2>&1; then
	fetch "$site/wabilink.repo" /etc/yum.repos.d/wabilink.repo
	rpm --import "$site/wabilink.asc"
	# Installed already: brought up to date instead, with what the new version recommends.
	if command -v dnf >/dev/null 2>&1; then
		dnf install -y --refresh --setopt=install_weak_deps=True wabilink-server
		dnf upgrade -y --setopt=install_weak_deps=True wabilink-server
	else
		yum install -y wabilink-server
		yum update -y wabilink-server
	fi
elif command -v apt-get >/dev/null 2>&1; then
	install -d -m 0755 /etc/apt/keyrings
	fetch "$site/wabilink.asc" /etc/apt/keyrings/wabilink.asc
	chmod 0644 /etc/apt/keyrings/wabilink.asc
	echo "deb [signed-by=/etc/apt/keyrings/wabilink.asc] $site/deb stable main" > /etc/apt/sources.list.d/wabilink.list
	apt-get update
	apt-get install -y --install-recommends wabilink-server
else
	echo "Neither dnf nor apt here. Download the .tar.gz from $site/ instead." >&2
	exit 1
fi

# A server already running restarts, to load what was just installed (AV1, say).
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet wabilink 2>/dev/null; then
	systemctl restart wabilink
	running=yes
fi

echo
echo "wabilink-server $(wabilink-server version) is installed."
if { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -qE "libSvtAv1Enc\.so\.[2-9]"; then
	echo "The remote desktop can send AV1 video (SVT-AV1 is installed)."
else
	echo "The remote desktop sends ZRLE: this system has no SVT-AV1 2.0 or later for AV1 video."
fi
if [ "${running:-}" = yes ]; then
	echo "The service was running, and has been restarted."
else
	echo
	echo "Next:"
	echo "  sudo wabilink-server user add NAME --admin     an administrator, for the admin tool"
	echo "  sudo wabilink-server share add NAME Files /srv/files"
	echo "  sudo systemctl enable --now wabilink           start it, now and at every boot"
	echo "  sudo wabilink-server identity                  the fingerprint clients will see"
fi
