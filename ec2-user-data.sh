#!/bin/bash
# The WabiLink server on an AWS EC2 instance, set up at its first boot.
#
# Give this file as the instance's user data: in the console, Advanced details -> User data;
# or aws ec2 run-instances ... --user-data file://ec2-user-data.sh. It works on the Amazon
# Linux 2023, Ubuntu, Debian, Fedora, RHEL, Rocky Linux and AlmaLinux images, x86_64 and
# ARM (Graviton).
#
# It sets the server up one of two ways (https://link.wabione.com/#aws has it step by step):
#   - registered with WabiOne, where Parameter Store has an API token that may register servers
#     (TOKEN_PARAMETER, made in WabiOne's console: API tokens): the console then manages it -
#     its people, shares and settings - and it has no administrator of its own here;
#   - otherwise offline: an administrator, with its password from Parameter Store
#     (PASSWORD_PARAMETER), and a shared folder.
#
# Before launching:
#   - the token or the password in SSM Parameter Store, as a SecureString - never in here:
#     user data can be read by any program on the instance, and in the EC2 console;
#   - an instance role that may read it (ssm:GetParameter on parameter/wabilink/*);
#   - a security group open on TCP 8009 (and, offline, 8010 from your own address only).
#
# What it did is in /var/log/cloud-init-output.log on the instance, and in its system log
# (EC2 console: Actions -> Monitor and troubleshoot -> Get system log): the lines starting
# WABILINK, with the server's fingerprint to compare the first time you connect.
set -euo pipefail

# --- Settings ----------------------------------------------------------------------------
TOKEN_PARAMETER="/wabilink/registration-token" # a WabiOne API token that may register servers: an SSM SecureString
WABIONE="https://app.wabione.com"              # the WabiOne it registers with
SERVER_NAME=""                                 # its name there; empty: the instance's Name tag, else its ID
ADMIN="admin"                                  # offline: the WabiLink administrator account
PASSWORD_PARAMETER="/wabilink/admin-password"  # its password: an SSM SecureString parameter
SHARE_NAME="Files"                             # offline: a share for the administrator...
SHARE_PATH="/srv/files"                        # ...and the folder it is (made either way)
# ------------------------------------------------------------------------------------------

site="https://link.wabione.com"

# The instance metadata service (IMDSv2): where this instance runs, and its addresses.
imds() {
	local token
	token="$(curl -fsS --max-time 5 -X PUT http://169.254.169.254/latest/api/token -H 'X-aws-ec2-metadata-token-ttl-seconds: 60')" || return 1
	curl -fsS --max-time 5 -H "X-aws-ec2-metadata-token: $token" "http://169.254.169.254/latest/meta-data/$1"
}
REGION="${REGION:-$(imds placement/region)}"

# The server, from WabiLink's signed package repository (dnf or apt); updated with the
# system's own updates from then on. The install script downloaded first, checked against the
# release's list of checksums and that list's signature by WabiLink's key - whose fingerprint
# was written into this file as it was published - and only then run as root: a launch
# template keeps this file long after it was downloaded, and the site's word alone would have
# been run as it was at each launch. It checks the repository's key too, and installs nothing
# it could not check: then this stops here (set -e), and nothing is set up.
signer="2C9F6909A29FC1FE2F957F7FACBA86055D3EBAD2"
if ! command -v gpg >/dev/null 2>&1; then
	if command -v dnf >/dev/null 2>&1; then dnf install -y gnupg2 || true
	elif command -v yum >/dev/null 2>&1; then yum install -y gnupg2 || true
	elif command -v apt-get >/dev/null 2>&1; then { apt-get update && apt-get install -y gpg; } || true
	fi
fi
command -v gpg >/dev/null 2>&1 || { echo "WABILINK: stopped: gpg could not be installed, and the install script cannot be checked without it." >&2; exit 1; }
work="$(mktemp -d)"
curl -fsSL "$site/files/SHA256SUMS" -o "$work/SHA256SUMS"
curl -fsSL "$site/files/SHA256SUMS.asc" -o "$work/SHA256SUMS.asc"
curl -fsSL "$site/wabilink.asc" -o "$work/wabilink.asc"
curl -fsSL "$site/files/install.sh" -o "$work/install.sh"
mkdir -m 700 "$work/gnupg"
GNUPGHOME="$work/gnupg" gpg --batch --quiet --import "$work/wabilink.asc" 2>/dev/null || true
if ! GNUPGHOME="$work/gnupg" gpg --batch --status-fd 1 --verify "$work/SHA256SUMS.asc" "$work/SHA256SUMS" 2>/dev/null \
	| grep -q "^\[GNUPG:\] VALIDSIG .*$signer"; then
	echo "WABILINK: stopped: the package site's list of checksums is not signed by WabiLink's key ($signer); nothing was run." >&2
	exit 1
