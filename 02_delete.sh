#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 02_delete.sh - Delete Users
#
# Deletes users from Port Admin Service and Auth0
#
# Input: output/users_ready.csv (from 01_prepare.sh)
###############################################################################

# Configuration
CSV_PATH="${CSV_PATH:-output/users_ready.csv}"

# Log files
mkdir -p logs
ADMIN_SUCCESS_LOG="logs/delete_admin_success.log"
ADMIN_ERROR_LOG="logs/delete_admin_errors.log"
AUTH0_SUCCESS_LOG="logs/delete_auth0_success.log"
AUTH0_ERROR_LOG="logs/delete_auth0_errors.log"

# Initialize logs with headers
cat > "$ADMIN_SUCCESS_LOG" << 'EOF'
# Delete - Admin Service Success
# Format: Timestamp,Status,Email,Port Name
# ─────────────────────────────────────────────────────────────────
Timestamp,Status,Email,Port Name
EOF

cat > "$ADMIN_ERROR_LOG" << 'EOF'
# Delete - Admin Service Errors
# Format: Timestamp,Status,Email,Port Name,HTTP Status,Error
# ─────────────────────────────────────────────────────────────────
Timestamp,Status,Email,Port Name,HTTP Status,Error
EOF

cat > "$AUTH0_SUCCESS_LOG" << 'EOF'
# Delete - Auth0 Success
# Format: Timestamp,Status,Email,Auth0 ID
# ─────────────────────────────────────────────────────────────────
Timestamp,Status,Email,Auth0 ID
EOF

cat > "$AUTH0_ERROR_LOG" << 'EOF'
# Delete - Auth0 Errors
# Format: Timestamp,Status,Email,Auth0 ID,Error
# ─────────────────────────────────────────────────────────────────
Timestamp,Status,Email,Auth0 ID,Error
EOF

# URL encode helper
urlencode() {
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Set URLs based on region
set_region_urls() {
    local region="$1"
    case "$region" in
        eu|EU)
            AUTH0_DOMAIN="port-prod.eu.auth0.com"
            ADMIN_API_URL="https://admin-service.production-internal.getport.io/v0.1"
            ;;
        us|US)
            AUTH0_DOMAIN="port-prod.us.auth0.com"
            ADMIN_API_URL="https://admin-service.us-production-internal.getport.io/v0.1"
            ;;
        *)
            echo "ERROR: Invalid region '$region'. Must be 'eu' or 'us'."
            exit 1
            ;;
    esac
}

# Header
echo ""
echo "=== Step 2: Delete Users ==="
echo ""

# Select region
if [[ -n "${REGION:-}" ]]; then
    set_region_urls "$REGION"
    echo "Region: $REGION (from environment)"
else
    echo "Select region:"
    echo "  1) EU (Europe)"
    echo "  2) US (United States)"
    echo ""
    read -rp "Enter 1 or 2: " region_choice
    
    case "$region_choice" in
        1) set_region_urls "eu" ;;
        2) set_region_urls "us" ;;
        *)
            echo "ERROR: Invalid choice. Please enter 1 or 2."
            exit 1
            ;;
    esac
fi

echo "Auth0 Domain: $AUTH0_DOMAIN"
echo "Admin API:    $ADMIN_API_URL"
echo ""

# Check Auth0 token
if [[ -z "${AUTH0_TOKEN:-}" ]]; then
    echo "ERROR: AUTH0_TOKEN is required."
    echo ""
    echo "To set it, run:"
    echo "  export AUTH0_TOKEN='your-management-api-token'"
    echo ""
    echo "Then run this script again."
    exit 1
fi

# Validate CSV
if [[ ! -f "$CSV_PATH" ]]; then
    echo "ERROR: CSV file not found: $CSV_PATH"
    echo ""
    echo "Run ./01_prepare.sh first to generate this file."
    exit 1
fi

user_count=$(tail -n +2 "$CSV_PATH" | grep -c '[^[:space:]]' || echo 0)
if [[ "$user_count" -eq 0 ]]; then
    echo "ERROR: No users found in CSV"
    exit 1
fi

# Show preview
echo "Input: $CSV_PATH"
echo "Users: $user_count"
echo ""
echo "Preview:"
tail -n +2 "$CSV_PATH" | head -5 | while IFS=, read -r email port_name auth0_id; do
    echo "  - $(echo "$email" | xargs)"
done
[[ "$user_count" -gt 5 ]] && echo "  ... and $((user_count - 5)) more"
echo ""

# Confirm
echo "This will delete users from:"
echo "  - Port Admin Service"
echo "  - Auth0 ($AUTH0_DOMAIN)"
echo ""
read -rp "Proceed? [y/n]: " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# Counters
processed=0
admin_deleted=0 admin_not_found=0 admin_fail=0
auth0_deleted=0 auth0_not_found=0 auth0_fail=0 auth0_skip=0

