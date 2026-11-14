#!/usr/bin/env python3
# awg-to-mihomo.py client.conf ["имя"] — .conf из wg-easy → YAML-прокси для Mihomo (AWG 3.x, version: 3). См. docs/awg.md
import re, sys

conf = open(sys.argv[1], encoding="utf-8").read()
name = sys.argv[2] if len(sys.argv) > 2 else "🛡 AWG"
sect = None; iface = {}; peer = {}
for line in conf.splitlines():
    line = line.strip()
    if not line or line.startswith("#"): continue
    if line.startswith("["): sect = line.strip("[]").lower(); continue
    k, _, v = line.partition("=")
    (iface if sect == "interface" else peer)[k.strip()] = v.strip()

host, port = peer["Endpoint"].rsplit(":", 1)
addrs = [a.strip() for a in iface["Address"].split(",")]
v4 = next(a for a in addrs if ":" not in a).split("/")[0]
v6 = next((a for a in addrs if ":" in a), None)

def q(v): return f'"{v}"'
out = [f"  - name: {q(name)}",
       "    type: wireguard",
       f"    server: {host}",
       f"    port: {port}",
       f"    ip: {v4}"]
if v6: out.append(f"    ipv6: {v6.split('/')[0]}")
out += [f"    private-key: {iface['PrivateKey']}",
        f"    public-key: {peer['PublicKey']}"]
if "PresharedKey" in peer: out.append(f"    pre-shared-key: {peer['PresharedKey']}")
out += ["    allowed-ips: ['0.0.0.0/0', '::/0']",
        f"    mtu: {iface.get('MTU', '1280')}",
        "    udp: true"]
if "PersistentKeepalive" in peer: out.append(f"    persistent-keepalive: {peer['PersistentKeepalive']}")
# Ключи Mihomo — в нижнем регистре; version: 3 обязателен для HeaderProtectionKey (mihomo#3118)
amap = {"Jc": "jc", "Jmin": "jmin", "Jmax": "jmax", "S1": "s1", "S2": "s2", "S3": "s3", "S4": "s4",
        "H1": "h1", "H2": "h2", "H3": "h3", "H4": "h4", "I1": "i1", "I2": "i2", "I3": "i3", "I4": "i4", "I5": "i5",
        "HeaderProtectionKey": "header-protection-key", "ContentPaddingAddition": "content-padding-addition",
        "RandomTrailers": "random-trailers", "DisableCookies": "disable-cookies"}
awg = []
for k, mk in amap.items():
    if k not in iface: continue
    v = iface[k]
    if k in ("RandomTrailers", "DisableCookies"):
        v = "true" if v.lower() in ("on", "true", "1") else "false"
    elif not re.fullmatch(r"\d+", v):
        v = q(v)
    awg.append(f"      {mk}: {v}")
if awg:
    v3 = "HeaderProtectionKey" in iface
    out.append("    amnezia-wg-option:")
    out.append(f"      version: {3 if v3 else 2}")
    out += awg
print("\n".join(out))
