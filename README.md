# Atlassian Data Center - Docker Compose

A Docker Compose deployment of Atlassian Data Center applications with PostgreSQL and HAProxy.

## Architecture

| Service | Nodes | Description |
|---|---|---|
| Jira Software + JSM | 2 | Jira and Jira Service Management |
| Confluence | 2 | Confluence Data Center |
| Bitbucket | 2 | Bitbucket Data Center |
| PostgreSQL | 1 | Separate databases and users for each application |
| HAProxy | 1 | HTTP load balancing and session persistence |

The secondary application nodes use the `cluster` Compose profile, allowing the stack to be initialized with one node per application.

**Note:** This deployment does not provide complete high availability. PostgreSQL, HAProxy, and shared storage remain potential single points of failure.

## Directory structure

```text
atlassian/
├── compose.yml
├── .env.example
├── .env
├── .gitignore
├── README.md
└── data/
    ├── haproxy/
    │   └── haproxy.cfg
    ├── postgres/
    │   └── .gitkeep
    ├── postgres-init/
    │   └── 01-create-databases.sh
    ├── jira/
    │   ├── node1/
    │   ├── node2/
    │   └── shared/
    ├── confluence/
    │   ├── node1/
    │   ├── node2/
    │   └── shared/
    └── bitbucket/
        ├── node1/
        ├── node2/
        └── shared/
```

Runtime application data, PostgreSQL data, and secrets are excluded from Git. The `.gitkeep` files preserve empty directories.

## Requirements

- Linux host with Docker Engine and Docker Compose v2 (or equivalent such as Podman)
- Docker networking with an available bridge subnet
- Sufficient CPU, RAM, and storage for six Atlassian application nodes
- Compatible Atlassian Data Center licenses
- Compatible PostgreSQL version
- Persistent local storage and a shared home for each application
- External HTTPS reverse proxy or TLS termination

The stack is designed for rootless Docker, although volume permissions must still be configured correctly.

**Important:** The supplied Compose configuration is a starting point. Verify cluster-discovery settings, database compatibility, HAProxy health checks, and application licensing for the selected Atlassian releases.

---

## 1. Initial configuration

Clone the repository:

```bash
git clone https://github.com/notmayo/atlassian-datacenter.git /opt/docker/atlassian
cd /opt/docker/atlassian
```

Create the environment file:

```bash
cp .env.example .env
chmod 600 .env
```

Edit `.env` and configure:

### Application versions

```dotenv
POSTGRES_VERSION=17
HAPROXY_VERSION=3.4-alpine

JIRA_VERSION=11.3
CONFLUENCE_VERSION=11.0
BITBUCKET_VERSION=10.5.1
```

Pin specific supported image versions. Verify the tags exist and each release supports the selected PostgreSQL version before starting.

### Public domains

```dotenv
JIRA_DOMAIN=jira.example.com
CONFLUENCE_DOMAIN=confluence.example.com
BITBUCKET_DOMAIN=bitbucket.example.com
```

These must match the hostnames configured in HAProxy and the external reverse proxy.

### Database credentials

Each application has a separate PostgreSQL database and user:

```dotenv
POSTGRES_USER=postgres
POSTGRES_PASSWORD=

JIRA_DB=jira
JIRA_DB_USER=jira
JIRA_DB_PASSWORD=

CONFLUENCE_DB=confluence
CONFLUENCE_DB_USER=confluence
CONFLUENCE_DB_PASSWORD=

BITBUCKET_DB=bitbucket
BITBUCKET_DB_USER=bitbucket
BITBUCKET_DB_PASSWORD=
```

Generate unique passwords:

```bash
openssl rand -hex 24
```

Generate a different password for each database user and the PostgreSQL administrator.

Also configure `BITBUCKET_CLUSTER_PASSWORD` and other cluster-related variables.

Do not commit `.env` to Git.

## 2. Networking

### Docker subnet

The Compose file uses a dedicated bridge network.

Example:

```yaml
networks:
  atlassian:
    driver: "bridge"
    ipam:
      config:
        - subnet: "10.50.50.0/24"
```

Before deployment, ensure the subnet does not overlap other Docker, LAN, VPN, or routed networks.

List existing Docker subnets:

```bash
docker network ls -q | xargs -r docker network inspect \
  --format '{{.Name}}: {{range .IPAM.Config}}{{.Subnet}} {{end}}'
```

Inspect host routes:

```bash
ip -4 route
```

If changing the subnet, update any static container addresses and cluster peer addresses.

### Published ports

| Port | Service | Purpose |
|---|---|---|
| 8088/TCP | HAProxy | HTTP upstream for external reverse proxy |
| 7999/TCP | Bitbucket SSH | Git over SSH, if enabled |

Jira, Confluence, Bitbucket HTTP, and PostgreSQL do not require host port publication.

### External Caddy reverse proxy

Example Caddyfile configuration:

```caddyfile
jira.example.com {
    reverse_proxy 10.10.40.11:8088
}

confluence.example.com {
    reverse_proxy 10.10.40.11:8088
}

bitbucket.example.com {
    reverse_proxy 10.10.40.11:8088
}
```

Replace `10.10.40.11` with the IP address of the Docker host running HAProxy.

HAProxy must listen on an address accessible from the Caddy host, rather than being published exclusively to `127.0.0.1`.

For example:

```yaml
ports:
  - "10.10.40.11:${HAPROXY_HTTP_PORT}:8080"
```

HAProxy uses the HTTP `Host` header to route traffic to the correct application.

Bitbucket SSH requires separate TCP forwarding or load balancing; normal HTTP reverse proxy rules do not handle SSH.

---

## 3. Filesystem permissions

Protect the environment file:

```bash
chmod 600 .env
```

Make the database initialization script executable:

```bash
chmod 755 data/postgres-init/01-create-databases.sh
```

Set the HAProxy configuration readable:

```bash
chmod 644 data/haproxy/haproxy.cfg
```

### Persistent storage ownership

Atlassian containers and PostgreSQL may use different UIDs/GIDs.

Before startup, inspect the effective user IDs of the selected container images and configure the bind-mount ownership accordingly.

For rootless Docker, account for the container UID/GID mapping to host IDs.

**Do not recursively use `chmod 777` or assume one UID works for every service.**

Each Atlassian node needs write access to its local application home. Both nodes of the same application require appropriate access to that application's shared home.

The shared directories in this single-host Compose example are bind mounts, not network storage. A multi-host cluster requires actual shared storage accessible to every node.

---

## 4. First-time startup

**Do not start all six application nodes simultaneously during initial setup.**

### Step 1 - Validate Compose

```bash
docker compose config --quiet
```

This validates Compose parsing and variable substitution. It does not verify application compatibility.

### Step 2 - Initialize PostgreSQL

```bash
docker compose up -d postgres
```

Monitor startup:

```bash
docker compose logs -f postgres
```

The script at:

```text
data/postgres-init/01-create-databases.sh
```

creates the separate Jira, Confluence, and Bitbucket databases and roles.

**Important:** PostgreSQL initialization scripts only run when its database data directory is empty.

Changing credentials in `.env` after the database has been initialized does not automatically update existing PostgreSQL roles.

Never delete an existing PostgreSQL data directory to force initialization unless the data is intentionally being discarded.

### Step 3 - Verify databases

```bash
docker compose exec postgres \
  psql -U postgres -c '\l'
```

Expected databases:

- `jira`
- `confluence`
- `bitbucket`

### Step 4 - Start primary application nodes

```bash
docker compose up -d jira-1 confluence-1 bitbucket-1
```

Start HAProxy:

```bash
docker compose up -d haproxy
```

Monitor the containers:

```bash
docker compose ps
docker compose logs -f jira-1 confluence-1 bitbucket-1
```

The secondary nodes remain disabled because they belong to the `cluster` profile.

### Step 5 - Complete Atlassian setup

Open the configured HTTPS application URLs:

- https://jira.example.com
- https://confluence.example.com
- https://bitbucket.example.com

Complete the initial setup wizard for each application.

Configure licensing, administrator accounts, database connections, and application settings as required.

Jira Service Management operates within Jira. It does not require a separate PostgreSQL database or additional Jira nodes.

### Step 6 - Validate application health

Check routing through HAProxy:

```bash
for app in jira confluence bitbucket; do
  echo "=== $app ==="
  curl -sSI \
    -H "Host: ${app}.example.com" \
    http://10.10.40.11:8088/ |
    grep -iE '^(HTTP/|location:)'
done
```

A `200` or expected setup/login redirect typically indicates successful HTTP routing.

An HAProxy `503` may indicate a failed health check, an unavailable backend, or incorrect routing.

Verify each application works independently before enabling its second node.

---

## 5. Enable Data Center clustering

After successfully initializing the primary application nodes, verify the clustering configuration for each application.

Check:

- Data Center licensing
- Unique node identifiers
- Database connectivity
- Shared home accessibility
- Cluster peer discovery
- Internal cluster communication
- HAProxy backend health checks

Start the secondary nodes:

```bash
docker compose --profile cluster up -d
```

Monitor their startup:

```bash
docker compose logs -f jira-2 confluence-2 bitbucket-2
```

Confirm that each application's administration interface reports both nodes as healthy cluster members.

**Do not assume that two running containers automatically form a valid Data Center cluster.**

---

## 6. Normal startup and shutdown

After initial configuration and successful clustering:

### Start the complete stack

```bash
docker compose --profile cluster up -d
```

### Start only primary nodes

```bash
docker compose up -d
```

This command targets services without the `cluster` profile. If secondary containers are already running, it does not necessarily stop them.

### Stop the entire stack

```bash
docker compose --profile cluster stop
```

### Restart an individual service