echo ""
echo "=== Processing ==="

while IFS=, read -r email port_name auth0_id; do
    email="$(echo "${email:-}" | xargs)"
    port_name="$(echo "${port_name:-}" | xargs)"
    auth0_id="$(echo "${auth0_id:-}" | xargs)"
    
    [[ -z "$email" ]] && continue
    
    ((++processed))
    echo ""
    echo "[$processed/$user_count] $email"
    
    # --- Admin Service ---
    email_enc="$(urlencode "$email")"
    resp_file="$(mktemp)"
    status="$(curl -sS -o "$resp_file" -w "%{http_code}" -X DELETE "${ADMIN_API_URL}/users/email/${email_enc}")"
    body="$(cat "$resp_file")"
    rm -f "$resp_file"
    
    case "$status" in
        200)
            echo "  ADMIN: Deleted"
            echo "$(date -Iseconds),DELETED,$email,$port_name" >> "$ADMIN_SUCCESS_LOG"
            ((++admin_deleted))
            ;;
        404)
            echo "  ADMIN: Not found (wasn't in Admin Service)"
            echo "$(date -Iseconds),NOT_FOUND,$email,$port_name" >> "$ADMIN_SUCCESS_LOG"
            ((++admin_not_found))
            ;;
        *)
            echo "  ADMIN: ERROR $status - $body"
            echo "$(date -Iseconds),ERROR,$email,$port_name,$status,$body" >> "$ADMIN_ERROR_LOG"
            ((++admin_fail))
            ;;
    esac
    
    # --- Auth0 ---
    if [[ -z "$auth0_id" ]]; then
        echo "  AUTH0: Skipped (no ID)"
        ((++auth0_skip))
    else
        auth0_id_enc="$(urlencode "$auth0_id")"
        resp_file="$(mktemp)"
        status="$(curl -sS -o "$resp_file" -w "%{http_code}" -X DELETE \
            -H "Authorization: Bearer ${AUTH0_TOKEN}" \
            "https://${AUTH0_DOMAIN}/api/v2/users/${auth0_id_enc}")"
        body="$(cat "$resp_file")"
        rm -f "$resp_file"
        
        case "$status" in
            200|204)
                echo "  AUTH0: Deleted"
                echo "$(date -Iseconds),DELETED,$email,$auth0_id" >> "$AUTH0_SUCCESS_LOG"
                ((++auth0_deleted))
                ;;
            404)
                echo "  AUTH0: Not found (wasn't in Auth0)"
                echo "$(date -Iseconds),NOT_FOUND,$email,$auth0_id" >> "$AUTH0_SUCCESS_LOG"
                ((++auth0_not_found))
                ;;
            401)
                echo "  AUTH0: ERROR 401 - Unauthorized (bad token)"
                echo "$(date -Iseconds),UNAUTHORIZED,$email,$auth0_id,Invalid token" >> "$AUTH0_ERROR_LOG"
                ((++auth0_fail))
                ;;
            403)
                echo "  AUTH0: ERROR 403 - Forbidden (missing scope)"
                echo "$(date -Iseconds),FORBIDDEN,$email,$auth0_id,Missing delete:users scope" >> "$AUTH0_ERROR_LOG"
                ((++auth0_fail))
                ;;
            *)
                echo "  AUTH0: ERROR $status - $body"
                echo "$(date -Iseconds),ERROR,$email,$auth0_id,$body" >> "$AUTH0_ERROR_LOG"
                ((++auth0_fail))
                ;;
        esac
    fi

done < <(tail -n +2 "$CSV_PATH")

# Summary
echo ""
echo "=== Delete Summary ==="
echo ""
echo "Processed: $processed users"
echo ""
echo "Admin Service:"
echo "  Deleted:   $admin_deleted"
echo "  Not found: $admin_not_found (user wasn't in Admin Service)"
echo "  Failed:    $admin_fail"
echo ""
echo "Auth0:"
echo "  Deleted:   $auth0_deleted"
echo "  Not found: $auth0_not_found (user wasn't in Auth0)"
echo "  Failed:    $auth0_fail"
echo "  Skipped:   $auth0_skip (no Auth0 ID)"
echo ""
echo "Logs:"
echo "  $ADMIN_SUCCESS_LOG"
echo "  $ADMIN_ERROR_LOG"
echo "  $AUTH0_SUCCESS_LOG"
echo "  $AUTH0_ERROR_LOG"
echo ""
echo "Next step: Run ./03_verify.sh to confirm deletion"
echo ""
