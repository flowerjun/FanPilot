#!/bin/zsh
# sudo ./uninstall.sh — same as the app's "완전 삭제": fan back to system control, everything removed
set -uo pipefail
cd "${0:A:h}"
[[ $EUID -eq 0 ]] || { echo "sudo로 실행하세요: sudo ./uninstall.sh"; exit 1; }
USER_NAME=${SUDO_USER:-$(stat -f %Su /dev/console)}
APP=/Applications/FanPilot.app
pkill -x FanPilot 2>/dev/null
[[ -x $APP/Contents/MacOS/FanPilot ]] && sudo -u "$USER_NAME" $APP/Contents/MacOS/FanPilot --unregister-login-item 2>/dev/null
zsh scripts/fanpilot-admin.sh uninstall $APP "$USER_NAME"
