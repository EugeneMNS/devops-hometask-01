#!/usr/bin/env bash
# Ubuntu 26.04 compatibility fix from containerd/containerd#14487.
# Keep host restrictions and AppArmor enforcement enabled.
set -euo pipefail

[[ "$EUID" -eq 0 ]] || { echo 'Run this script with sudo.' >&2; exit 1; }
repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
candidate="$repo_dir/ops/cri-containerd.apparmor.d"
baseline="$repo_dir/ops/cri-containerd.apparmor.base"
target=/etc/apparmor.d/cri-containerd.apparmor.d
restriction_before="$(sysctl -n kernel.apparmor_restrict_unprivileged_unconfined)"

python3 - "$baseline" "$candidate" <<'PY'
from pathlib import Path
import sys
base = Path(sys.argv[1]).read_text()
expected = base.replace(
    '  signal (send,receive) peer=cri-containerd.apparmor.d,',
    '  signal (send,receive) peer=cri-containerd.apparmor.d,\n  signal (send,receive) peer=cri-containerd.apparmor.d//&unconfined,',
).replace(
    '  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,',
    '  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d,\n  ptrace (trace,tracedby,read,readby) peer=cri-containerd.apparmor.d//&unconfined,',
)
assert Path(sys.argv[2]).read_text() == expected, 'Unexpected changes in AppArmor profile'
PY

apparmor_parser -Q -K "$candidate"
if [[ -e "$target" ]] && ! cmp -s "$target" "$baseline" && ! cmp -s "$target" "$candidate"; then
  echo 'A custom host profile already exists; review it before applying this fix.' >&2
  exit 1
fi

backup_dir="/var/backups/hw6-apparmor/$(date -u +%Y%m%dT%H%M%SZ)"
install -d -m 700 "$backup_dir"
had_target=false
if [[ -e "$target" ]]; then
  cp -p "$target" "$backup_dir/prior-profile"
  had_target=true
else
  cp "$baseline" "$backup_dir/prior-profile"
fi

rollback() {
  echo 'Verification failed; restoring the prior AppArmor policy.' >&2
  apparmor_parser -r -K "$backup_dir/prior-profile" || true
  if $had_target; then
    install -m 644 "$backup_dir/prior-profile" "$target"
  else
    rm -f "$target"
  fi
}
trap rollback ERR
install -m 644 "$candidate" "$target"
apparmor_parser -r -K "$target"
grep -Fx 'cri-containerd.apparmor.d (enforce)' /sys/kernel/security/apparmor/profiles

setpriv --reuid 65534 --regid 65534 --clear-groups \
  aa-exec -p cri-containerd.apparmor.d -- sh -ec '
    cat /proc/self/attr/current
    sleep 30 & child_pid=$!
    trap "kill $child_pid 2>/dev/null || true" EXIT
    kill -URG "$child_pid"
    kill -TERM "$child_pid"
    wait "$child_pid" 2>/dev/null || true
    echo "Confined process signal check passed"
  '
[[ "$(sysctl -n kernel.apparmor_restrict_unprivileged_unconfined)" == "$restriction_before" ]]
trap - ERR
echo 'AppArmor compatibility fix loaded; host restriction remains unchanged.'
