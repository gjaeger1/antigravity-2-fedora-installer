#!/usr/bin/env bash

# Antigravity 2.0 Fedora Installer
# A secure, robust, and native installation script for Fedora.
#
# Usage:
#   ./install.sh [options]
#
# Options:
#   --mode <ide|agent> Choose target application variant.
#   --user             Install to user space (~/.local) without requiring root privileges.
#   --url <url>        Override the default download URL.
#   --dry-run          Run pre-flight checks and download the package but do not write any files.
#   -h, --help         Show help message.

set -euo pipefail

# ANSI color codes for premium terminal output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
BOLD='\033[1m'
NC='\033[0m' # No Color

# Default values
INSTALL_SCOPE="system"
APP_MODE="" # Starts empty to force interaction if not provided
APP_VERSION=""

DRY_RUN=false
TEMP_DIR=""
LEGACY_REPOSITIONED=false
DOWNLOAD_URL=""
AUTO_CONFIRM=false

# Resiliency states
BACKUP_APP_DIR=""
INSTALL_SUCCESSFUL=false

# System-wide installations require selective elevation helper
escalate_cmd() {
    if [[ "$INSTALL_SCOPE" == "system" ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

resolve_release_metadata() {
    local mode="$1"
    local arch="$2"
    local api_url=""
    local version=""
    local exec_id=""
    local download_url=""
    local json_data=""

    echo -e "${YELLOW}Detecting latest version and download URL from release metadata...${NC}" >&2

    # Primary API endpoints based on mode
    if [[ "$mode" == "ide" ]]; then
        api_url="https://antigravity-ide-auto-updater-974169037036.us-central1.run.app/releases"
    elif [[ "$mode" == "agent" ]]; then
        api_url="https://antigravity-hub-auto-updater-974169037036.us-central1.run.app/releases"
    else
        echo -e "${RED}Error: Unsupported mode '$mode' for release metadata resolution.${NC}" >&2
        return 1
    fi

    # Attempt 1: Fetch primary auto-updater API JSON directly
    json_data=$(curl -fsSL --compressed "$api_url" 2>/dev/null || true)

    # Attempt 2: Discover API endpoint dynamically from antigravity.google release JS bundles
    if [[ -z "$json_data" ]]; then
        local js_paths
        js_paths=$(curl -fsSL --compressed "https://antigravity.google/releases" 2>/dev/null | grep -oE "/_astro/[^\"]+\.js" || true)
        for js_path in $js_paths; do
            local js_content
            js_content=$(curl -fsSL --compressed "https://antigravity.google${js_path}" 2>/dev/null || true)
            local fetched_api=""
            if [[ "$mode" == "ide" ]]; then
                fetched_api=$(echo "$js_content" | grep -oE "https://[a-zA-Z0-9_.-]+ide[a-zA-Z0-9_.-]*\.run\.app/releases" | head -n 1 || true)
            else
                fetched_api=$(echo "$js_content" | grep -oE "https://[a-zA-Z0-9_.-]+hub[a-zA-Z0-9_.-]*\.run\.app/releases" | head -n 1 || true)
            fi
            if [[ -n "$fetched_api" ]]; then
                json_data=$(curl -fsSL --compressed "$fetched_api" 2>/dev/null || true)
                [[ -n "$json_data" ]] && break
            fi
        done
    fi

    # Extract latest version and execution_id from JSON response
    if [[ -n "$json_data" ]]; then
        local matched_pair
        matched_pair=$(echo "$json_data" | grep -oE "\"version\":\"[^\"]*\",\"execution_id\":\"[^\"]*\"" | head -n 1 | sed -nE "s/.*\"version\":\"([^\"]*)\".*\"execution_id\":\"([^\"]*)\".*/\1 \2/p" || true)
        if [[ -n "$matched_pair" ]]; then
            version=$(echo "$matched_pair" | awk '{print $1}')
            exec_id=$(echo "$matched_pair" | awk '{print $2}')
            exec_id="${exec_id%/}"
        fi
    fi

    # Attempt 3: Parse fallback attributes from HTML of releases page if API calls failed
    if [[ -z "$version" || -z "$exec_id" ]]; then
        local html_content
        html_content=$(curl -fsSL --compressed "https://antigravity.google/releases" 2>/dev/null || true)
        if [[ -n "$html_content" ]]; then
            local fallback_attr=""
            if [[ "$mode" == "ide" ]]; then
                fallback_attr="data-fallback-ide"
            else
                fallback_attr="data-fallback-antigravity"
            fi
            local matched_pair
            matched_pair=$(echo "$html_content" | grep -oE "${fallback_attr}=\"[^\"]+\"" | sed 's/&quot;/"/g' | grep -oE "\"version\":\"[^\"]*\",\"execution_id\":\"[^\"]*\"" | head -n 1 | sed -nE "s/.*\"version\":\"([^\"]*)\".*\"execution_id\":\"([^\"]*)\".*/\1 \2/p" || true)
            if [[ -n "$matched_pair" ]]; then
                version=$(echo "$matched_pair" | awk '{print $1}')
                exec_id=$(echo "$matched_pair" | awk '{print $2}')
                exec_id="${exec_id%/}"
            fi
        fi
    fi

    # Construct the download URL if version and execution_id were found
    if [[ -n "$version" && -n "$exec_id" ]]; then
        if [[ "$mode" == "ide" ]]; then
            download_url="https://edgedl.me.gvt1.com/edgedl/release2/j0qc3/antigravity/stable/${version}-${exec_id}/${arch}/Antigravity%20IDE.tar.gz"
        else
            download_url="https://storage.googleapis.com/antigravity-public/antigravity-hub/${version}-${exec_id}/${arch}/Antigravity.tar.gz"
        fi
    fi

    if [[ -z "$version" || -z "$download_url" ]]; then
        echo -e "${RED}Error: Failed to resolve release metadata for $mode ($arch).${NC}" >&2
        return 1
    fi

    printf '%s|%s\n' "$version" "$download_url"
}

# Print usage instructions
show_help() {
    cat << EOF
Usage: $(basename "$0") [options]

Options:
  --mode <ide|agent> Choose target application variant.
  --user             Install to user space (~/.local) without requiring root privileges.
  --url <url>        Override the default download URL.
  --dry-run          Perform pre-flight checks and package download only. No files written.
  -y, --yes          Automatic yes to prompts (bypass confirmation).
  -h, --help         Show this help message.
EOF
}

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)
            if [[ -n "${2:-}" && ( "$2" == "ide" || "$2" == "agent" ) ]]; then
                APP_MODE="$2"
                shift 2
            else
                echo -e "${RED}Error: --mode requires a value: 'ide' or 'agent'.${NC}" >&2
                exit 1
            fi
            ;;
        --user)
            INSTALL_SCOPE="user"
            shift
            ;;
        --url)
            if [[ -n "${2:-}" ]]; then
                DOWNLOAD_URL="$2"
                shift 2
            else
                echo -e "${RED}Error: --url requires a value.${NC}" >&2
                exit 1
            fi
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        -y|--yes)
            AUTO_CONFIRM=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            echo -e "${RED}Error: Unknown option '$1'${NC}" >&2
            show_help
            exit 1
            ;;
        esac
