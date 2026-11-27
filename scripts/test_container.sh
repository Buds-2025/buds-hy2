#!/usr/bin/env bash
# Run only in a fresh disposable CI container.
set -euo pipefail
[[ -f /.dockerenv && ! -e /etc/hysteria/config.yaml && ! -e /usr/local/bin/buds ]] || exit 1
umask 077
work=$(mktemp -d)
if ! printf 'node.invalid\n24443\n\n2\n' | bash /src/install.sh > "$work/install.log" 2>&1; then
    sed '/部署完成/,$d' "$work/install.log" | tail -25 >&2
    exit 1
fi
buds hy2 version
hy2 version
buds hy2 stop
buds hy2 start
mkdir "$work/public"
printf 'hy2-container-ok\n' > "$work/public/probe"
python3 -m http.server 18080 --bind 127.0.0.1 --directory "$work/public" > "$work/http.log" 2>&1 &
sed '1s/node.invalid:/127.0.0.1:/' /etc/hysteria/client.yaml > "$work/client.yaml"
hysteria client -c "$work/client.yaml" > "$work/client.log" 2>&1 &
for attempt in {1..15}; do
    if reply=$(curl -qfsS --max-time 3 --noproxy '' --proxy socks5h://127.0.0.1:1080 http://127.0.0.1:18080/probe) &&
        [[ "$reply" == hy2-container-ok ]]; then
        echo "Installed native HY2 client and server successfully exchanged data."
        exit 0
    fi
    sleep 1
done
echo "The installed native client could not reach the test HTTP server." >&2
exit 1
