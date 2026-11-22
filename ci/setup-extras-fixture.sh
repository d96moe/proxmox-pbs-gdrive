#!/bin/bash
# =============================================================================
# ci/setup-extras-fixture.sh — simulate a host with manual additions
#
# Run on the CI VM in Scenario A, BEFORE the config backup. It builds the same
# shape a real host can have outside PVE/PBS:
#   - nginx as a reverse proxy (default site removed) → a helper on 127.0.0.1
#   - a small helper service: /usr/local/bin + /etc/systemd/system unit
#   - an iptables NAT rule persisted by iptables-persistent
#   - a sysctl drop-in
# The matching EXTRA_* values live in ci/config_ci*.env. Scenario B
# (scenario_b_spec.sh, "Host extras") checks the DR brings all of it back.
#
# Uses TEST-NET-2 (198.51.100.0/24) and loopback ports, so it touches nothing real.
# =============================================================================

set -euo pipefail

echo "iptables-persistent iptables-persistent/autosave_v4 boolean false" | debconf-set-selections
echo "iptables-persistent iptables-persistent/autosave_v6 boolean false" | debconf-set-selections
DEBIAN_FRONTEND=noninteractive apt-get install -y nginx iptables-persistent

# Helper service: answers every request with a fixed marker
cat > /usr/local/bin/ci-extras-echo.py << 'PYEOF'
#!/usr/bin/env python3
from http.server import BaseHTTPRequestHandler, HTTPServer

class H(BaseHTTPRequestHandler):
    def do_GET(self):
        body = b"ci-extras-ok\n"
        self.send_response(200)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a):
        pass

HTTPServer(("127.0.0.1", 8098), H).serve_forever()
PYEOF
chmod 755 /usr/local/bin/ci-extras-echo.py

cat > /etc/systemd/system/ci-extras-echo.service << 'EOF'
[Unit]
Description=CI host-extras fixture helper
After=network.target

[Service]
ExecStart=/usr/bin/python3 /usr/local/bin/ci-extras-echo.py
Restart=always
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF

# Reverse proxy site on :8081 → helper; drop the package default (default_server)
cat > /etc/nginx/sites-available/ci-extras << 'EOF'
server {
    listen 8081;
    location / {
        proxy_pass http://127.0.0.1:8098;
    }
}
EOF
ln -sf /etc/nginx/sites-available/ci-extras /etc/nginx/sites-enabled/ci-extras
rm -f /etc/nginx/sites-enabled/default

# NAT rule (TEST-NET-2) persisted the iptables-persistent way
iptables -t nat -C POSTROUTING -d 198.51.100.0/24 -j MASQUERADE 2>/dev/null \
    || iptables -t nat -A POSTROUTING -d 198.51.100.0/24 -j MASQUERADE
netfilter-persistent save

# sysctl drop-in with a value that differs from the kernel default
echo "net.ipv4.conf.all.log_martians=1" > /etc/sysctl.d/99-ci-extras.conf
sysctl --system >/dev/null

systemctl daemon-reload
systemctl enable --now ci-extras-echo
nginx -t
systemctl restart nginx
sleep 2

# Prove the fixture works before it is backed up
OUT="$(curl -fsS --max-time 5 http://127.0.0.1:8081/)"
[ "${OUT}" = "ci-extras-ok" ] || { echo "ERROR: fixture proxy returned '${OUT}'"; exit 1; }
echo "Host extras fixture ready: nginx :8081 → ci-extras-echo, NAT 198.51.100.0/24, log_martians=1"