done

echo -e "${BLUE}${BOLD}=== Antigravity 2.0 Installer ===${NC}"

# --- INTERACTIVE MENU ---
if [[ -z "$APP_MODE" ]]; then
    if [[ ! -t 0 ]]; then
        echo -e "${RED}Error: Standard input is not a terminal. Please specify --mode <ide|agent>.${NC}" >&2
        exit 1
    fi
    echo -e "\n${BOLD}Select the version you want to install:${NC}"
    echo -e "  ${GREEN}1)${NC} Antigravity 2.0 ${BOLD}IDE${NC} (Development Environment)"
    echo -e "  ${GREEN}2)${NC} Antigravity 2.0 ${BOLD}Agent${NC} (Background Agent / Hub)"
    echo -ne "\nEnter an option [1-2]: "

    read -r OPTION

    case "$OPTION" in
        1)
            APP_MODE="ide"
            ;;
        2)
            APP_MODE="agent"
            ;;
        *)
            echo -e "${RED}Invalid option. Canceling installation.${NC}" >&2
            exit 1
            ;;
    esac
fi

# Pre-flight check: CPU Architecture
ARCH=$(uname -m)
if [[ "$ARCH" != "x86_64" && "$ARCH" != "aarch64" ]]; then
    echo -e "${RED}Error: Antigravity Linux build is strictly x86_64 or aarch64. Detected: ${ARCH}${NC}" >&2
    exit 1
