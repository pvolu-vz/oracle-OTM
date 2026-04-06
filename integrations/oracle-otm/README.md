# Oracle OTM → Veza OAA Integration

Push Oracle Transportation Management (OTM) user and role data into the Veza Access Graph via the Open Authorization API (OAA).

## Overview

This connector extracts user records from the OTM **GL_USER** table and role assignments from the **USER_ROLE_ACR_ROLE** table — both stored in the Smurfit Westrock Enterprise Data Lake (EDL) on AWS S3, queried via AWS Athena ODBC — and pushes them to Veza as a Custom Application.

### OAA Entity Mapping

| OTM Source | OAA Entity | Key Fields |
|---|---|---|
| `GL_USER` row | **Local User** | `user_gid` (unique ID), `first_name + last_name` (display), `email_address` (identity) |
| `USER_ROLE_ACR_ROLE.acr_role_gid` | **Local Role** | `acr_role_gid` (unique ID / name) |
| `GL_USER.user_role_gid` ↔ `USER_ROLE_ACR_ROLE.user_role_gid` | **Role Assignment** | User → Role(s) via `role_assignments` |

### Data Flow

```
┌──────────────┐     ODBC/SQL      ┌──────────────┐     OAA Push     ┌───────┐
│  AWS Athena   │ ───────────────► │  oracle_otm   │ ──────────────► │  Veza │
│  (EDL / S3)   │  GL_USER +       │    .py         │  JSON payload   │       │
│               │  USER_ROLE_       │               │                 │       │
│               │  ACR_ROLE         │               │                 │       │
└──────────────┘                   └──────────────┘                  └───────┘
```

## How It Works

1. Load configuration from CLI args → environment variables → `.env` file
2. Connect to AWS Athena via the Simba ODBC driver (Azure AD authentication)
3. Query `GL_USER` and `USER_ROLE_ACR_ROLE` from the OTM database in the EDL
4. Build an OAA `CustomApplication` payload:
   - Each GL_USER row becomes a **Local User** (with `email_address` as the IdP identity)
   - Each unique `acr_role_gid` becomes a **Local Role**
   - Users are assigned to roles via their `user_role_gid` link in `USER_ROLE_ACR_ROLE`
5. Push the payload to Veza (or output only in `--dry-run` mode)

## Prerequisites

