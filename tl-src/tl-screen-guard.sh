#!/bin/sh
# Keeps the X screen at 1088x832 (the size the car page is laid out for).
# Something (session start / xfsettingsd) can shrink it to ~617x641 after X restarts;
# this re-applies the layout whenever it drifts.
W=1088; H=832
export DISPLAY=:0
while true; do
  cur=$(xdpyinfo 2>/dev/null | awk '/dimensions:/{print $2}')
  if [ -n "$cur" ] && [ "$cur" != "${W}x${H}" ]; then
    xrandr --fb 1920x1080 --output HDMI-1 --mode 1920x1080 --scale 1x1 2>/dev/null
    sleep 1
    xrandr --fb ${W}x${H} --output HDMI-1 --mode 1920x1080 --scale-from ${W}x${H} --primary 2>/dev/null
  fi
  sleep 5
done