fi

# Dynamic URL Selection based on architecture
IDE_DOWNLOAD_ARCH="linux-x64"
AGENT_DOWNLOAD_ARCH="linux-x64"
if [[ "$ARCH" == "aarch64" ]]; then
    AGENT_DOWNLOAD_ARCH="linux-arm"
    if [[ "$APP_MODE" == "ide" ]]; then
        echo -e "${YELLOW}Warning: Native ARM64 build is not officially supported for the IDE variant.${NC}" >&2
        echo -e "${YELLOW}Defaulting to the standard x86_64 package (requires compatibility layers).${NC}" >&2
    fi
fi

if [[ -z "$DOWNLOAD_URL" ]]; then
    RESOLVED_META=""
    if [[ "$APP_MODE" == "ide" ]]; then
        RESOLVED_META=$(resolve_release_metadata "ide" "$IDE_DOWNLOAD_ARCH") || exit 1
    else
        RESOLVED_META=$(resolve_release_metadata "agent" "$AGENT_DOWNLOAD_ARCH") || exit 1
    fi
    IFS='|' read -r APP_VERSION DOWNLOAD_URL <<< "$RESOLVED_META"
else
    APP_VERSION="dynamic"
fi

if [[ -z "$APP_VERSION" || -z "$DOWNLOAD_URL" ]]; then
    echo -e "${RED}Error: Release version or download URL resolution failed.${NC}" >&2
    exit 1
fi

# Define dynamic variables based on selected mode
if [[ "$APP_MODE" == "ide" ]]; then
    APP_NAME_SHORT="antigravity-ide"
    APP_NAME_PRETTY="Antigravity 2.0 IDE"
    APP_COMMENT="Experience liftoff (v2.0 Standalone IDE)"
    BINARY_NAME="antigravity-ide"
else
    APP_NAME_SHORT="antigravity"
    APP_NAME_PRETTY="Antigravity 2.0 Agent"
    APP_COMMENT="Experience liftoff (v2.0 Agent)"
    BINARY_NAME="antigravity"
fi

echo -e "\n${BLUE}Selected variant: ${BOLD}${APP_NAME_PRETTY}${NC}"
echo -e "${BLUE}Targeting scope: ${BOLD}${INSTALL_SCOPE}${NC}"
echo -e "${BLUE}Resolved version: ${BOLD}${APP_VERSION}${NC}"
echo -e "${BLUE}Resolved download URL: ${BOLD}${DOWNLOAD_URL}${NC}"

# Define paths based on install scope and dynamic name
if [[ "$INSTALL_SCOPE" == "system" ]]; then
    TARGET_PARENT_DIR="/opt"
    TARGET_APP_DIR="/opt/${APP_NAME_SHORT}-Linux"
    TARGET_BIN_PATH="/usr/local/bin/${APP_NAME_SHORT}"
    DESKTOP_ENTRY_DIR="/usr/share/applications"
    DESKTOP_ENTRY_PATH="${DESKTOP_ENTRY_DIR}/${APP_NAME_SHORT}.desktop"
    ICON_LOOKUP_NAME="antigravity" # Force native asset resource name for desktop styling
    ICON_TARGET_DIR="/usr/share/pixmaps"