- **OS**: Linux (RHEL 7+, CentOS 7+, Ubuntu 18.04+)
- **Python**: 3.8+
- **Simba Amazon Athena ODBC Driver**: [Download](https://docs.aws.amazon.com/athena/latest/ug/connect-with-odbc.html)
- **Network**: Access to Smurfit Westrock VPN or facility network (required for EDL)
- **EDL Access**: Approved via ServiceNow General Access Request for the OTM data objects
- **Azure AD Client Secret**: Retrieved from the Data SharePoint site after EDL access provisioning
- **Veza**: Tenant URL and API key with provider-management permissions

## Quick Start

### One-Command Installer (Linux)

```bash
curl -fsSL https://raw.githubusercontent.com/<org>/<repo>/main/integrations/oracle-otm/install_oracle_otm.sh | bash
```

The installer will:
- Install system packages (git, python3, pip, venv)
- Clone the repository to `/opt/oracle-otm-veza/scripts/`
- Create a Python virtual environment and install dependencies
- Prompt for Veza and Athena credentials
- Generate `.env` with `chmod 600`

### Non-Interactive Install

```bash
VEZA_URL=your-company.veza.com \
VEZA_API_KEY=your_key \
ATHENA_S3_OUTPUT=s3://wrk-techdevops-prod-athena-query-results/ops \
ATHENA_DATABASE=dtl_otm \
AZURE_AD_CLIENT_ID=your_client_id \
AZURE_AD_CLIENT_SECRET=your_secret \
AZURE_AD_TENANT_ID=your_tenant_id \
ATHENA_UID=svc-account@westrock.com \
ATHENA_PWD=svc_password \
bash install_oracle_otm.sh --non-interactive
```

## Manual Installation

### RHEL / CentOS / Fedora

```bash
sudo dnf install -y git python3 python3-pip
```

### Ubuntu / Debian

```bash
sudo apt-get update
sudo apt-get install -y git python3 python3-pip python3-venv
```

### Install Simba Athena ODBC Driver

Download from AWS: https://docs.aws.amazon.com/athena/latest/ug/connect-with-odbc.html

```bash
# RHEL/CentOS
sudo rpm -i AmazonAthenaODBC-*.rpm

# Ubuntu/Debian
sudo dpkg -i AmazonAthenaODBC-*.deb
```

### Application Setup

```bash
# Clone repository
git clone https://github.com/<org>/<repo>.git /opt/oracle-otm-veza/scripts
cd /opt/oracle-otm-veza/scripts/integrations/oracle-otm

# Create virtual environment
python3 -m venv venv
source venv/bin/activate
pip install -r requirements.txt

# Configure credentials
cp .env.example .env
chmod 600 .env
# Edit .env with your Veza and Athena credentials
```

## Usage

### CLI Arguments

| Argument | Required | Default | Description |
|---|---|---|---|
| `--env-file` | No | `.env` | Path to environment file |
| `--veza-url` | Yes¹ | — | Veza instance URL |
| `--veza-api-key` | Yes¹ | — | Veza API key |
| `--provider-name` | No | `Oracle OTM` | Provider name in Veza UI |
| `--datasource-name` | No | `Oracle OTM` | Datasource name in Veza UI |
| `--odbc-dsn` | No² | — | ODBC DSN name (e.g. `edl-datalake`) |
| `--athena-region` | No | `us-east-1` | AWS region |
| `--athena-s3-output` | Yes² | — | S3 location for Athena query results |
| `--athena-catalog` | No | `AwsDataCatalog` | Athena catalog |
| `--athena-database` | No | `dtl_otm` | Athena database containing OTM tables |
| `--athena-workgroup` | No | `datalake` | Athena workgroup |
| `--dry-run` | No | `false` | Build payload but skip Veza push |
| `--log-level` | No | `INFO` | Logging level (DEBUG/INFO/WARNING/ERROR) |

¹ Can also be set via `VEZA_URL` / `VEZA_API_KEY` environment variables.
² Either `--odbc-dsn` or `--athena-s3-output` (+ Azure AD env vars) is required.

### Examples

```bash
# Dry-run with .env file
python3 oracle_otm.py --env-file .env --dry-run

# Full push with explicit database
python3 oracle_otm.py --env-file .env --athena-database dtl_otm

# Using a pre-configured ODBC DSN
python3 oracle_otm.py --env-file .env --odbc-dsn edl-datalake

# Debug logging
python3 oracle_otm.py --env-file .env --log-level DEBUG --dry-run
```

## Deployment on Linux

### Service Account

```bash
sudo useradd -r -s /bin/bash -m -d /opt/oracle-otm-veza oracle-otm-veza
sudo chown -R oracle-otm-veza:oracle-otm-veza /opt/oracle-otm-veza
sudo chmod 700 /opt/oracle-otm-veza/scripts
sudo chmod 600 /opt/oracle-otm-veza/scripts/.env
```

### SELinux (RHEL)

```bash
# Check enforcement mode
getenforce

# Restore file contexts after installation
sudo restorecon -Rv /opt/oracle-otm-veza
```

### Cron Scheduling

Create a wrapper script:

```bash
cat > /opt/oracle-otm-veza/scripts/run_oracle_otm.sh << 'EOF'
#!/bin/bash
cd /opt/oracle-otm-veza/scripts
source venv/bin/activate
python3 oracle_otm.py --env-file .env --log-level INFO \
    >> /opt/oracle-otm-veza/logs/oracle_otm_$(date +\%Y\%m\%d).log 2>&1
EOF
chmod +x /opt/oracle-otm-veza/scripts/run_oracle_otm.sh
```

Add cron entry (`/etc/cron.d/oracle-otm-veza`):

```cron
# Run Oracle OTM → Veza sync daily at 06:00 UTC
0 6 * * * oracle-otm-veza /opt/oracle-otm-veza/scripts/run_oracle_otm.sh
```

### Log Rotation

Create `/etc/logrotate.d/oracle-otm-veza`:

```
/opt/oracle-otm-veza/logs/*.log {
    daily
    missingok
    rotate 30
    compress
    delaycompress
    notifempty
    create 0640 oracle-otm-veza oracle-otm-veza
}
```

## Multiple Instances

To sync multiple OTM environments (e.g., production and staging), create separate `.env` files:

```bash
# Production
python3 oracle_otm.py --env-file /opt/oracle-otm-veza/configs/prod.env \
    --datasource-name "Oracle OTM Prod"

# Staging
python3 oracle_otm.py --env-file /opt/oracle-otm-veza/configs/staging.env \
    --datasource-name "Oracle OTM Staging" \
    --athena-database dtl_otm_staging
```

Stagger cron jobs to avoid concurrent load:

```cron
0  6 * * * oracle-otm-veza /opt/oracle-otm-veza/scripts/run_oracle_otm.sh --env-file configs/prod.env
30 6 * * * oracle-otm-veza /opt/oracle-otm-veza/scripts/run_oracle_otm.sh --env-file configs/staging.env
```

## Security Considerations

- **Credentials**: All secrets are read from environment variables or `.env` files — never hardcoded
- **File permissions**: `.env` must be `chmod 600`, scripts directory `chmod 700`
- **Credential rotation**: Azure AD client secret is rotated annually; update `.env` when notified
- **Network**: EDL access requires Smurfit Westrock VPN or facility network
- **Service accounts**: Use dedicated service accounts (request via ServiceNow) instead of personal credentials for automation

## Troubleshooting

| Issue | Solution |
|---|---|
| `pyodbc.Error: ... Data source name not found` | Install the Simba Amazon Athena ODBC driver and configure the DSN, or use DSN-less connection |
| `AADSTS50126: Error validating credentials` | Check username/password in `.env`; reset if recently changed |
| `The security token included in the request is invalid` | Recreate the ODBC DSN or wait 24h for cached tokens to clear |
| `interaction_required: AADSTS50076: ...multi-factor authentication` | Ensure you are connected to Smurfit Westrock VPN or facility network |
| `Insufficient Lake Formation permission(s)` | Verify the service account has been granted access to the OTM data objects via ServiceNow |
| `Unable to execute HTTP request (port 444)` | Set `UseResultsetStreaming=0` in the ODBC connection (already set in this connector) |
| `veza push failed: ... Invalid Argument` | Run with `--dry-run --log-level DEBUG` to inspect the payload; check for UTF-8 or 512-char limit issues |
| `ModuleNotFoundError: No module named 'pyodbc'` | Activate the venv: `source venv/bin/activate` then `pip install pyodbc` |

## Changelog

| Version | Date | Description |
|---|---|---|
| 1.0 | 2026-04-02 | Initial release — Users → Roles mapping from GL_USER + USER_ROLE_ACR_ROLE |