fi
expected="$(grep -E '  install\.sh$' "$work/SHA256SUMS" | cut -d' ' -f1)"
actual="$(sha256sum "$work/install.sh" | cut -d' ' -f1)"
if [ -z "$expected" ] || [ "$expected" != "$actual" ]; then
	echo "WABILINK: stopped: install.sh is not the one the signed list of checksums names; it was not run." >&2
	exit 1
fi
sh "$work/install.sh"
rm -rf "$work"
# Nothing older than the release this file was published with: the repositories' signed lists of
# an older release check out still, and whoever answered for the site could have served them.
floor="1.1.28"
installed="$(wabilink-server version 2>/dev/null | head -1 | tr -d '[:space:]')"
case "$floor" in
	@*) ;; # not published (run from the source): no floor
	*) if [ -z "$installed" ] || { [ "$installed" != "$floor" ] && [ "$(printf '%s\n%s\n' "$installed" "$floor" | sort -t. -k1,1n -k2,2n -k3,3n | head -1)" = "$installed" ]; }; then
		echo "WABILINK: stopped: the package site installed ${installed:-nothing that says its version}, older than this file's release ($floor); nothing was set up." >&2
		exit 1
	fi ;;
esac

# The AWS CLI, to read Parameter Store: Amazon Linux has it; the other images get AWS's own.
if ! command -v aws >/dev/null 2>&1; then
	if command -v apt-get >/dev/null 2>&1; then
		apt-get install -y unzip
	else
		dnf install -y unzip
	fi
	work="$(mktemp -d)"
	curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-$(uname -m).zip" -o "$work/awscli.zip"
	unzip -q "$work/awscli.zip" -d "$work"
	"$work/aws/install"
	rm -rf "$work"
	PATH="/usr/local/bin:$PATH"
fi

# A parameter's value, decrypted: piped from here straight into the server - on no command
# line, in no file, and not in this script's output.
parameter() {
	aws ssm get-parameter --region "$REGION" --name "$1" --with-decryption --query Parameter.Value --output text
}

# A folder to share; the service runs as the wabilink account, which must be able to write it.
# Offline it is the administrator's share; with WabiOne, one for the console to share.
mkdir -p "$SHARE_PATH"
chown wabilink: "$SHARE_PATH"

# WabiOne, where there is a token. Asked for by name only, not decrypted, so that a launch with
# no token - or a role that may read the password only - is set up offline, as before.
if aws ssm get-parameter --region "$REGION" --name "$TOKEN_PARAMETER" --query Parameter.Name --output text >/dev/null; then
	name="${SERVER_NAME:-$(imds tags/instance/Name 2>/dev/null || imds instance-id)}"
	name="${name:0:100}" # a tag may be longer than a server's name
	# Registered already, it is left as it is: registering again would drop what the console set.
	if wabilink-server home >/dev/null 2>&1; then
		echo "WABILINK: already registered with WabiOne; left as it is."
	else
		parameter "$TOKEN_PARAMETER" | wabilink-server register --token-stdin --name "$name" --home "$WABIONE"
	fi
	systemctl enable --now wabilink
	echo "WABILINK: wabilink-server $(wabilink-server version) is running, registered with WabiOne as $name."
	echo "WABILINK: its people, shares and settings are set in WabiOne's console, Servers; the app's Sign in lists it."
else
	echo "WABILINK: no API token at $TOKEN_PARAMETER (why, just above): set up offline, with an administrator."
	parameter "$PASSWORD_PARAMETER" | wabilink-server user add "$ADMIN" --admin --password-stdin
	wabilink-server share add "$ADMIN" "$SHARE_NAME" "$SHARE_PATH"
	systemctl enable --now wabilink
	address="$(imds public-ipv4 2>/dev/null || imds local-ipv4 2>/dev/null || hostname -I | cut -d' ' -f1)"
	echo "WABILINK: wabilink-server $(wabilink-server version) is running."
	echo "WABILINK: connect to $address, port 8009, as $ADMIN."
fi

echo "WABILINK: the server's fingerprint - the app shows it the first time; it must be the same:"
wabilink-server identity | sed 's/^/WABILINK:   /'
