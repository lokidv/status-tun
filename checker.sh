#!/usr/bin/env bash
set -e

# ----- تنظیم‌های قابل تغییر -----
PORT="${PORT:-8080}"   # پورت HTTP
LOOP_SEC="${LOOP_SEC:-40}"   # حداکثر صبر پس از restart (ثانیه)
STEP="${STEP:-5}"           # بازهٔ هر چک (ثانیه)
LOG_LINES="${LOG_LINES:-600}"
APP_DIR=/opt/udp2raw-checker
PY=python3
UNIT=udp2raw-flask.service
# ---------------------------------

echo "[*] (Re)installing udp2raw Flask checker v2 ..."

# -------- python ----------
if ! command -v "$PY" &>/dev/null; then
  if command -v apt-get &>/dev/null; then
    apt-get update -qq && apt-get install -y python3
  else
    yum install -y python3
  fi
fi

# -------- Flask -----------
if ! "$PY" - <<<'import flask' &>/dev/null; then
  if command -v apt-get &>/dev/null && apt-cache show python3-flask &>/dev/null; then
    apt-get install -y python3-flask
  else
    command -v pip3 &>/dev/null || { apt-get install -y python3-pip 2>/dev/null || yum install -y python3-pip; }
    pip3 install -U --no-cache-dir flask
  fi
fi

# ---- stop old version ----
systemctl stop "$UNIT" 2>/dev/null || true

# ---------- app.py ----------
mkdir -p "$APP_DIR"
cat >"$APP_DIR/app.py" <<'PY'
from flask import Flask, jsonify
import subprocess, time, os, re

STEP      = int(os.getenv("STEP", 5))
LIMIT     = int(os.getenv("LOOP_SEC", 40))
LOG_LINES = int(os.getenv("LOG_LINES", 600))

app = Flask(__name__)

def svc_name(name):
    return name if name.startswith("udp2raw-") else f"udp2raw-{name}"

def check(name):
    svc = f"{svc_name(name)}.service"
    if subprocess.run(["systemctl", "status", svc],
                      stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
        return "NOT_FOUND"
    start = int(time.time())
    subprocess.run(["systemctl", "restart", svc])
    waited = 0
    while waited < LIMIT:
        time.sleep(STEP)
        logs = subprocess.check_output(
            ["journalctl", "-u", svc, "--since", f"@{start}",
             "-n", str(LOG_LINES), "--no-pager"],
            text=True, errors="ignore")
        if re.search(r"handshake2", logs):
            return "TWO_HANDSHAKES"
        waited += STEP
    return "ONE_HANDSHAKE"

@app.route("/<name>")
def status(name):
    return jsonify(service=name, status=check(name))

if __name__ == "__main__":
    port = int(os.getenv("PORT", 8080))
    app.run(host="0.0.0.0", port=port)
PY

# -------- systemd unit --------
cat >/etc/systemd/system/"$UNIT" <<UNIT
[Unit]
Description=udp2raw Handshake Checker (Flask v2)
After=network.target

[Service]
Type=simple
Environment=PORT=$PORT STEP=$STEP LOOP_SEC=$LOOP_SEC LOG_LINES=$LOG_LINES
WorkingDirectory=$APP_DIR
ExecStart=$PY $APP_DIR/app.py
Restart=always
RestartSec=2

[Install]
WantedBy=multi-user.target
UNIT

systemctl daemon-reload
systemctl enable --now "$UNIT"
echo "[*] v2 ready -> test: curl http://\$(hostname -I | awk '{print \$1}'):$PORT/<service-name>"
