#!/usr/bin/env bash
# install_oracle_otm.sh — One-command installer for Oracle OTM → Veza OAA integration
# Supports RHEL/CentOS/Fedora (dnf/yum) and Ubuntu/Debian (apt).
set -euo pipefail

SCRIPT_NAME="oracle-otm-installer"
DEFAULT_REPO_URL="https://github.com/your-org/oracle-otm-veza.git"
DEFAULT_BRANCH="main"
DEFAULT_INSTALL_BASE="/opt/oracle-otm-veza"

REPO_URL="${DEFAULT_REPO_URL}"
BRANCH="${DEFAULT_BRANCH}"
INSTALL_BASE="${DEFAULT_INSTALL_BASE}"
NON_INTERACTIVE="false"
OVERWRITE_ENV="false"

APP_DIR=""
LOG_DIR=""
VENV_DIR=""
ENV_FILE=""
INSTALL_LOG=""
RUN_AS_ROOT=""
PKG_MANAGER=""
OS_ID=""
APT_UPDATED="false"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

log()  { echo -e "${BLUE}[INFO]${NC} $*";  [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%F %T')] [INFO] $*" >> "${INSTALL_LOG}"; }
ok()   { echo -e "${GREEN}[OK]${NC} $*";    [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%F %T')] [OK] $*"   >> "${INSTALL_LOG}"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%F %T')] [WARN] $*" >> "${INSTALL_LOG}"; }
err()  { echo -e "${RED}[ERROR]${NC} $*" >&2; [[ -n "${INSTALL_LOG}" ]] && echo "[$(date '+%F %T')] [ERROR] $*" >> "${INSTALL_LOG}"; }

usage() {
    cat <<EOF
Usage: ${SCRIPT_NAME} [options]

Options:
  --repo-url URL         Git repository URL (default: ${DEFAULT_REPO_URL})
  --branch NAME          Git branch to clone/update (default: ${DEFAULT_BRANCH})
  --install-dir PATH     Base install directory (default: ${DEFAULT_INSTALL_BASE})
  --non-interactive      Do not prompt; expects env vars for credentials
  --overwrite-env        Overwrite existing .env file if present
  -h, --help             Show this help

Required env vars in --non-interactive mode:
  VEZA_URL  VEZA_API_KEY
  Plus one of: ATHENA_ODBC_DSN  or  (ATHENA_S3_OUTPUT + AZURE_AD_CLIENT_ID +
               AZURE_AD_CLIENT_SECRET + AZURE_AD_TENANT_ID + ATHENA_UID + ATHENA_PWD)
EOF
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --repo-url)        REPO_URL="$2";        shift 2 ;;
            --branch)          BRANCH="$2";           shift 2 ;;
            --install-dir)     INSTALL_BASE="$2";     shift 2 ;;
            --non-interactive) NON_INTERACTIVE="true"; shift  ;;
            --overwrite-env)   OVERWRITE_ENV="true";   shift  ;;
            -h|--help)         usage; exit 0           ;;
            *)                 err "Unknown option: $1"; usage; exit 1 ;;
        esac
    done
}

configure_paths() {
    APP_DIR="${INSTALL_BASE}/scripts"
    LOG_DIR="${INSTALL_BASE}/logs"
    VENV_DIR="${APP_DIR}/venv"
    ENV_FILE="${APP_DIR}/.env"
    INSTALL_LOG="${LOG_DIR}/install_$(date +%Y%m%d_%H%M%S).log"
}

require_linux() {
    if [[ "$(uname -s)" != "Linux" ]]; then
        err "This installer supports Linux only."
        exit 1
    fi
}

detect_package_manager() {
    if command -v dnf >/dev/null 2>&1; then
        PKG_MANAGER="dnf"
    elif command -v yum >/dev/null 2>&1; then
        PKG_MANAGER="yum"
    elif command -v apt-get >/dev/null 2>&1; then
        PKG_MANAGER="apt"
    else
        err "No supported package manager (dnf/yum/apt) found."
        exit 1
    fi

    if [[ -f /etc/os-release ]]; then
        OS_ID="$(grep '^ID=' /etc/os-release | cut -d'=' -f2 | tr -d '"')"
    else
        OS_ID="unknown"
    fi
    ok "Detected package manager: ${PKG_MANAGER} (distro: ${OS_ID})"
}

