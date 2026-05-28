#!/bin/bash

RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
CYAN='\033[1;36m'
MAGENTA='\033[1;35m'
NC='\033[0m'

clear
echo -e "${CYAN}======================================================${NC}"
echo -e "${MAGENTA}   ███╗   ███╗██╗██████╗     ██████╗  █████╗ ███╗   ██╗███████╗██╗     ${NC}"
echo -e "${MAGENTA}   ████╗ ████║██║██╔══██╗    ██╔══██╗██╔══██╗████╗  ██║██╔════╝██║     ${NC}"
echo -e "${MAGENTA}   ██╔████╔██║██║██████╔╝    ██████╔╝███████║██╔██╗ ██║█████╗  ██║     ${NC}"
echo -e "${MAGENTA}   ██║╚██╔╝██║██║██╔══██╗    ██╔═══╝ ██╔══██║██║╚██╗██║██╔══╝  ██║     ${NC}"
echo -e "${MAGENTA}   ██║ ╚═╝ ██║██║██║  ██║    ██║     ██║  ██║██║ ╚████║███████╗███████╗${NC}"
echo -e "${MAGENTA}   ╚═╝     ╚═╝╚═╝╚═╝  ╚═╝    ╚═╝     ╚═╝  ╚═╝╚═╝  ╚═══╝╚══════╝╚══════╝${NC}"
echo -e "${CYAN}======================================================${NC}"
echo -e "${YELLOW}[*] Installing MIR Advanced Proxy & Tunneling System...${NC}"

if [[ $EUID -ne 0 ]]; then
    echo -e "${RED}[✗] Please run as root!${NC}"
    exit 1
fi

IP=$(curl -s -4 api.ipify.org || curl -s -4 ifconfig.me)

# ============ CONFIGURATION ============
read -p "Enter MIR Admin Username: " ADMIN_USER
read -p "Enter MIR Admin Password: " ADMIN_PASS
read -p "Enter MIR Panel Port [Default: 2096]: " PANEL_PORT
PANEL_PORT=${PANEL_PORT:-2096}
read -p "Enter Proxy Port (for VLESS/WS) [Default: 443]: " PROXY_PORT
PROXY_PORT=${PROXY_PORT:-443}

# ============ DEPENDENCIES ============
echo -e "${YELLOW}[1/5] Installing Dependencies & Python...${NC}"
apt update -qq
apt install -y -qq curl wget unzip jq python3 python3-pip cron iptables
pip3 install flask psutil >/dev/null 2>&1 || pip3 install flask psutil --break-system-packages >/dev/null 2>&1

# ============ XRAY CORE (ANTI-DPI & FRAGMENTATION) ============
echo -e "${YELLOW}[2/5] Installing Xray Core...${NC}"
bash -c "$(curl -L https://github.com/XTLS/Xray-install/raw/main/install-release.sh)" @ install >/dev/null 2>&1

# ساخت کانفیگ اولیه Xray با Fragmentation
cat > /usr/local/etc/xray/config.json << EOF
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "port": $PROXY_PORT,
      "protocol": "vless",
      "settings": {
        "clients": [],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/mir-tunnel" }
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {
        "domainStrategy": "UseIP"
      },
      "streamSettings": {
        "sockopt": {
          "tcpFastOpen": true
        }
      }
    },
    {
      "tag": "fragment-out",
      "protocol": "freedom",
      "settings": {
        "fragment": {
          "packets": "tlshello",
          "length": "100-200",
          "interval": "10-20"
        }
      }
    }
  ],
  "routing": {
    "rules": [
      {
        "type": "field",
        "network": "tcp",
        "outboundTag": "fragment-out"
      }
    ]
  }
}
EOF
systemctl restart xray
systemctl enable xray

# ============ AUTO TROUBLESHOOTING & TUNNEL ============
echo -e "${YELLOW}[3/5] Setting up Auto-Troubleshooting & Tunnel rules...${NC}"
cat > /usr/local/bin/mir-watchdog.sh << 'EOF'
#!/bin/bash
# بررسی وضعیت Xray و اتصال شبکه
if ! systemctl is-active --quiet xray; then
    systemctl restart xray
    echo "$(date): Xray restarted by watchdog" >> /var/log/mir-watchdog.log
fi
# در صورت نیاز به تانل معکوس (Reverse Tunnel) بین سرور ایران و خارج، دستورات iptables یا SSH Reverse اینجا قرار می‌گیرد.
EOF
chmod +x /usr/local/bin/mir-watchdog.sh
(crontab -l 2>/dev/null; echo "*/5 * * * * /usr/local/bin/mir-watchdog.sh") | crontab -

# ============ MIR PYTHON WEB PANEL ============
echo -e "${YELLOW}[4/5] Installing MIR Web Panel...${NC}"
mkdir -p /opt/mir-panel
cat > /opt/mir-panel/app.py << EOF
import os, json, uuid, psutil
from flask import Flask, request, render_template_string, Response

app = Flask(__name__)

ADMIN_USER = "$ADMIN_USER"
ADMIN_PASS = "$ADMIN_PASS"
XRAY_CONF = "/usr/local/etc/xray/config.json"
PROXY_PORT = $PROXY_PORT

