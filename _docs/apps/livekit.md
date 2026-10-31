[← Sommaire](../README.md)


## LiveKit — relais réseau via VPS (Element Call)

Le Cloudflare Tunnel (HTTP/S uniquement) ne peut pas transporter le flux média WebRTC
(UDP) de LiveKit. `harkesh` étant derrière NAT sans IP publique routable, le flux média
est relayé via un tunnel **WireGuard** vers un VPS avec IP publique :

```
Participant  ──UDP/TCP──▶  VPS (203.0.113.10)  ──WireGuard──▶  pod livekit (10.10.0.2)
                            DNAT 7882/udp, 7881/tcp
```

- **Signaling** (WebSocket, port 7880) passe normalement par le Cloudflare Tunnel comme
  le reste — pas besoin du VPS pour ça.
- **Média** (UDP 7882 + TCP ICE 7881) : le VPS fait du DNAT + MASQUERADE (`iptables`,
  `/etc/ufw/before.rules`) vers `10.10.0.2` à travers le tunnel WireGuard.
- L'interface WireGuard tourne **dans le netns du pod `livekit`** (initContainer
  `wg-setup`, capability `NET_ADMIN`), pas sur l'hôte `harkesh` — évite toute
  interférence avec le routage de la machine (cf. incident du 2026-09-01 où WireGuard
  sur l'hôte cassait `cloudflared`).
- `config.yaml` de LiveKit force `node_ip: "203.0.113.10"` (IP du VPS) — c'est cette
  IP que LiveKit annonce aux clients comme candidat ICE, pas celle du pod/cluster.

**Config VPS** (`203.0.113.10`, Debian 13, Vexcloud) — `/etc/wireguard/wg0.conf` :
```
[Interface]
Address = 10.10.0.1/24
ListenPort = 51820
PrivateKey = <clé privée VPS>

[Peer]
# pod livekit
PublicKey = <clé publique du pod, voir ci-dessous>
AllowedIPs = 10.10.0.2/32
```

Ports ouverts côté VPS (`ufw`) : `51820/udp` (WireGuard), `7882/udp` + `7881/tcp` (média,
DNAT vers `10.10.0.2`). `net.ipv4.ip_forward=1` + `DEFAULT_FORWARD_POLICY="ACCEPT"`.

**Régénérer la clé WireGuard du pod** (si compromise/perdue) :
```bash
wg genkey | tee privatekey | wg pubkey  # noter la clé publique affichée
```
1. Mettre la clé **privée** dans le champ `wg-private-key` de l'item 1Password `livekit`
2. Mettre à jour le `PublicKey` du peer `# pod livekit` dans `/etc/wireguard/wg0.conf`
   sur le VPS, puis `sudo systemctl restart wg-quick@wg0`
3. Redémarrer le pod : `kubectl -n livekit rollout restart deploy/livekit`