ensure_root_command() {
    if [[ "${EUID}" -eq 0 ]]; then
        RUN_AS_ROOT=""
    elif command -v sudo >/dev/null 2>&1; then
        RUN_AS_ROOT="sudo"
    else
        err "Root access required. Run as root or install sudo."
        exit 1
    fi
}

run_root() {
    if [[ -n "${RUN_AS_ROOT}" ]]; then ${RUN_AS_ROOT} "$@"; else "$@"; fi
}

setup_directories() {
    run_root mkdir -p "${APP_DIR}" "${LOG_DIR}"
    run_root chmod 755 "${INSTALL_BASE}" "${APP_DIR}" "${LOG_DIR}"
    run_root touch "${INSTALL_LOG}"
    if [[ "${EUID}" -ne 0 ]]; then
        run_root chown -R "${USER}:${USER}" "${INSTALL_BASE}"
    fi
}

install_system_packages() {
    install_pkg() {
        local pkg="$1"
        case "${PKG_MANAGER}" in
            dnf) run_root dnf install -y "${pkg}" >/dev/null ;;
            yum) run_root yum install -y "${pkg}" >/dev/null ;;
            apt)
                if [[ "${APT_UPDATED}" != "true" ]]; then
                    run_root apt-get update -y >/dev/null
                    APT_UPDATED="true"
                fi
                run_root apt-get install -y "${pkg}" >/dev/null
                ;;
        esac
    }

    command -v git     >/dev/null 2>&1 || { log "Installing git...";     install_pkg "git"; }
    command -v curl    >/dev/null 2>&1 || { log "Installing curl...";    install_pkg "curl"; }
    command -v python3 >/dev/null 2>&1 || { log "Installing python3..."; install_pkg "python3"; }
    python3 -m pip --version >/dev/null 2>&1 || { log "Installing pip..."; install_pkg "python3-pip"; }
    python3 -m venv --help  >/dev/null 2>&1 || {
        log "Installing python3-venv..."
        case "${PKG_MANAGER}" in
            dnf|yum) install_pkg "python3-virtualenv" ;;
            apt)     install_pkg "python3-venv" ;;
        esac
    }
    ok "System packages verified"
}

check_python_version() {
    local version
    version="$(python3 -c 'import sys; print(f"{sys.version_info.major}.{sys.version_info.minor}")')"
    local major="${version%%.*}"
    local minor="${version##*.}"
    if (( major < 3 || (major == 3 && minor < 8) )); then
        err "Python ${version} detected; Python 3.8+ required."
        exit 1
    fi
    ok "Python ${version} is supported"
}

sync_repository() {
    if [[ -d "${APP_DIR}/.git" ]]; then
        log "Updating repository from ${REPO_URL} (${BRANCH})"
        git -C "${APP_DIR}" remote set-url origin "${REPO_URL}" >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" fetch --all --prune             >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" checkout "${BRANCH}"             >> "${INSTALL_LOG}" 2>&1
        git -C "${APP_DIR}" pull --ff-only origin "${BRANCH}" >> "${INSTALL_LOG}" 2>&1
    else
        if [[ -n "$(ls -A "${APP_DIR}" 2>/dev/null)" ]]; then
            warn "${APP_DIR} not empty — removing before clone"
            run_root rm -rf "${APP_DIR}"
            run_root mkdir -p "${APP_DIR}"
            [[ "${EUID}" -ne 0 ]] && run_root chown "${USER}:${USER}" "${APP_DIR}"
        fi
        log "Cloning ${REPO_URL} (${BRANCH}) into ${APP_DIR}"
        git clone --branch "${BRANCH}" --single-branch "${REPO_URL}" "${APP_DIR}" >> "${INSTALL_LOG}" 2>&1
    fi
    chmod +x "${APP_DIR}/oracle_otm.py" 2>/dev/null || true
    ok "Repository synchronized"
}

