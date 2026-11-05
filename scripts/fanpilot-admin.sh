#!/bin/zsh
# Privileged half of FanPilot. Bundled in FanPilot.app/Contents/Resources and run as root
# (via the app's admin password prompt, or install.sh / uninstall.sh).
#
#   fanpilot-admin.sh install   <FanPilot.app path> <user>
#   fanpilot-admin.sh uninstall <FanPilot.app path> <user>
set -uo pipefail
[[ $EUID -eq 0 ]] || { echo "root 권한이 필요합니다"; exit 1; }
[[ $# -eq 3 ]] || { echo "usage: $0 install|uninstall <app> <user>"; exit 2; }
CMD=$1 APP=$2 USER_NAME=$3
LABEL=com.flowerjun.fanpilot
PLIST=/Library/LaunchDaemons/$LABEL.plist
DAEMON=/usr/local/libexec/fanpilotd
USER_HOME=$(dscl . -read /Users/$USER_NAME NFSHomeDirectory | awk '{print $2}')

case $CMD in
install)
    set -e
    SRC="$APP/Contents/Resources/fanpilotd"
    [[ -x $SRC ]] || { echo "앱 안에 fanpilotd가 없습니다: $SRC"; exit 1; }
    launchctl bootout system/$LABEL 2>/dev/null || true
    install -d -o root -g wheel -m 755 /usr/local/libexec
    install -o root -g wheel -m 755 "$SRC" $DAEMON
    # Config lives where the (non-root) app can write it.
    install -d -o "$USER_NAME" -g staff -m 755 /Users/Shared/FanPilot
    cat > $PLIST <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array><string>$DAEMON</string></array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>StandardErrorPath</key><string>/var/log/fanpilotd.log</string>
</dict></plist>
PL
    chown root:wheel $PLIST && chmod 644 $PLIST
    launchctl bootstrap system $PLIST
    echo "팬 제어 서비스 설치 완료"
    ;;
uninstall)
    # Stop the daemon; it restores system fan control on SIGTERM. --reset makes sure.
    launchctl bootout system/$LABEL 2>/dev/null
    [[ -x $DAEMON ]] && $DAEMON --reset 2>/dev/null
    rm -f $PLIST $DAEMON /var/run/fanpilot.json /var/log/fanpilotd.log
    rmdir /usr/local/libexec 2>/dev/null   # only if empty
    rm -rf /Users/Shared/FanPilot
    # Go through cfprefsd as the user, then remove the file in case it was never cached.
    sudo -u "$USER_NAME" defaults delete $LABEL 2>/dev/null
    rm -f "$USER_HOME/Library/Preferences/$LABEL.plist"
    rm -rf "$USER_HOME/Library/Saved Application State/$LABEL.savedState" "$USER_HOME/Library/Caches/$LABEL"
    [[ $APP == *.app && -d $APP ]] && rm -rf "$APP"
    echo "제거 완료. 팬은 시스템 자동 제어로 돌아갔습니다."
    ;;
*)
    echo "unknown command: $CMD"; exit 2 ;;
esac
