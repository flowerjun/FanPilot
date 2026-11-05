#!/bin/zsh
# sudo ./install.sh — terminal alternative to the app's install button: copies the app to /Applications and installs the daemon
set -euo pipefail
cd "${0:A:h}"
[[ $EUID -eq 0 ]] || { echo "sudo로 실행하세요: sudo ./install.sh"; exit 1; }
USER_NAME=${SUDO_USER:-$(stat -f %Su /dev/console)}
[[ -d build/FanPilot.app ]] || sudo -u "$USER_NAME" ./build.sh
pkill -x FanPilot 2>/dev/null || true
rm -rf /Applications/FanPilot.app
cp -R build/FanPilot.app /Applications/
chown -R "$USER_NAME":admin /Applications/FanPilot.app
/Applications/FanPilot.app/Contents/Resources/fanpilot-admin.sh install /Applications/FanPilot.app "$USER_NAME"