```bash
docker compose restart jira-1
```

### View running services

```bash
docker compose --profile cluster ps
```

### View logs

```bash
docker compose logs -f --tail=100
```

### Recreate a service after changing Compose configuration

```bash
docker compose up -d --force-recreate jira-1
```

`docker compose restart` does not apply modified Compose environment variables or service configuration. Recreate the affected service when necessary.

---

## 7. HAProxy configuration

The load balancer configuration is stored at:

```text
data/haproxy/haproxy.cfg
```

HAProxy handles:

- Hostname-based routing
- Application load balancing
- Session persistence
- Backend health checks
- Dynamic Docker DNS resolution

Docker's embedded DNS is available within Docker networks at `127.0.0.11`.

Dynamic name resolution is useful when secondary application nodes are not yet started.

Example backend server:

```haproxy
server jira1 jira-1:8080 check cookie j1 resolvers docker init-addr none
```

### Validate HAProxy configuration

```bash
docker compose run --rm --no-deps haproxy \
  haproxy -c -f /usr/local/etc/haproxy/haproxy.cfg
```

Apply configuration changes:

```bash
docker compose restart haproxy
```

**Health checks:** Generic TCP connectivity or accepting HTTP 2xx/3xx responses is useful during bootstrap, but production deployments should use suitable application health endpoints and readiness criteria.

---

## 8. Backups and persistence

The following directories contain persistent application data:

```text
data/postgres/
data/jira/
data/confluence/
data/bitbucket/
```

These are intentionally excluded from Git.

Back up:

1. All three PostgreSQL databases.
2. Each application's local and shared home data as required by Atlassian's backup procedures.
3. Application configuration and secrets, using secure storage.

Ensure database and filesystem backups are coordinated for application consistency.

**Git is not a backup system for application databases or shared homes.**

Before upgrades, back up the databases and application data and verify that a restore is possible.

---

## 9. Updating applications

1. Review the Atlassian release notes and supported-platform matrix.
2. Verify PostgreSQL and Java compatibility.
3. Back up databases and application homes.
4. Follow Atlassian's supported Data Center rolling-upgrade procedure where available.
5. Change the appropriate version in `.env`.
6. Pull the new image:

```bash
docker compose pull jira-1
```

7. Recreate the node when appropriate:

```bash
docker compose up -d jira-1
```

8. Verify application and cluster health before upgrading the next node.

Do not assume that arbitrary version changes support rolling upgrades. Some upgrades require downtime, schema migrations, or specific intermediate versions.

---

## 10. Git repository management

Track:

```text
compose.yml
.env.example
.gitignore
README.md
data/haproxy/haproxy.cfg
data/postgres-init/01-create-databases.sh
```

Also track `.gitkeep` placeholders for empty runtime directories.

Do not track:

- `.env`
- Database files
- Jira/Confluence/Bitbucket application homes
- Database backups
- TLS private keys
- Runtime secrets

Verify before committing:

```bash
git add .
git status --short
```

Check ignored files:

```bash
git status --ignored --short
```

If credentials or application data were previously committed, removing them from the current Git index does not remove them from Git history. Rotate exposed credentials and clean the repository history as appropriate.

---

## Troubleshooting

### Docker network pool overlaps

The configured subnet overlaps an existing Docker or routed network.

Inspect existing subnets and change the Compose network subnet along with any static node IPs and peer addresses.

### HAProxy fails to resolve a backend

A service might not be started, especially when using the `cluster` profile.

Use Docker DNS resolvers and `init-addr none` in HAProxy to allow missing backends at initialization.

### HAProxy returns 503

Check:

```bash
docker compose logs --tail=100 haproxy
```

Confirm the application's container is running, reachable, and passing the configured health checks.

### All domains redirect to Jira

Verify HAProxy hostname ACLs. Remove any unintended default backend routing to Jira.

### PostgreSQL authentication fails

Confirm database role names and passwords match those in `.env`.

Remember: changing `.env` does not update PostgreSQL credentials after database initialization.

### Permission denied on bind mounts

Inspect the container's effective UID/GID and the corresponding host-side ownership. Rootless Docker UID mappings require special attention.

---

## References

- [Atlassian Data Center Docker images](https://atlassian.github.io/data-center-helm-charts/containers/)
- [Jira Data Center documentation](https://confluence.atlassian.com/enterprise/jira-data-center-documentation-953651037.html)
- [Confluence Data Center documentation](https://confluence.atlassian.com/doc/confluence-data-center-technical-overview-790795847.html)
- [Bitbucket Data Center documentation](https://confluence.atlassian.com/bitbucketserver/)
- [Docker Compose documentation](https://docs.docker.com/compose/)
- [HAProxy documentation](https://docs.haproxy.org/)

## Disclaimer

This repository is a self-managed deployment template and is not an official Atlassian-supported installation method.

Validate application compatibility, clustering behavior, networking, security, and backup procedures before using it in production.
