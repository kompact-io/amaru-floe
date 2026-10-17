{pkgs}: {
  # Checks the kernel's own listening-socket table (/proc/net/tcp) for
  # `host:port` in state 0A (TCP_LISTEN) -- confirms the listener is
  # actually bound, which is the real readiness signal amaru's N2N port
  # needs. Two things this deliberately isn't:
  #
  # - A bare TCP connect (`exec 3<>/dev/tcp/host/port`, or `nc -z`): that's
  #   a real SYN amaru's own listener accepts, then sees abandoned before
  #   any mini-protocol handshake happens -- logged every `period_seconds`
  #   as `mux.failed ... recv_header_leading_edge ... unexpected end of
  #   file`. Reading /proc/net/tcp touches no socket at all -- the kernel
  #   already has this table, so there's nothing for amaru to log, however
  #   often this polls.
  # - amaru's `--pid-export` pidfile (`kill -0 $(cat pidfile)`, the
  #   previous approach here): that only says the process is alive, not
  #   that it's finished ledger/stake-distribution setup and actually
  #   called `bind()`/`listen()` -- amaru's startup does real work
  #   in between (seconds on preprod), so a pidfile-only check still let
  #   floe's `depends_on.amaru.condition = "process_healthy"` fire before
  #   the port was open, racing floe's first connect attempt into
  #   "error connecting bearer / Connection refused" often enough in
  #   practice to be the stack's main startup flake. amaru has no
  #   `/health` endpoint (that's floe's own `--metrics`) to check instead.
  listenProbe = host: port:
    toString (pkgs.writeShellScript "listen-probe-${toString port}" ''
      set -eu
      IFS=. read -r o1 o2 o3 o4 <<< "${host}"
      hexaddr=$(printf '%02X%02X%02X%02X:%04X' "$o4" "$o3" "$o2" "$o1" "${toString port}")
      awk -v addr="$hexaddr" '$2 == addr && $4 == "0A" { found=1 } END { exit !found }' /proc/net/tcp
    '');
}
