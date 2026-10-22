#!/usr/bin/env bash
# Host-side: NetworkManager polkit rule shipped, installed, staged; no prompts on :0.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"; R="$HERE/49-tesla-linux-networkmanager.rules"; f=0
ck(){ if eval "$2"; then echo "PASS: $1"; else echo "FAIL: $1"; f=1; fi; }
ck "rule file exists" "test -s '$R'"
ck "rule grants NM prefix" "grep -q 'org.freedesktop.NetworkManager.' '$R'"
ck "rule keyed on netdev" "grep -q 'isInGroup(\"netdev\")' '$R'"
ck "rule not gated on subject.active (background session)" "! grep -q 'subject.active' '$R'"
ck "no SSID/psk in rule" "! grep -v '^//' '$R' | grep -Eiq 'ssid|psk'"
ck "installer installs rule" "grep -q '/etc/polkit-1/rules.d/49-tesla-linux-networkmanager.rules' '$HERE/install-tesla-linux.sh'"
ck "installer adds user to netdev" "grep -q 'usermod -aG netdev' '$HERE/install-tesla-linux.sh'"
ck "image stages rule" "grep -q '49-tesla-linux-networkmanager.rules' '$HERE/build-image.sh'"
if command -v node >/dev/null; then
  ck "rule evaluates YES for netdev wifi.scan, null otherwise" "node -e '
var fn;global.polkit={Result:{YES:\"yes\"},addRule:function(f){fn=f}};eval(require(\"fs\").readFileSync(\"$R\",\"utf8\"));
var s=function(g){return{isInGroup:function(x){return x==g}}};
if(fn({id:\"org.freedesktop.NetworkManager.wifi.scan\"},s(\"netdev\"))!==\"yes\")process.exit(1);
if(fn({id:\"org.freedesktop.NetworkManager.wifi.scan\"},s(\"x\"))!==undefined)process.exit(1);
if(fn({id:\"org.freedesktop.login1.reboot\"},s(\"netdev\"))!==undefined)process.exit(1);'"
fi
exit $f