else
    TARGET_PARENT_DIR="$HOME/.local/share"
    TARGET_APP_DIR="$HOME/.local/share/${APP_NAME_SHORT}-Linux"
    TARGET_BIN_PATH="$HOME/.local/bin/${APP_NAME_SHORT}"
    DESKTOP_ENTRY_DIR="$HOME/.local/share/applications"
    DESKTOP_ENTRY_PATH="${DESKTOP_ENTRY_DIR}/${APP_NAME_SHORT}.desktop"
    ICON_LOOKUP_NAME="antigravity" # Force native asset resource name for desktop styling
    ICON_TARGET_DIR="$HOME/.local/share/pixmaps"
fi

# Detect currently installed version
CURRENT_VERSION="none"
if [[ -f "$TARGET_APP_DIR/version.txt" ]]; then
    CURRENT_VERSION=$(cat "$TARGET_APP_DIR/version.txt" 2>/dev/null || echo "unknown")
elif [[ -d "$TARGET_APP_DIR" || -L "$TARGET_BIN_PATH" || ( "$INSTALL_SCOPE" == "system" && "$APP_NAME_SHORT" == "antigravity" && -d "/opt/Antigravity-x64" ) ]]; then
    # Fallback: if version.txt is missing but the target directory, the symlink,
    # or the legacy /opt/Antigravity-x64 folder exists, we classify it as a legacy pre-version-tracked install.
    CURRENT_VERSION="legacy"
fi

if [[ "$CURRENT_VERSION" != "none" ]]; then
    if [[ "$CURRENT_VERSION" == "legacy" ]]; then
        echo -e "${GREEN}Upgrade Notice: An existing installation was detected. Upgrading ${APP_NAME_PRETTY} to v${APP_VERSION}...${NC}"
    elif [[ "$CURRENT_VERSION" == "$APP_VERSION" ]]; then
        echo -e "${YELLOW}Notice: ${APP_NAME_PRETTY} v${CURRENT_VERSION} is already installed. Reinstalling...${NC}"
    else
        echo -e "${GREEN}Upgrade Notice: Upgrading ${APP_NAME_PRETTY} from v${CURRENT_VERSION} to v${APP_VERSION}...${NC}"
    fi

    # Upgrade/reinstall interactive confirmation prompt
    if [[ "$AUTO_CONFIRM" == "false" && "$DRY_RUN" == "false" ]]; then
        if [[ ! -t 0 ]]; then
            echo -e "${YELLOW}Warning: Non-interactive terminal detected. Proceeding automatically...${NC}"
        else
            echo -ne "\nDo you want to proceed? [Y/n]: "
            read -r CONFIRM
            CONFIRM=$(echo "${CONFIRM:-y}" | tr '[:upper:]' '[:lower:]')
            if [[ "$CONFIRM" != "y" && "$CONFIRM" != "yes" ]]; then
                echo -e "${RED}Installation aborted by user.${NC}"
                exit 0
            fi
        fi
    fi
else
    echo -e "${GREEN}New installation: Installing ${APP_NAME_PRETTY} v${APP_VERSION}...${NC}"
fi

# Pre-flight check: Required utilities
echo -e "${YELLOW}Verifying system utilities...${NC}"
for util in curl tar sed update-desktop-database df awk grep head; do
    if ! command -v "$util" &> /dev/null; then
        echo -e "${RED}Error: Required command '$util' is missing.${NC}" >&2
        exit 1
    fi
done
echo -e "${GREEN}✓ All core utilities verified.${NC}"

# Pre-flight check: Available disk space (POSIX-compliant check)
echo -e "${YELLOW}Verifying available disk space...${NC}"
CHECK_PATH="$TARGET_PARENT_DIR"
while [[ ! -d "$CHECK_PATH" ]]; do
    CHECK_PATH=$(dirname "$CHECK_PATH")
done