setup_python_environment() {
    log "Setting up Python virtual environment"
    if [[ ! -d "${VENV_DIR}" ]]; then
        python3 -m venv "${VENV_DIR}"
    fi
    "${VENV_DIR}/bin/python" -m pip install --upgrade pip >> "${INSTALL_LOG}" 2>&1
    "${VENV_DIR}/bin/pip" install -r "${APP_DIR}/requirements.txt" 2>&1 | tee -a "${INSTALL_LOG}"
    ok "Python dependencies installed"
}

# ---------------------------------------------------------------------------
# Prompt helper (visible via /dev/tty when piped from curl)
# ---------------------------------------------------------------------------
prompt_value() {
    local prompt_text="$1" default_value="$2" required="$3" secret="$4"
    local value=""

    while true; do
        if [[ "${secret}" == "true" ]]; then
            if [[ -n "${default_value}" ]]; then
                IFS= read -r -s -p "${prompt_text} [current kept if empty]: " value </dev/tty
            else
                IFS= read -r -s -p "${prompt_text}: " value </dev/tty
            fi
            echo >/dev/tty
        else
            if [[ -n "${default_value}" ]]; then
                IFS= read -r -p "${prompt_text} [${default_value}]: " value </dev/tty
            else
                IFS= read -r -p "${prompt_text}: " value </dev/tty
            fi
        fi

        [[ -z "${value}" && -n "${default_value}" ]] && value="${default_value}"

        if [[ "${required}" == "true" && -z "${value}" ]]; then
            echo -e "${YELLOW}[WARN]${NC} This value is required." >/dev/tty
            continue
        fi

        echo "${value}"
        return 0
    done
}

sanitize_veza_url() {
    local raw="$1"
    raw="${raw#https://}"
    raw="${raw#http://}"
    raw="${raw%/}"
    echo "${raw}"
}

