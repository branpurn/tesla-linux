#!/usr/bin/env bash
# Source-routing selftest: static gates always; functional netns test when root.
set -uo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
S="$HERE/tesla-linux-srcroute.sh"; C="$HERE/99-tesla-linux-srcroute.conf"
fail=0; pass(){ echo "PASS: $*"; }; bad(){ echo "FAIL: $*"; fail=1; }
bash -n "$S" && pass "script parses" || bad "script syntax"
for k in arp_ignore=1 arp_announce=2 rp_filter=2; do
  grep -Eq "all\.${k%%=*} *= *${k#*=}" "$C" && pass "sysctl $k" || bad "sysctl $k"; done
grep -q 'dhcp4-change' "$S" && pass "handles dhcp4-change" || bad "dhcp4-change"
grep -q 'ip "\$fam" rule add from' "$S" && pass "from-addr rules" || bad "rules"
bash "$HERE/install-tesla-linux.sh" --verify-srcroute "$HERE/__nonexistent__" >/dev/null 2>&1 \
  && bad "verify-srcroute accepted empty root" || pass "verify-srcroute fails on empty root"
if [ "$(id -u)" = 0 ] && ip netns add tlsr-a 2>/dev/null; then
  trap 'ip netns del tlsr-a 2>/dev/null; ip netns del tlsr-b 2>/dev/null' EXIT
  ip netns add tlsr-b
  ip link add lte type veth peer name pl netns tlsr-b
  ip link add wl type veth peer name pw netns tlsr-b
  ip link set lte netns tlsr-a; ip link set wl netns tlsr-a
  A="ip netns exec tlsr-a"; B="ip netns exec tlsr-b"
  $A ip addr add 192.168.1.100/24 dev lte; $A ip addr add 192.168.1.48/24 dev wl
  $B ip link set pl up; $B ip link set pw up
  $A ip link set lte up; $A ip link set wl up; $A ip link set lo up
  $A ip route add default via 192.168.1.1 dev lte metric 101
  $A ip route add default via 192.168.1.1 dev wl metric 600
  $A ip route del 192.168.1.0/24 dev wl 2>/dev/null; $A ip route add 192.168.1.0/24 dev wl src 192.168.1.48 metric 600
  $A bash "$S" wl up
  r=$($A ip route get 192.168.1.50 from 192.168.1.48); echo "$r" | grep -q 'dev wl' && pass "48 -> wl" || bad "48 route: $r"
  r=$($A ip route get 8.8.8.8 from 192.168.1.48); echo "$r" | grep -q 'dev wl' && pass "48 default -> wl" || bad "48 default: $r"
  r=$($A ip route get 192.168.1.50 from 192.168.1.100); echo "$r" | grep -q 'dev lte' && pass "100 -> lte" || bad "100 route: $r"
  $A ip link set wl down; $A bash "$S" wl down
  $A ip rule | grep -q 192.168.1.48 && bad "stale rule after down" || pass "down removes rule"
  ip netns del tlsr-a; ip netns del tlsr-b
else echo "SKIP: netns functional test (needs root)"; fi
[ $fail = 0 ] && echo "ALL PASS" ; exit $fail
