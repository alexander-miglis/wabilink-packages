#!/bin/sh
# Installs the WabiLink server, and keeps it up to date:
#
#   curl -fsSLO https://alexander-miglis.github.io/wabilink-packages/install.sh
#   sudo sh install.sh
#
# With dnf (Fedora, RHEL and their kin) or apt (Debian, Ubuntu, Raspberry Pi OS): adds the
# repository and its signing key, then installs wabilink-server with what its optional parts
# use (ssh, the desktop server's X11 and PipeWire libraries, SVT-AV1 where the system has 2.0
# or later). The system's own updates keep it current.
#
# With neither (Arch, openSUSE, and the rest): the newest self-contained archive for this
# processor, its checksum checked, into /opt/wabilink, and a systemd unit for it under its own
# wabilink account. Nothing updates it but this: run again, it replaces the program with the
# newest. The data, in /var/lib/wabilink, is kept.
#
# Either way, run again it updates all of it, and a running server is restarted. A new install
# is not started: see what it prints at the end.
set -eu

site="https://alexander-miglis.github.io/wabilink-packages"
# The installed program: the package's, on the PATH; the archive's, by its full path (sudo's
# PATH need not have /usr/local/bin).
server=wabilink-server

if [ "$(id -u)" != 0 ]; then
	echo "Run it as root: sudo sh install.sh" >&2
	exit 1
fi

fetch() {
	if command -v curl >/dev/null 2>&1; then
		curl -fsSL "$1" -o "$2"
	else
		wget -qO "$2" "$1"
	fi
}

# No repository of ours for this system: the archive. It used to say "download the .tar.gz
# instead", and updating was by hand - where a folder holding two downloads unpacked neither.
archive() {
	command -v systemctl >/dev/null 2>&1 || {
		echo "The server runs as a systemd service, and this system has no systemctl." >&2
		exit 1
	}
	case "$(uname -m)" in
		x86_64 | amd64) arch=x86_64 ;;
		aarch64 | arm64) arch=aarch64 ;;
		armv7l | armv8l) arch=armv7l ;;
		*)
			echo "There is no WabiLink server for this processor ($(uname -m))." >&2
			exit 1
			;;
	esac

	# What it needs from the system besides glibc and systemd: OpenSSL 3. Nearly always there
	# already (curl uses it); installed only when it is not - pacman -S of one package on a
	# system not up to date is a partial upgrade, which Arch warns against.
	if ! { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -q "libssl\.so\.3 "; then
		if command -v pacman >/dev/null 2>&1; then
			pacman -S --needed --noconfirm openssl
		elif command -v zypper >/dev/null 2>&1; then
			zypper --non-interactive install libopenssl3
		else
			echo "The server needs OpenSSL 3 (libssl.so.3), which this system does not have. Install it, then run this again." >&2
			exit 1
		fi
	fi

	work="$(mktemp -d)"
	trap 'rm -rf "$work"' EXIT
	# The newest, by the list of checksums every release publishes.
	fetch "$site/files/SHA256SUMS" "$work/SHA256SUMS"
	name="$(grep -oE "wabilink-server-[^ ]+-linux-$arch\.tar\.gz" "$work/SHA256SUMS" | sort -V | tail -n 1)"
	if [ -z "$name" ]; then
		echo "The package site has no server for $arch just now." >&2
		exit 1
	fi
	echo "Downloading $name..."
	fetch "$site/files/$name" "$work/$name"
	expected="$(grep "  $name\$" "$work/SHA256SUMS" | cut -d' ' -f1)"
	actual="$(sha256sum "$work/$name" | cut -d' ' -f1)"
	if [ "$expected" != "$actual" ]; then
		echo "The download is not what was published (its checksum differs); run this again." >&2
		exit 1
	fi

	# Unpacked beside the one there, then swapped in: a running server keeps the files it has
	# open until it is restarted, below.
	rm -rf /opt/wabilink.new /opt/wabilink.old
	mkdir -p /opt/wabilink.new
	tar --no-same-owner -xzf "$work/$name" -C /opt/wabilink.new --strip-components=1
	if [ -d /opt/wabilink ]; then
		mv /opt/wabilink /opt/wabilink.old
	fi
	mv /opt/wabilink.new /opt/wabilink
	rm -rf /opt/wabilink.old
	mkdir -p /usr/local/bin
	ln -sf /opt/wabilink/wabilink-server /usr/local/bin/wabilink-server
	server=/opt/wabilink/wabilink-server

	# The account, /var/lib/wabilink and the unit, enabled - written each time, so the unit is
	# the new version's. Not started: what to do first is printed at the end.
	if ! /opt/wabilink/wabilink-server install-systemd --no-start > "$work/systemd.log" 2>&1; then
		cat "$work/systemd.log" >&2
		exit 1
	fi

	# The desktop agent, in every desktop session, as the packages set it up: it offers the
	# session's screen to the server once this machine's desktop is turned on, and does nothing
	# until then. A running one ends itself once its program is replaced, and starts again new.
	mkdir -p /etc/systemd/user
	cat > /etc/systemd/user/wabilink-desktop-agent.service <<'EOF'
[Unit]
Description=WabiLink desktop agent
PartOf=graphical-session.target
After=graphical-session.target

[Service]
ExecStart=/opt/wabilink/wabilink-server desktop-agent
Restart=on-failure
RestartSec=5

[Install]
WantedBy=graphical-session.target
EOF
	systemctl --global enable wabilink-desktop-agent.service >/dev/null 2>&1 || true
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
	archive
fi

# A server already running restarts, to load what was just installed (AV1, say).
if command -v systemctl >/dev/null 2>&1 && systemctl is-active --quiet wabilink 2>/dev/null; then
	systemctl restart wabilink
	running=yes
fi

echo
echo "wabilink-server $("$server" version) is installed."
# The SVT-AV1 the server reads: 2.x or 3.x (libSvtAv1Enc.so.2 or .3); a newer one it does not, yet.
if { ldconfig -p 2>/dev/null || /sbin/ldconfig -p 2>/dev/null; } | grep -qE "libSvtAv1Enc\.so\.[23]( |$)"; then
	echo "The remote desktop can send AV1 video (SVT-AV1 is installed)."
else
	echo "The remote desktop sends no AV1 from the CPU: this system has no SVT-AV1 2.x or 3.x. A graphics card's encoder, where there is one, still codes the screen."
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
