#!/bin/bash
# The WabiLink server on an AWS EC2 instance, set up at its first boot.
#
# Give this file as the instance's user data: in the console, Advanced details -> User data;
# or aws ec2 run-instances ... --user-data file://ec2-user-data.sh. It works on the Amazon
# Linux 2023, Ubuntu, Debian, Fedora, RHEL, Rocky Linux and AlmaLinux images, x86_64 and
# ARM (Graviton).
#
# Before launching (https://link.wabione.com/#aws has it step by step):
#   - the administrator's password in SSM Parameter Store, as a SecureString - never in here:
#     user data can be read by any program on the instance, and in the EC2 console;
#   - an instance role that may read that parameter (ssm:GetParameter);
#   - a security group open on TCP 8009 (and 8010 from your own address only).
#
# What it did is in /var/log/cloud-init-output.log on the instance, and in its system log
# (EC2 console: Actions -> Monitor and troubleshoot -> Get system log): the lines starting
# WABILINK, with the server's fingerprint to compare the first time you connect.
set -euo pipefail

# --- Settings ----------------------------------------------------------------------------
ADMIN="admin"                                  # the WabiLink administrator account
PASSWORD_PARAMETER="/wabilink/admin-password"  # its password: an SSM SecureString parameter
SHARE_NAME="Files"                             # a share for the administrator...
SHARE_PATH="/srv/files"                        # ...and the folder it is
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
# system's own updates from then on. The install script downloaded first, then run. It checks
# the repository's key with gpg - installing gpg where the image has none - and installs
# nothing it could not check: then this stops here (set -e), and nothing is set up.
installer="$(mktemp)"
curl -fsSL "$site/install.sh" -o "$installer"
sh "$installer"
rm -f "$installer"

# The AWS CLI, to read the password: Amazon Linux has it; the other images get AWS's own.
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

# The administrator: the password goes from Parameter Store straight into the server - on no
# command line, in no file, and not in this script's output.
aws ssm get-parameter --region "$REGION" --name "$PASSWORD_PARAMETER" --with-decryption \
	--query Parameter.Value --output text \
	| wabilink-server user add "$ADMIN" --admin --password-stdin

# A folder to share; the service runs as the wabilink account, which must be able to write it.
mkdir -p "$SHARE_PATH"
chown wabilink: "$SHARE_PATH"
wabilink-server share add "$ADMIN" "$SHARE_NAME" "$SHARE_PATH"

# Started now, and at every boot.
systemctl enable --now wabilink

address="$(imds public-ipv4 2>/dev/null || imds local-ipv4 2>/dev/null || hostname -I | cut -d' ' -f1)"
echo "WABILINK: wabilink-server $(wabilink-server version) is running."
echo "WABILINK: connect to $address, port 8009, as $ADMIN."
echo "WABILINK: the server's fingerprint - the app shows it the first time; it must be the same:"
wabilink-server identity | sed 's/^/WABILINK:   /'
