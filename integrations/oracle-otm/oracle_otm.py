#!/usr/bin/env python3
"""
Oracle Transportation Management (OTM) to Veza OAA Integration Script

Extracts user and role data from OTM tables (GL_USER, USER_ROLE_ACR_ROLE)
stored in the Smurfit Westrock Enterprise Data Lake (EDL) via AWS Athena ODBC,
and pushes User → Role mappings to Veza as a Custom Application.
"""

import argparse
import logging
import os
import sys

from dotenv import load_dotenv
from oaaclient.client import OAAClient, OAAClientError
from oaaclient.templates import CustomApplication, OAAPermission, OAAPropertyType

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------
log = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------
def load_config(args):
    """Load configuration with precedence: CLI arg → env var → .env file."""
    if args.env_file and os.path.exists(args.env_file):
        load_dotenv(args.env_file, override=True)

    cfg = {
        # Veza
        "veza_url": args.veza_url or os.getenv("VEZA_URL"),
        "veza_api_key": args.veza_api_key or os.getenv("VEZA_API_KEY"),
        # OAA
        "provider_name": args.provider_name or os.getenv("PROVIDER_NAME", "Oracle OTM"),
        "datasource_name": args.datasource_name or os.getenv("DATASOURCE_NAME", "Oracle OTM"),
        # Athena ODBC
        "odbc_dsn": args.odbc_dsn or os.getenv("ATHENA_ODBC_DSN"),
        "athena_region": args.athena_region or os.getenv("ATHENA_REGION", "us-east-1"),
        "athena_s3_output": args.athena_s3_output or os.getenv("ATHENA_S3_OUTPUT"),
        "athena_catalog": args.athena_catalog or os.getenv("ATHENA_CATALOG", "AwsDataCatalog"),
        "athena_database": args.athena_database or os.getenv("ATHENA_DATABASE", "dtl_otm"),
        "athena_workgroup": args.athena_workgroup or os.getenv("ATHENA_WORKGROUP", "datalake"),
        # Azure AD auth for Athena
        "azure_ad_client_id": os.getenv("AZURE_AD_CLIENT_ID"),
        "azure_ad_client_secret": os.getenv("AZURE_AD_CLIENT_SECRET"),
        "azure_ad_tenant_id": os.getenv("AZURE_AD_TENANT_ID"),
        "athena_uid": os.getenv("ATHENA_UID"),
        "athena_pwd": os.getenv("ATHENA_PWD"),
    }
    return cfg


# ---------------------------------------------------------------------------
# Data extraction via Athena ODBC
# ---------------------------------------------------------------------------
def get_odbc_connection(cfg):
    """Create an ODBC connection to AWS Athena via the Simba driver."""
    try:
        import pyodbc
    except ImportError:
        log.error("pyodbc is not installed. Run: pip install pyodbc")
        sys.exit(1)

    # If a DSN name is provided, use it directly
    if cfg["odbc_dsn"]:
        log.info("Connecting via DSN: %s", cfg["odbc_dsn"])
        conn = pyodbc.connect(f"DSN={cfg['odbc_dsn']}", autocommit=True)
        return conn

    # Otherwise build a DSN-less connection string
    parts = [
        "Driver=Simba Amazon Athena ODBC Driver",
        f"AwsRegion={cfg['athena_region']}",
        f"S3OutputLocation={cfg['athena_s3_output']}",
        f"Catalog={cfg['athena_catalog']}",
        f"Schema={cfg['athena_database']}",
        f"Workgroup={cfg['athena_workgroup']}",
        "AuthenticationType=AzureAD",
        f"AzureAdClientId={cfg['azure_ad_client_id']}",
        f"AzureAdClientSecret={cfg['azure_ad_client_secret']}",
        f"AzureAdTenantId={cfg['azure_ad_tenant_id']}",
        f"UID={cfg['athena_uid']}",
        f"PWD={cfg['athena_pwd']}",
        "LakeFormationEnabled=1",
        "UseResultsetStreaming=0",
    ]
    conn_str = ";".join(parts)

    log.info("Connecting to Athena (region=%s, database=%s)",
             cfg["athena_region"], cfg["athena_database"])
    conn = pyodbc.connect(conn_str, autocommit=True)
    return conn


