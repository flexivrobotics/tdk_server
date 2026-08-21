# TDK Server

TDK Server is a high-performance, self-hosted relay server node for flexiv_tdk WAN teleoperation.
It enables secure, low-latency, and reliable communication between user edge devices, and cloud infrastructure across different cities and continents. Users can independently deploy their own cross-region teleoperation applications based on the TDK server.

## Requirements

- Cloud VM (Ubuntu Server 22.04 LTS 64bit) with a **public IPv4 address**
- Open **TCP/UDP 7449** on the cloud security group / firewall
- SSH access to this VM (used both for administration and to **scp** client certificates)

## Quick start

### On the server


```bash
# 1) Clone repo
git clone https://github.com/flexivrobotics/tdk_server.git

# 2) Generate CA + server cert + leader/follower client packages
cd tdk_server
bash scripts/generate_server_client_cert.sh --ip SERVER_PUBLIC_IP

# 3) Install TDK Server package + systemd service
sudo bash scripts/install_tdk_server.sh
```

Re-create everything (new CA, all certs):

```bash
bash scripts/generate_server_client_cert.sh --ip SERVER_PUBLIC_IP --force
```

### On your PC — download client certificates with scp

Certificate packages stay on the server under `generated/packages/`.
Copy them with **scp** (same SSH key/host you already use). No HTTP port
and no extra firewall rule is required.

```bash
# On your LOCAL computer:
mkdir -p ~/tdk-certs && cd ~/tdk-certs

# Replace key path / SERVER_NAME / SERVER_PUBLIC_IP to match your SSH login.
scp -i /path/to/key.pem SERVER_NAME@SERVER_PUBLIC_IP:/path/to/remote/generated/packages/leader.tar.gz .
scp -i /path/to/key.pem SERVER_NAME@SERVER_PUBLIC_IP:/path/to/remote/generated/packages/follower.tar.gz .

tar -xzf leader.tar.gz
tar -xzf follower.tar.gz
# Pass leader/client.conf or follower/client.conf to TDK
```

The generate script prints the exact `scp` lines with the absolute paths for
your deployment.


## What you configure

| Item            | Where                                        |
| --------------- | -------------------------------------------- |
| Public IP       | `generate_server_client_cert.sh --ip`        |
| Client packages | Always `leader.tar.gz` and `follower.tar.gz` |
| Credential file | `client.conf` inside each `.tar.gz`          |

Do not edit internal server config unless instructed by Flexiv support.

## Service commands

```bash
sudo systemctl status tdk-server
sudo systemctl restart tdk-server
tail -f /var/log/tdk-server/tdk-server.log
```


## Security notes

- `generated/ca/ca.key` must never leave this server or be committed to Git.
- Re-running with `--force` invalidates all existing server and client certificates.
- Client `.tar.gz` packages contain private keys; keep your SSH key private and
  only scp to trusted PCs.

## Third-party notices

Open-source license texts for redistributed components:

```text
licenses/THIRD_PARTY_NOTICES.txt
```

After install they are also available at `/usr/share/doc/tdk-server/`.