AVAILABLE_KB=$(df -Pk "$CHECK_PATH" | tail -1 | awk '{print $4}')
if [[ -n "$AVAILABLE_KB" && "$AVAILABLE_KB" -lt 512000 ]]; then
    echo -e "${RED}Error: Insufficient disk space in target partition ($CHECK_PATH).${NC}" >&2
    echo -e "${RED}Available: $((AVAILABLE_KB / 1024))MB, Required: 500MB headroom.${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Disk space verification passed ($((AVAILABLE_KB / 1024))MB available).${NC}"

# Setup secure cleanup on script exit or interrupt
cleanup() {
    # Perform rollback if installation was interrupted or failed after a backup was created
    if [[ "${INSTALL_SUCCESSFUL}" == "false" && -n "${BACKUP_APP_DIR:-}" && -d "$BACKUP_APP_DIR" ]]; then
        echo -e "\n${RED}Installation interrupted or failed. Rolling back to previous state...${NC}"
        if [[ -d "${TARGET_APP_DIR:-}" ]]; then
            escalate_cmd rm -rf "$TARGET_APP_DIR"
        fi
        escalate_cmd mv "$BACKUP_APP_DIR" "$TARGET_APP_DIR"
        echo -e "${GREEN}✓ Rollback completed successfully.${NC}"
    fi

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        echo -e "${YELLOW}Cleaning up temporary directory: $TEMP_DIR${NC}"
        rm -rf "$TEMP_DIR"
    fi
}
trap cleanup EXIT INT TERM

# Create secure temporary directory for download
TEMP_DIR=$(mktemp -d -t antigravity-install-XXXXXX)
TEMP_ARCHIVE="$TEMP_DIR/Antigravity.tar.gz"

# Fetch/Download the tarball package
echo -e "${YELLOW}Downloading ${APP_NAME_PRETTY} package...${NC}"
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}[DRY RUN] Would download from: $DOWNLOAD_URL${NC}"
fi

# Perform download with retry logic
HTTP_CODE=$(curl -sSL -w "%{http_code}" -o "$TEMP_ARCHIVE" "$DOWNLOAD_URL")
if [[ "$HTTP_CODE" -ne 200 ]]; then
    echo -e "${RED}Error: Download failed with HTTP status code $HTTP_CODE${NC}" >&2
    exit 1
fi
echo -e "${GREEN}✓ Downloaded successfully.${NC}"

# Retrieve application icon (local copy or download fallback)
echo -e "${YELLOW}Retrieving application icon...${NC}"
LOCAL_ICON="$(dirname "$0")/antigravity.png"
if [[ -f "$LOCAL_ICON" ]]; then
    echo -e "${GREEN}✓ Found local icon file.${NC}"
    cp "$LOCAL_ICON" "$TEMP_DIR/antigravity.png"
else
    ICON_URL="https://raw.githubusercontent.com/jssroberto/antigravity-2-fedora-installer/main/antigravity.png"
    if [[ "$DRY_RUN" == "true" ]]; then
        echo -e "${BLUE}[DRY RUN] Would download icon from: $ICON_URL${NC}"
    else
        echo -e "${YELLOW}Downloading icon from mirror...${NC}"
        ICON_HTTP_CODE=$(curl -sSL -w "%{http_code}" -o "$TEMP_DIR/antigravity.png" "$ICON_URL")
        if [[ "$ICON_HTTP_CODE" -ne 200 ]]; then
            echo -e "${RED}Error: Icon download failed with HTTP status code $ICON_HTTP_CODE${NC}" >&2
            exit 1
        fi
        echo -e "${GREEN}✓ Icon downloaded successfully.${NC}"
    fi
fi

# Extract package and install files (Skip if --dry-run)
if [[ "$DRY_RUN" == "true" ]]; then
    echo -e "${BLUE}[DRY RUN] Would extract files and configure launcher paths.${NC}"
    echo -e "${GREEN}✓ Dry-run completed successfully. The environment and download were verified.${NC}"
    exit 0
fi


echo -e "${YELLOW}Extracting and installing binaries...${NC}"

