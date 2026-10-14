#!/usr/bin/env bash
# Regenerates userdata.sh: a self-contained DigitalOcean startup script that
# writes this repo onto the droplet and runs setup.sh. Run after editing any file.
set -euo pipefail
cd "$(dirname "$0")"
out=userdata.sh
{
  cat <<'HEAD'
#!/bin/bash
# always-green: paste into DigitalOcean > Create Droplet > Startup scripts.
# Only edit the next line. Progress log on the droplet: /var/log/always-green-setup.log
TELEGRAM_BOT_TOKEN="PASTE_BOT_TOKEN_HERE"

set -euo pipefail
exec >/var/log/always-green-setup.log 2>&1
D=/root/always-green
mkdir -p "$D/bin" "$D/systemd"
HEAD
  for f in setup.sh config.env.example bin/*.sh systemd/*; do
    grep -q '^AG_EOF$' "$f" && { echo "$f contains the heredoc marker" >&2; exit 1; }
    printf "\ncat >\"\$D/%s\" <<'AG_EOF'\n" "$f"
    cat "$f"
    printf 'AG_EOF\n'
  done
  cat <<'TAIL'

chmod +x "$D/setup.sh" "$D"/bin/*.sh
sed "s|^TELEGRAM_BOT_TOKEN=.*|TELEGRAM_BOT_TOKEN=$TELEGRAM_BOT_TOKEN|" "$D/config.env.example" >"$D/config.env"
"$D/setup.sh"
echo "always-green setup done"
TAIL
} >"$out"
chmod +x "$out"
echo "wrote $out ($(wc -c <"$out") bytes)"
