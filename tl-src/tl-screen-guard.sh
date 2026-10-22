#!/bin/sh
# Keeps the X screen at the target size. Target = /run/tesla-linux/screen-size
# ("WxH", written by ta_screen_api for desktop.html Fit: Adaptive); default
# 1088x832 (the size the car page is laid out for). Something (session start /
# xfsettingsd) can shrink it to ~617x641 after X restarts; this re-applies it.
STATE=/run/tesla-linux/screen-size
LOCK=/run/tesla-linux/screen.lock
export DISPLAY=:0
target() {
  t=$(cat "$STATE" 2>/dev/null | tr -d ' \n')
  case "$t" in
    [0-9]*x[0-9]*) W=${t%x*}; H=${t#*x}
      if [ "$W" -ge 640 ] && [ "$W" -le 1920 ] && [ "$H" -ge 480 ] && [ "$H" -le 1080 ]; then return; fi ;;
  esac
  W=1088; H=832
}
apply() {
  xrandr --fb 1920x1080 --output HDMI-1 --mode 1920x1080 --scale 1x1 2>/dev/null
  sleep 1
  xrandr --fb ${W}x${H} --output HDMI-1 --mode 1920x1080 --scale-from ${W}x${H} --primary 2>/dev/null
}
while true; do
  target
  cur=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
  if [ -n "$cur" ] && [ "$cur" != "${W}x${H}" ]; then
    if [ -w "$LOCK" ] || [ -w "${LOCK%/*}" ]; then
      ( flock -n 9 || exit 0; apply ) 9>>"$LOCK"
    else
      apply
    fi
  fi
  sleep 5
done