create_env_file() {
    if [[ -f "${ENV_FILE}" && "${OVERWRITE_ENV}" != "true" ]]; then
        warn "${ENV_FILE} already exists. Use --overwrite-env to regenerate."
        return 0
    fi

    local veza_url="" veza_api_key=""
    local athena_dsn="" athena_s3="" athena_db="" athena_wg=""
    local azure_client_id="" azure_client_secret="" azure_tenant_id=""
    local athena_uid="" athena_pwd=""

    if [[ "${NON_INTERACTIVE}" == "true" ]]; then
        veza_url="${VEZA_URL:-}"
        veza_api_key="${VEZA_API_KEY:-}"
        athena_dsn="${ATHENA_ODBC_DSN:-}"
        athena_s3="${ATHENA_S3_OUTPUT:-}"
        athena_db="${ATHENA_DATABASE:-dtl_otm}"
        athena_wg="${ATHENA_WORKGROUP:-datalake}"
        azure_client_id="${AZURE_AD_CLIENT_ID:-}"
        azure_client_secret="${AZURE_AD_CLIENT_SECRET:-}"
        azure_tenant_id="${AZURE_AD_TENANT_ID:-}"
        athena_uid="${ATHENA_UID:-}"
        athena_pwd="${ATHENA_PWD:-}"

        if [[ -z "${veza_url}" || -z "${veza_api_key}" ]]; then
            err "Missing VEZA_URL or VEZA_API_KEY for --non-interactive mode."
            exit 1
        fi
    else
        log "Collecting credentials for .env"
        veza_url="$(prompt_value "Veza URL (e.g. your-company.veza.com)" "" "true" "false")"
        veza_api_key="$(prompt_value "Veza API key" "" "true" "true")"
        athena_dsn="$(prompt_value "ODBC DSN name (leave blank for DSN-less)" "" "false" "false")"

        if [[ -z "${athena_dsn}" ]]; then
            athena_s3="$(prompt_value "Athena S3 output location" "s3://wrk-techdevops-prod-athena-query-results/ops" "true" "false")"
            athena_db="$(prompt_value "Athena database (OTM)" "dtl_otm" "true" "false")"
            athena_wg="$(prompt_value "Athena workgroup" "datalake" "true" "false")"
            azure_client_id="$(prompt_value "Azure AD Client ID" "" "true" "false")"
            azure_client_secret="$(prompt_value "Azure AD Client Secret" "" "true" "true")"
            azure_tenant_id="$(prompt_value "Azure AD Tenant ID" "" "true" "false")"
            athena_uid="$(prompt_value "Athena UID (email@westrock.com or service account)" "" "true" "false")"
            athena_pwd="$(prompt_value "Athena password" "" "true" "true")"
        fi
    fi

    veza_url="$(sanitize_veza_url "${veza_url}")"

    cat > "${ENV_FILE}" <<EOF
# =============================================================
# Oracle OTM → Veza OAA Integration  —  Environment Variables
# =============================================================

# --- Veza Configuration ---
VEZA_URL=${veza_url}
VEZA_API_KEY=${veza_api_key}

# --- OAA Provider Settings (optional overrides) ---
# PROVIDER_NAME=Oracle OTM
# DATASOURCE_NAME=Oracle OTM

# --- Athena ODBC Connection ---
# Option A: Use a pre-configured ODBC DSN name
ATHENA_ODBC_DSN=${athena_dsn}

# Option B: DSN-less connection (all fields required if DSN is blank)
ATHENA_REGION=us-east-1
ATHENA_S3_OUTPUT=${athena_s3}
ATHENA_CATALOG=AwsDataCatalog
ATHENA_DATABASE=${athena_db}
ATHENA_WORKGROUP=${athena_wg}

# --- Azure AD Authentication for Athena ---
AZURE_AD_CLIENT_ID=${azure_client_id}
AZURE_AD_CLIENT_SECRET=${azure_client_secret}
AZURE_AD_TENANT_ID=${azure_tenant_id}
ATHENA_UID=${athena_uid}
ATHENA_PWD=${athena_pwd}
EOF

    chmod 600 "${ENV_FILE}"
    ok ".env created at ${ENV_FILE}"
}

run_post_install_checks() {
    log "Running post-install checks"
    check_python_version

    # Verify key Python imports
    local failed=0
    for pkg in requests dotenv oaaclient pyodbc; do
        if "${VENV_DIR}/bin/python" -c "import ${pkg}" 2>/dev/null; then
            ok "${pkg} importable"
        else
            warn "${pkg} NOT importable — may need system ODBC driver"
            failed=$((failed + 1))
        fi
    done
    [[ ${failed} -gt 0 ]] && warn "Some imports failed. Ensure the Simba Athena ODBC driver is installed."
    ok "Post-install checks completed"
}

print_summary() {
    cat <<EOF

============================================================
  Installation complete
============================================================
Paths:
  Base:      ${INSTALL_BASE}
  Scripts:   ${APP_DIR}
  Venv:      ${VENV_DIR}
  Config:    ${ENV_FILE}
  Logs:      ${LOG_DIR}
  Log file:  ${INSTALL_LOG}

Run the integration:
  ${VENV_DIR}/bin/python ${APP_DIR}/oracle_otm.py --env-file ${ENV_FILE} --dry-run

Prerequisite: Simba Amazon Athena ODBC Driver must be installed.
  https://docs.aws.amazon.com/athena/latest/ug/connect-with-odbc.html
============================================================
EOF
}

main() {
    parse_args "$@"
    require_linux
    detect_package_manager
    ensure_root_command
    configure_paths
    setup_directories

    log "Starting Oracle OTM installer"
    log "Repository: ${REPO_URL} (${BRANCH})"
    log "Install base: ${INSTALL_BASE}"

    install_system_packages
    sync_repository
    setup_python_environment
    create_env_file
    run_post_install_checks
    print_summary
}

main "$@"
