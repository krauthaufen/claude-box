#!/bin/sh
# Container entrypoint (runs as root with only NET_ADMIN/SETUID/SETGID/SETPCAP):
# apply outbound network rules, then drop to the unprivileged user with no capabilities.
# Fails closed: if any rule can't be applied, claude does not start.
set -eu
die() { echo "claude-box: network setup failed: $*" >&2; exit 1; }

apply() {  # apply ACTION CIDR
  case "$2" in *:*) T=ip6tables ;; *) T=iptables ;; esac
  case "$1" in
    allow) $T -A OUTPUT -d "$2" -j ACCEPT || die "$1 $2" ;;
    block) $T -A OUTPUT -d "$2" -j REJECT || die "$1 $2" ;;
    *) die "unknown action '$1' (use allow/block)" ;;
  esac
}

iptables -A OUTPUT -o lo -j ACCEPT || die "iptables unavailable"
HAVE6=0; if ip6tables -A OUTPUT -o lo -j ACCEPT 2>/dev/null; then HAVE6=1; fi
for ns in $(awk '/^nameserver/{print $2}' /etc/resolv.conf); do
  case "$ns" in *:*) [ $HAVE6 = 1 ] && apply allow "$ns" ;; *) apply allow "$ns" ;; esac
done
printf '%s\n' "${CLAUDE_BOX_NET:-}" | sed 's/#.*//' | while read -r act cidr _; do
  [ -n "${act:-}" ] || continue
  case "$cidr" in *:*) [ $HAVE6 = 1 ] || continue ;; esac
  apply "$act" "$cidr"
done

exec setpriv --reuid="$BOX_UID" --regid="$BOX_GID" --init-groups \
  --inh-caps=-all --ambient-caps=-all --bounding-set=-all --no-new-privs \
  -- /usr/bin/tini -- claude "$@"