# Safely back up existing installation directory instead of removing it beforehand
if [[ -d "$TARGET_APP_DIR" ]]; then
    BACKUP_APP_DIR="${TARGET_APP_DIR}.bak"
    echo -e "${YELLOW}Backing up existing installation folder to $BACKUP_APP_DIR...${NC}"
    # Remove any old residual backup directory if it exists from a previous crash
    if [[ -d "$BACKUP_APP_DIR" ]]; then
        escalate_cmd rm -rf "$BACKUP_APP_DIR"
    fi
    escalate_cmd mv "$TARGET_APP_DIR" "$BACKUP_APP_DIR"
fi

# Ensure parent directory exists
escalate_cmd mkdir -p "$TARGET_PARENT_DIR"

# Extract archive to a temporary location to detect the internal folder name
EXTRACT_TEMP="$TEMP_DIR/extract_temp"
mkdir -p "$EXTRACT_TEMP"
tar -xzf "$TEMP_ARCHIVE" -C "$EXTRACT_TEMP"

# Locate the extracted directory cleanly without fragile ls parsing
EXTRACTED_DIR_NAME=""
for d in "$EXTRACT_TEMP"/*/; do
    if [[ -d "$d" ]]; then
        EXTRACTED_DIR_NAME=$(basename "$d")
        break
    fi
done

if [[ -z "$EXTRACTED_DIR_NAME" ]]; then
    echo -e "${RED}Error: Archive extraction failed or archive is empty.${NC}" >&2
    exit 1
fi

echo -e "${BLUE}Detected package folder: $EXTRACTED_DIR_NAME${NC}"

# Move the extracted content to the final destination
escalate_cmd mv "$EXTRACT_TEMP/$EXTRACTED_DIR_NAME" "$TARGET_APP_DIR"

# Write the version metadata file
echo "$APP_VERSION" | escalate_cmd tee "$TARGET_APP_DIR/version.txt" > /dev/null

# Verify execution capability using dynamic binary name
if [[ ! -f "$TARGET_APP_DIR/$BINARY_NAME" ]]; then
    echo -e "${RED}Error: Extraction completed but executable was not found at $TARGET_APP_DIR/$BINARY_NAME${NC}" >&2
    exit 1
fi
escalate_cmd chmod +x "$TARGET_APP_DIR/$BINARY_NAME"

# Commit Phase: Successful install, mark flag and clean up backup
INSTALL_SUCCESSFUL=true
if [[ -n "$BACKUP_APP_DIR" && -d "$BACKUP_APP_DIR" ]]; then
    echo -e "${GREEN}✓ Verification passed. Removing installation backup...${NC}"
    escalate_cmd rm -rf "$BACKUP_APP_DIR"
fi

# Configure symlink path
echo -e "${YELLOW}Configuring system command shortcuts...${NC}"
# Ensure user-local bin folder exists
if [[ "$INSTALL_SCOPE" == "user" ]]; then
    mkdir -p "$(dirname "$TARGET_BIN_PATH")"
fi

escalate_cmd rm -f "$TARGET_BIN_PATH"
escalate_cmd ln -s "$TARGET_APP_DIR/$BINARY_NAME" "$TARGET_BIN_PATH"

# Configure Desktop application launcher entry
echo -e "${YELLOW}Generating Desktop integration entry...${NC}"

# -----------------------------------------------------------------------------
# Dual-Version Launcher Integrations & Shadowing Resolution
# -----------------------------------------------------------------------------
echo -e "${YELLOW}Analyzing system for dual-version coexistence...${NC}"

SYSTEM_DESKTOP_FILE="/usr/share/applications/${APP_NAME_SHORT}.desktop"
LOCAL_DESKTOP_FILE="$HOME/.local/share/applications/${APP_NAME_SHORT}.desktop"

if [[ "$INSTALL_SCOPE" == "system" ]]; then
    # 1. System Scope: Check if local desktop file exists and shadows system scope
    if [[ -f "$LOCAL_DESKTOP_FILE" ]]; then
        if grep -q "/usr/share/antigravity" "$LOCAL_DESKTOP_FILE" 2>/dev/null; then
            echo -e "${BLUE}Detected legacy v1.x launcher at user level. Renaming to preserve...${NC}"
            mv "$LOCAL_DESKTOP_FILE" "$HOME/.local/share/applications/${APP_NAME_SHORT}-legacy.desktop"
            update-desktop-database "$HOME/.local/share/applications" || true
            LEGACY_REPOSITIONED=true
        fi
    fi

    # 2. System Scope: Check if system-wide desktop file belongs to v1.x before overwriting
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        if grep -q "/usr/share/antigravity" "$SYSTEM_DESKTOP_FILE" 2>/dev/null; then
            echo -e "${BLUE}Detected system-wide legacy v1.x launcher. Renaming to preserve...${NC}"
            escalate_cmd mv "$SYSTEM_DESKTOP_FILE" "/usr/share/applications/${APP_NAME_SHORT}-legacy.desktop"
            LEGACY_REPOSITIONED=true
        fi
    fi

else
    # 3. User Scope: Check if local desktop file belongs to v1.x before overwriting
    if [[ -f "$LOCAL_DESKTOP_FILE" ]]; then
        if grep -q "/usr/share/antigravity" "$LOCAL_DESKTOP_FILE" 2>/dev/null; then
            echo -e "${BLUE}Detected legacy v1.x launcher at user level. Renaming to preserve...${NC}"
            mv "$LOCAL_DESKTOP_FILE" "$HOME/.local/share/applications/${APP_NAME_SHORT}-legacy.desktop"
            LEGACY_REPOSITIONED=true
        fi
    fi

    # 4. User Scope: Check if system-wide desktop file belongs to v1.x and will be shadowed
    if [[ -f "$SYSTEM_DESKTOP_FILE" ]]; then
        if grep -q "/usr/share/antigravity" "$SYSTEM_DESKTOP_FILE" 2>/dev/null; then
            # Copy system v1.x launcher to user applications folder as legacy to prevent it being shadowed
            LOCAL_LEGACY_PATH="$HOME/.local/share/applications/${APP_NAME_SHORT}-legacy.desktop"
            if [[ ! -f "$LOCAL_LEGACY_PATH" ]]; then
                echo -e "${BLUE}Detected system-wide legacy v1.x launcher. Copying to user-space to preserve...${NC}"
                mkdir -p "$(dirname "$LOCAL_LEGACY_PATH")"
                cp "$SYSTEM_DESKTOP_FILE" "$LOCAL_LEGACY_PATH"
                LEGACY_REPOSITIONED=true
            fi
        fi
    fi
fi
# Clean up older, duplicate desktop launchers to prevent duplicate launcher shortcuts
escalate_cmd rm -f "$DESKTOP_ENTRY_DIR/${APP_NAME_SHORT}-2.desktop"

# Generate the desktop integration template dynamically in the secure temp directory
TEMP_DESKTOP="$TEMP_DIR/${APP_NAME_SHORT}.desktop"
cat << 'EOF' > "$TEMP_DESKTOP"
[Desktop Entry]
Version=1.0
Type=Application
Name=__NAME__
Comment=__COMMENT__
GenericName=Text Editor
Exec=__EXEC_PATH__ --ozone-platform-hint=wayland --enable-features=WaylandWindowDecorations,CanvasOopRasterization --enable-gpu-rasterization --enable-zero-copy %F
Icon=__ICON_PATH__
Terminal=false
Categories=Development;IDE;TextEditor;
MimeType=application/x-antigravity-workspace;
StartupNotify=true
StartupWMClass=Antigravity
Actions=new-empty-window;
Keywords=vscode;

[Desktop Action new-empty-window]
Name=New Empty Window
Exec=__EXEC_PATH__ --ozone-platform-hint=wayland --enable-features=WaylandWindowDecorations,CanvasOopRasterization --enable-gpu-rasterization --enable-zero-copy --new-window %F
Icon=__ICON_PATH__
EOF

sed -i "s|__NAME__|$APP_NAME_PRETTY|g" "$TEMP_DESKTOP"
sed -i "s|__COMMENT__|$APP_COMMENT|g" "$TEMP_DESKTOP"
sed -i "s|__EXEC_PATH__|$TARGET_BIN_PATH|g" "$TEMP_DESKTOP"
sed -i "s|__ICON_PATH__|$ICON_LOOKUP_NAME|g" "$TEMP_DESKTOP"

# Install desktop file to applications folder
escalate_cmd mkdir -p "$DESKTOP_ENTRY_DIR"
escalate_cmd cp "$TEMP_DESKTOP" "$DESKTOP_ENTRY_PATH"
escalate_cmd chmod 644 "$DESKTOP_ENTRY_PATH"

# Install application icon to search path
echo -e "${YELLOW}Installing application icon...${NC}"
escalate_cmd mkdir -p "$ICON_TARGET_DIR"
escalate_cmd cp "$TEMP_DIR/antigravity.png" "$ICON_TARGET_DIR/antigravity.png"
escalate_cmd chmod 644 "$ICON_TARGET_DIR/antigravity.png"

# SELinux context restoration for system installations on Fedora
if [[ "$INSTALL_SCOPE" == "system" ]] && command -v restorecon &> /dev/null; then
    echo -e "${YELLOW}Restoring SELinux contexts for $TARGET_APP_DIR...${NC}"
    sudo restorecon -R "$TARGET_APP_DIR" || true
fi

# Update desktop application databases
echo -e "${YELLOW}Updating desktop database shortcuts...${NC}"
escalate_cmd update-desktop-database "$DESKTOP_ENTRY_DIR" || true

# Force GNOME Shell to reload launcher and icon textures immediately
escalate_cmd touch "$DESKTOP_ENTRY_PATH"

echo -e "${GREEN}${BOLD}✓ ${APP_NAME_PRETTY} successfully installed!${NC}"
echo -e "You can launch the application via:"
echo -e "  * Terminal command: ${BOLD}${APP_NAME_SHORT}${NC}"
echo -e "  * Application menu entry: ${BOLD}${APP_NAME_PRETTY}${NC}"

if [[ "$LEGACY_REPOSITIONED" == "true" ]]; then
    echo -e "\n${YELLOW}${BOLD}⚠️  Coexistence Notice:${NC}"
    echo -e "  A legacy Antigravity 1.x launcher has been renamed or copied to ${BOLD}${APP_NAME_SHORT}-legacy.desktop${NC}."
    echo -e "  Due to GNOME Shell's launcher grid caching, you may need to **log out and log back in**"
    echo -e "  for both launchers to appear side-by-side in your applications drawer."
fi

# Post-install Shell PATH verification diagnostics
if [[ "$INSTALL_SCOPE" == "user" ]]; then
    BIN_DIR=$(dirname "$TARGET_BIN_PATH")
    if [[ ":$PATH:" != *":$BIN_DIR:"* && ":$PATH:" != *":${BIN_DIR/#$HOME/\~}:"* ]]; then
        SHELL_NAME=$(basename "${SHELL:-bash}")
        CONFIG_FILE="$HOME/.bashrc"
        if [[ "$SHELL_NAME" == "zsh" ]]; then
            CONFIG_FILE="$HOME/.zshrc"
        elif [[ "$SHELL_NAME" == "ksh" ]]; then
            CONFIG_FILE="$HOME/.kshrc"
        fi

        echo -e "\n${YELLOW}${BOLD}⚠️  Shell Configuration Notice:${NC}"
        echo -e "  The local bin directory (${BOLD}${BIN_DIR}${NC}) is not in your system ${BOLD}PATH${NC} variable."
        echo -e "  To launch the application using the '${BOLD}${APP_NAME_SHORT}${NC}' command, add it by running:"
        echo -e "  ${BLUE}echo 'export PATH=\"\$HOME/.local/bin:\$PATH\"' >> ${CONFIG_FILE} && source ${CONFIG_FILE}${NC}"
    fi
fi