def fetch_users(conn, database):
    """Fetch user records from GL_USER."""
    query = f"""
        SELECT
            user_gid,
            user_xid,
            user_role_gid,
            domain_name,
            first_name,
            last_name,
            middle_name,
            email_address,
            is_active,
            is_locked_out,
            last_login_date,
            password_last_changed_date,
            insert_date,
            update_date
        FROM {database}.gl_user
    """
    log.info("Querying GL_USER from %s ...", database)
    cursor = conn.cursor()
    cursor.execute(query)

    columns = [desc[0] for desc in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    log.info("Retrieved %d user(s) from GL_USER", len(rows))
    return rows


def fetch_user_role_mappings(conn, database):
    """Fetch user-role to access-control-role mappings from USER_ROLE_ACR_ROLE."""
    query = f"""
        SELECT
            user_role_gid,
            user_role_xid,
            acr_role_gid,
            acr_role_xid,
            domain_name
        FROM {database}.user_role_acr_role
    """
    log.info("Querying USER_ROLE_ACR_ROLE from %s ...", database)
    cursor = conn.cursor()
    cursor.execute(query)

    columns = [desc[0] for desc in cursor.description]
    rows = [dict(zip(columns, row)) for row in cursor.fetchall()]
    log.info("Retrieved %d role mapping(s) from USER_ROLE_ACR_ROLE", len(rows))
    return rows


# ---------------------------------------------------------------------------
# OAA payload assembly
# ---------------------------------------------------------------------------
def build_oaa_payload(users, role_mappings, cfg):
    """Build the Veza CustomApplication from OTM user and role data."""
    app = CustomApplication(
        name=cfg["datasource_name"],
        application_type=cfg["provider_name"],
    )

    # -- Define a placeholder permission (no real permissions modeled yet) --
    app.add_custom_permission("assigned", [OAAPermission.NonData])

    # -- Custom user properties --
    app.property_definitions.define_local_user_property("domain_name", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("user_xid", OAAPropertyType.STRING)
    app.property_definitions.define_local_user_property("is_locked_out", OAAPropertyType.BOOLEAN)
    app.property_definitions.define_local_user_property("last_login_date", OAAPropertyType.TIMESTAMP)
    app.property_definitions.define_local_user_property(
        "password_last_changed_date", OAAPropertyType.TIMESTAMP
    )
    app.property_definitions.define_local_user_property("insert_date", OAAPropertyType.TIMESTAMP)
    app.property_definitions.define_local_user_property("update_date", OAAPropertyType.TIMESTAMP)

    # -- Custom role properties --
    app.property_definitions.define_local_role_property("domain_name", OAAPropertyType.STRING)

    # -- Build a lookup: user_role_gid → list of acr_role_gids --
    role_gid_lookup = {}  # user_role_gid → [acr_role_gid, ...]
    all_acr_roles = {}    # acr_role_gid → {metadata}

    for mapping in role_mappings:
        ur_gid = mapping.get("user_role_gid", "")
        acr_gid = mapping.get("acr_role_gid", "")
        if not ur_gid or not acr_gid:
            continue
        role_gid_lookup.setdefault(ur_gid, []).append(acr_gid)
        if acr_gid not in all_acr_roles:
            all_acr_roles[acr_gid] = {
                "acr_role_xid": mapping.get("acr_role_xid", ""),
                "domain_name": mapping.get("domain_name", ""),
            }

    # -- Create local roles for each unique ACR role --
    for acr_gid, meta in all_acr_roles.items():
        role = app.add_local_role(acr_gid, unique_id=acr_gid, permissions=["assigned"])
        if meta.get("domain_name"):
            role.set_property("domain_name", meta["domain_name"])

    log.info("Created %d local role(s) from ACR roles", len(all_acr_roles))

    # -- Create local users --
    users_created = 0
    users_with_roles = 0

    for user in users:
        user_gid = user.get("user_gid", "")
        if not user_gid:
            continue

        first_name = user.get("first_name") or ""
        last_name = user.get("last_name") or ""
        display_name = f"{first_name} {last_name}".strip() or user_gid

        email = user.get("email_address") or ""
        identities = [email] if email else []

        is_active_raw = str(user.get("is_active", "")).upper()
        is_active = is_active_raw == "Y"

        local_user = app.add_local_user(
            name=display_name,
            unique_id=user_gid,
            identities=identities,
        )
        local_user.is_active = is_active

        # Set custom properties
        if user.get("domain_name"):
            local_user.set_property("domain_name", user["domain_name"])
        if user.get("user_xid"):
            local_user.set_property("user_xid", user["user_xid"])

        is_locked_raw = str(user.get("is_locked_out", "")).upper()
        local_user.set_property("is_locked_out", is_locked_raw == "Y")

        for ts_field in ("last_login_date", "password_last_changed_date", "insert_date", "update_date"):
            val = user.get(ts_field)
            if val is not None:
                local_user.set_property(ts_field, str(val))

        # Resolve user's role assignments via USER_ROLE_ACR_ROLE
        user_role_gid = user.get("user_role_gid")
        if user_role_gid and user_role_gid in role_gid_lookup:
            for acr_gid in role_gid_lookup[user_role_gid]:
                local_user.add_role(acr_gid, apply_to_application=True)
            users_with_roles += 1

        users_created += 1

    log.info(
        "Created %d local user(s) (%d with role assignments)",
        users_created,
        users_with_roles,
    )
    return app


# ---------------------------------------------------------------------------
# Push to Veza
# ---------------------------------------------------------------------------
def push_to_veza(cfg, app, dry_run=False):
    """Push the CustomApplication payload to Veza."""
    if dry_run:
        log.info("[DRY RUN] Payload built successfully — skipping push to Veza")
        return

    veza_con = OAAClient(url=cfg["veza_url"], api_key=cfg["veza_api_key"])

    try:
        provider = veza_con.get_provider(cfg["provider_name"])
        if not provider:
            log.info("Creating new provider '%s'", cfg["provider_name"])
            veza_con.create_provider(cfg["provider_name"], "application")

        response = veza_con.push_application(
            provider_name=cfg["provider_name"],
            data_source_name=cfg["datasource_name"],
            application_object=app,
            save_json=False,
        )

        if response.get("warnings"):
            for w in response["warnings"]:
                log.warning("Veza warning: %s", w)

        log.info("Successfully pushed to Veza (datasource: %s)", cfg["datasource_name"])

    except OAAClientError as e:
        log.error("Veza push failed: %s — %s (HTTP %s)", e.error, e.message, e.status_code)
        if hasattr(e, "details"):
            for d in e.details:
                log.error("  Detail: %s", d)
        sys.exit(1)


# ---------------------------------------------------------------------------
# CLI
# ---------------------------------------------------------------------------
def parse_args():
    parser = argparse.ArgumentParser(
        description="Oracle OTM → Veza OAA Integration",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  # Dry-run (build payload, skip push)
  python3 oracle_otm.py --env-file .env --dry-run

  # Full push with explicit arguments
  python3 oracle_otm.py --env-file .env --provider-name "Oracle OTM" \\
      --athena-database dtl_otm

  # Using a pre-configured ODBC DSN
  python3 oracle_otm.py --env-file .env --odbc-dsn edl-datalake
        """,
    )
    parser.add_argument("--env-file", default=".env", help="Path to .env file (default: .env)")
    parser.add_argument("--veza-url", help="Veza instance URL (or VEZA_URL env var)")
    parser.add_argument("--veza-api-key", help="Veza API key (or VEZA_API_KEY env var)")
    parser.add_argument("--provider-name", help="Veza provider name (default: Oracle OTM)")
    parser.add_argument("--datasource-name", help="Veza datasource name (default: Oracle OTM)")
    parser.add_argument("--odbc-dsn", help="ODBC DSN name (e.g. edl-datalake)")
    parser.add_argument("--athena-region", help="AWS region (default: us-east-1)")
    parser.add_argument("--athena-s3-output", help="S3 output location for Athena results")
    parser.add_argument("--athena-catalog", help="Athena catalog (default: AwsDataCatalog)")
    parser.add_argument("--athena-database", help="Athena database containing OTM tables (default: dtl_otm)")
    parser.add_argument("--athena-workgroup", help="Athena workgroup (default: datalake)")
    parser.add_argument("--dry-run", action="store_true", help="Build payload but skip Veza push")
    parser.add_argument(
        "--log-level",
        choices=["DEBUG", "INFO", "WARNING", "ERROR"],
        default="INFO",
        help="Logging level (default: INFO)",
    )
    return parser.parse_args()


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
def main():
    args = parse_args()

    logging.basicConfig(
        level=getattr(logging, args.log_level),
        format="%(asctime)s [%(levelname)s] %(name)s — %(message)s",
        datefmt="%Y-%m-%d %H:%M:%S",
    )

    print("=" * 60)
    print("Oracle OTM → Veza OAA Integration")
    print("=" * 60)

    # 1. Load configuration
    cfg = load_config(args)

    if not cfg["veza_url"] or not cfg["veza_api_key"]:
        log.error("VEZA_URL and VEZA_API_KEY are required (set via CLI, env var, or .env)")
        sys.exit(1)

    if not cfg["odbc_dsn"] and not cfg["athena_s3_output"]:
        log.error("Either --odbc-dsn or ATHENA_S3_OUTPUT (+ Azure AD credentials) must be set")
        sys.exit(1)

    # 2. Connect to Athena
    conn = get_odbc_connection(cfg)
    log.info("Connected to Athena successfully")

    try:
        # 3. Extract data
        database = cfg["athena_database"]
        users = fetch_users(conn, database)
        role_mappings = fetch_user_role_mappings(conn, database)

        if not users:
            log.warning("No users found in GL_USER — nothing to push")
            sys.exit(0)

        # 4. Build OAA payload
        app = build_oaa_payload(users, role_mappings, cfg)

        # 5. Push to Veza
        push_to_veza(cfg, app, dry_run=args.dry_run)

    finally:
        conn.close()
        log.info("Athena connection closed")

    print("=" * 60)
    print("Integration completed successfully")
    print("=" * 60)


if __name__ == "__main__":
    main()
