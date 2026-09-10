#!/usr/bin/env bash
# Host-side plantable gates: no background apt auto-patch.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
INSTALL="$HERE/install-tesla-linux.sh"
fail=0
n_pass=0
n_fail=0

pass() { echo "PASS: $*"; n_pass=$((n_pass + 1)); }
bad() { echo "FAIL: $*"; n_fail=$((n_fail + 1)); fail=1; }

expect_ok() {
    local name="$1"
    shift
    if "$@" >/tmp/tl-apt-ok.out 2>/tmp/tl-apt-ok.err; then
        pass "$name"
    else
        bad "$name (exit $?) stderr=$(tr '\n' ' ' </tmp/tl-apt-ok.err)"
    fi
}

expect_fail() {
    local name="$1" needle="$2"
    shift 2
    if "$@" >/tmp/tl-apt-bad.out 2>/tmp/tl-apt-bad.err; then
        bad "$name (expected fail, passed)"
    elif grep -q "$needle" /tmp/tl-apt-bad.err; then
        pass "$name"
    else
        bad "$name (wrong error: $(tr '\n' ' ' </tmp/tl-apt-bad.err))"
    fi
}

grep -q 'unattended-upgrades.service' "$INSTALL" \
    && pass "install names unattended-upgrades.service" \
    || bad "install missing unattended-upgrades.service"
grep -q 'apt-daily.timer' "$INSTALL" \
    && pass "install names apt-daily.timer" \
    || bad "install missing apt-daily.timer"
grep -q 'apt-daily-upgrade.timer' "$INSTALL" \
    && pass "install names apt-daily-upgrade.timer" \
    || bad "install missing apt-daily-upgrade.timer"
grep -q '99tesla-linux-no-unattended' "$INSTALL" \
    && pass "install writes 99tesla-linux-no-unattended" \
    || bad "install missing 99tesla-linux-no-unattended"
grep -q 'APT::Periodic::Unattended-Upgrade "0"' "$INSTALL" \
    && pass "install sets Unattended-Upgrade 0" \
    || bad "install missing Unattended-Upgrade 0"
grep -q 'APT::Periodic::Update-Package-Lists "0"' "$INSTALL" \
    && pass "install sets Update-Package-Lists 0" \
    || bad "install missing Update-Package-Lists 0"
if grep -Eq 'systemctl[[:space:]]+mask[[:space:]]+apt\.service' "$INSTALL"; then
    bad "install masks apt.service (would break manual apt)"
else
    pass "install does not mask apt.service"
fi
if grep -Eq 'apt-get[[:space:]]+(purge|remove)[[:space:]]+.*\bapt\b' "$INSTALL"; then
    bad "install removes apt"
else
    pass "install does not remove apt"
fi

TREE="$(mktemp -d /tmp/tl-apt-tree.XXXXXX)"
cleanup() { rm -rf "$TREE"; }
trap cleanup EXIT

plant() {
    local t="$1" u
    rm -rf "$t"
    mkdir -p "$t/etc/systemd/system/multi-user.target.wants" \
             "$t/etc/systemd/system/timers.target.wants" \
             "$t/etc/apt/apt.conf.d"
    for u in unattended-upgrades.service unattended-upgrades.timer \
             apt-daily.timer apt-daily.service \
             apt-daily-upgrade.timer apt-daily-upgrade.service; do
        ln -sfn /dev/null "$t/etc/systemd/system/$u"
    done
    cat > "$t/etc/apt/apt.conf.d/99tesla-linux-no-unattended" <<'EOF'
APT::Periodic::Enable "0";
APT::Periodic::Update-Package-Lists "0";
APT::Periodic::Download-Upgradeable-Packages "0";
APT::Periodic::AutocleanInterval "0";
APT::Periodic::Unattended-Upgrade "0";
EOF
}

plant "$TREE"
expect_ok "verify-no-unattended good tree" "$INSTALL" --verify-no-unattended "$TREE"

rm -f "$TREE/etc/systemd/system/apt-daily.timer"
expect_fail "unmasked apt-daily.timer fails gate" "unmasked" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

rm -f "$TREE/etc/systemd/system/unattended-upgrades.service"
expect_fail "unmasked unattended-upgrades.service fails gate" "unmasked" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

rm -f "$TREE/etc/systemd/system/apt-daily-upgrade.timer"
expect_fail "unmasked apt-daily-upgrade.timer fails gate" "unmasked" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

ln -sfn /lib/systemd/system/apt-daily.timer \
    "$TREE/etc/systemd/system/timers.target.wants/apt-daily.timer"
expect_fail "apt-daily.timer still in wants fails gate" "wants" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

sed -i 's/Unattended-Upgrade "0"/Unattended-Upgrade "1"/' \
    "$TREE/etc/apt/apt.conf.d/99tesla-linux-no-unattended"
expect_fail "Unattended-Upgrade 1 fails gate" "Unattended-Upgrade" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

rm -f "$TREE/etc/apt/apt.conf.d/99tesla-linux-no-unattended"
expect_fail "missing apt config fails gate" "99tesla-linux-no-unattended" \
    "$INSTALL" --verify-no-unattended "$TREE"
plant "$TREE"

ln -sfn /dev/null "$TREE/etc/systemd/system/apt.service"
expect_fail "masked apt.service fails gate" "apt.service is masked" \
    "$INSTALL" --verify-no-unattended "$TREE"

echo
echo "selftest-no-unattended: $n_pass passed, $n_fail failed"
exit "$fail"