def check_auth(username, password):
    return username == ADMIN_USER and password == ADMIN_PASS

def authenticate():
    return Response('Access Denied', 401, {'WWW-Authenticate': 'Basic realm="MIR Panel"'})

def requires_auth(f):
    def decorated(*args, **kwargs):
        auth = request.authorization
        if not auth or not check_auth(auth.username, auth.password):
            return authenticate()
        return f(*args, **kwargs)
    decorated.__name__ = f.__name__
    return decorated

HTML_TEMPLATE = """
<!DOCTYPE html>
<html lang="fa" dir="rtl">
<head>
    <meta charset="UTF-8">
    <title>MIR Panel | Advanced DPI Evasion</title>
    <link href="https://cdn.jsdelivr.net/npm/bootstrap@5.3.0/dist/css/bootstrap.min.css" rel="stylesheet">
    <style>body { background: #1a1d20; color: #fff; font-family: Tahoma; } .card { background: #212529; border: 1px solid #495057; }</style>
</head>
<body>
<div class="container mt-5">
    <h2 class="text-info text-center mb-4">MIR Advanced System</h2>
    
    <div class="row text-center mb-4">
        <div class="col-md-6"><div class="card p-3"><h5>CPU</h5><h3 class="text-warning">{{ cpu }}%</h3></div></div>
        <div class="col-md-6"><div class="card p-3"><h5>RAM</h5><h3 class="text-warning">{{ ram }}%</h3></div></div>
    </div>

    <div class="card p-4">
        <h4 class="text-success mb-3">ساخت کانفیگ VLESS + WS + Fragment</h4>
        <form action="/add" method="POST">
            <div class="input-group mb-3">
                <input type="text" name="email" class="form-control bg-dark text-white border-secondary" placeholder="نام کاربر (مثلا: User1)" required>
                <button type="submit" class="btn btn-primary">تولید کانفیگ</button>
            </div>
        </form>
        {% if msg %}
        <div class="alert alert-info mt-3" style="direction: ltr; text-align: left;">
            <b>UUID:</b> {{ new_uuid }} <br>
            <b>VLESS Link (CDN Ready):</b><br>
            <textarea class="form-control mt-2 bg-dark text-success border-secondary" rows="3" readonly>{{ msg }}</textarea>
        </div>
        {% endif %}
    </div>
</div>
</body>
</html>
"""

@app.route('/')
@requires_auth
def index():
    return render_template_string(HTML_TEMPLATE, cpu=psutil.cpu_percent(), ram=psutil.virtual_memory().percent)

@app.route('/add', methods=['POST'])
@requires_auth
def add_user():
    email = request.form['email']
    new_uuid = str(uuid.uuid4())
    
    with open(XRAY_CONF, 'r') as f:
        data = json.load(f)
        
    data['inbounds'][0]['settings']['clients'].append({"id": new_uuid, "email": email})
    
    with open(XRAY_CONF, 'w') as f:
        json.dump(data, f, indent=2)
        
    os.system("systemctl restart xray")
    
    ip = "$IP"
    # ساخت لینک VLESS استاندارد با قابلیت کار پشت کلادفلر
    vless_link = f"vless://{new_uuid}@{ip}:{PROXY_PORT}?type=ws&path=%2Fmir-tunnel&security=none#MIR-{email}"
    
    return render_template_string(HTML_TEMPLATE, cpu=psutil.cpu_percent(), ram=psutil.virtual_memory().percent, msg=vless_link, new_uuid=new_uuid)

if __name__ == '__main__':
    app.run(host='0.0.0.0', port=int($PANEL_PORT))
EOF

cat > /etc/systemd/system/mir-panel.service << EOF
[Unit]
Description=MIR Web Panel
After=network.target

[Service]
User=root
WorkingDirectory=/opt/mir-panel
ExecStart=/usr/bin/python3 app.py
Restart=always

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable mir-panel >/dev/null 2>&1
systemctl start mir-panel

# ============ FIREWALL ============
echo -e "${YELLOW}[5/5] Configuring Ports...${NC}"
iptables -A INPUT -p tcp --dport $PANEL_PORT -j ACCEPT
iptables -A INPUT -p tcp --dport $PROXY_PORT -j ACCEPT

echo -e "${GREEN}======================================================${NC}"
echo -e "${MAGENTA} ✅ MIR PANEL & XRAY FRAGMENTATION INSTALLED!${NC}"
echo -e "${GREEN}======================================================${NC}"
echo -e "${CYAN} 🌐 MIR Web Panel :${NC} http://$IP:$PANEL_PORT"
echo -e "${CYAN} 👤 Admin User    :${NC} $ADMIN_USER"
echo -e "${CYAN} 🔑 Admin Pass    :${NC} $ADMIN_PASS"
echo -e "${CYAN} 🛡️ Proxy Port    :${NC} $PROXY_PORT (WebSocket)"
echo -e "${GREEN}======================================================${NC}"
echo -e "You can now route your Cloudflare IP or CDN through the proxy port."
