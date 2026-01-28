[![Repository License](https://img.shields.io/badge/license-GPL%20v3.0-brightgreen.svg)](COPYING)

# Keepalived Gateway

An intelligent gateway health monitoring and routing table management solution for high-availability clusters. The script ensures automatic selection of the best available default route and seamless state synchronization between VRRP Master and Slave nodes.

## TL;DR

### Installation

1. Clone the repository:

   ```bash
   git clone https://github.com/mgmsam/keepalived-gateway.git
   ```

2. Copy files to system directories:

   ```bash
   sudo cp ./keepalived-gateway/keepalived-gateway.sh      /usr/sbin/
   sudo cp ./keepalived-gateway/keepalived-gateway.conf    /etc/
   sudo cp ./keepalived-gateway/keepalived-gateway.service /etc/systemd/system/
   ```

### Configuration

Edit the configuration file to match your network environment:

```bash
sudo vi /etc/keepalived-gateway.conf
```

### Activation

1. Set execution permissions:

   ```bash
   sudo chmod --verbose u+rwx,go+rx /usr/sbin/keepalived-gateway.sh
   ```

2. Reload systemd, enable and start the service:

   ```bash
   sudo systemctl daemon-reload
   sudo systemctl enable --now keepalived-gateway
   ```

---

## Operational Modes

The script dynamically adapts its behavior based on the node's role:

- **single**: Operates independently if `VIRTUAL_IPADDRESS` is empty or commented out. It performs health checks and manages routes locally.
- **master**: Static Master role. The node performs local health checks, manages its own routes, and provides the gateway list to others via `VIRTUAL_PORT`. If `VIRTUAL_IPADDRESS` is lost, it stops the delivery service.
- **master-advisor**: Advisor mode. Operates like **master** by providing the gateway list to the cluster, but does NOT apply any routing changes to its own local routing table.
- **slave**: Static Slave role. The node strictly fetches routing data from the **master** via `VIRTUAL_PORT`. If `VIRTUAL_IPADDRESS` appears on this host, it automatically switches to **single** mode for local management.
- **slave-survivor**: Hybrid Slave role. Acts as a **slave** while the **master** is reachable. If the **master** fails, it automatically activates local health checks (like **single** mode) to maintain connectivity until the **master** returns.
- **cluster**: Dynamic HA mode. The node automatically switches between **master** and **slave**:
  - Acts as **master** (provider) when `VIRTUAL_IPADDRESS` is found locally.
  - Acts as **slave** (receiver) when `VIRTUAL_IPADDRESS` is missing.
***NOTE***: In **slave** state, it operates as a survivor, performing local health checks if the current **master** is unreachable.

## Configuration (keepalived-gateway.conf)

| Parameter          | Description                                         | Example Value
|--------------------|-----------------------------------------------------|---------------|
| INTERFACE          | Default network interface for gateways.             | eth0
| METRIC             | Global default route metric.                        | 10 (default 0)
| GATEWAYS           | List of gateways in [IFACE=]IP[=METRIC] format.     | 192.168.1.2 2001:db8::1=50 eth1=192.168.3.2=100
| CHECK_INTERVAL     | Interval between health checks.                     | 30s
| PING_HOST          | Host (IP/DNS) for availability monitoring.          | dns.google
| SPEEDTEST          | Enable speed testing via gateways (yes/no).         | no
| SPEEDTEST_HOST     | Host (IP/DNS) for speedtest checks through gateways.| nbg1-speed.hetzner.com
| SPEEDTEST_SCOPE    | Remote file size used for throughput testing.       | 100MB.bin
| ROLE               | Operational mode (single, master, cluster, etc.).   | cluster
| VIRTUAL_IPADDRESS  | VIP (CIDR) used to determine Master/Slave role.     | 192.168.1.1/24
| VIRTUALPORT        | TCP port for gateway data distribution.             | 8888

## Dual-Stack Support

The script is fully IPv4/IPv6 aware. It independently monitors health for both families:

- The gateway's address family determines the stack used for `PING_HOST` and `SPEEDTEST_HOST` checks.
- Routing tables for IPv4 and IPv6 are managed separately, ensuring that a failure in one stack does not affect the other.

## Integration with Keepalived

The script relies on a standard Keepalived VRRP instance configuration.

### Example `/etc/keepalived/keepalived.conf` (Node A)

```conf
vrrp_instance VI_1 {
    state MASTER
    interface eth0          # Interface for VRRP packet exchange
    virtual_router_id 51
    priority 100            # Higher priority
    advert_int 1

    virtual_ipaddress {
        192.168.1.1/24      # This address must match VIRTUAL_IPADDRESS in keepalived-gateway.conf
    }
}
```

### Example `/etc/keepalived/keepalived.conf` (Node B)

```conf
vrrp_instance VI_1 {
    state BACKUP
    interface eth0
    virtual_router_id 51
    priority 90             # Lower priority
    advert_int 1

    virtual_ipaddress {
        192.168.1.1/24
    }
}
```

### How It Works:

1. **Failover**: If Node A fails, Keepalived on Node B assigns the `VIRTUAL_IPADDRESS` (192.168.1.1) to itself.

2. **Detection**: During the next check, the `keepalived-gateway.sh` script on Node B detects the `VIRTUAL_IPADDRESS` via the `is_vrrp_master` function.

3. **Promotion**: Node B automatically switches from **slave** to **master** mode, starts the synchronization server, and begins testing gateways independently.

4. **Recovery**: When Node A returns, the `VIRTUAL_IPADDRESS` moves back to it. Node B detects the loss of the `VIRTUAL_IPADDRESS` and immediately reverts to **slave** mode, stopping the server and switching back to receiving data over the network.

## Troubleshooting

1. ### View Service Logs

   ```bash
   sudo journalctl -u keepalived-gateway -f
   ```

2. ### Manual Sync Check (from Slave)

   Verify if the Master is serving data correctly:

   Using `wget`:

   ```bash
   wget -q -O - http://<VIRTUAL_IPADDRESS>:8888/gateways.state
   ```

   Using `nc` (Netcat):

   ```bash
   printf "GET /gateways.state HTTP/1.0\r\n\r\n" | nc <VIRTUAL_IPADDRESS> 8888
   ```

3. ### Verify Server Status (on Master)

   Check if the sync server process is active:

   ```bash
   ps | grep '\(telnetd\|uhttpd\)'
   ```

   Check if the port is listening:

   ```bash
   PORT="$(printf "%04X" 8888)"
   cat /proc/net/tcp /proc/net/tcp6 | grep ":$PORT"
   ```

4. ### Inspect Current State

   Check the gateway list prepared for synchronization:

   ```bash
   cat /tmp/keepalived-gateway/gateways.state
   ```

   Example output:

   ```
   eth0=192.168.1.2 eth0=2001:db8::1=50 eth1=192.168.3.2=100
   ```
