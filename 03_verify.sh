#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 03_verify.sh - Verify Deletion
#
# Checks if users still exist in Admin Service and/or Auth0 after deletion
# Use this to confirm users were actually deleted
#
# Input: output/users_ready.csv (same file used by 02_delete.sh)
###############################################################################

# Configuration
CSV_PATH="${CSV_PATH:-output/users_ready.csv}"

# Log file
mkdir -p logs
STILL_EXISTS_LOG="logs/verify_still_exists.log"

# Initialize log with header
cat > "$STILL_EXISTS_LOG" << 'EOF'
# Verify - Users That Still Exist
# These users were NOT successfully deleted and need attention
# Format: Email,Service,Details
# ─────────────────────────────────────────────────────────────────
Email,Service,Details
EOF

# URL encode helper
urlencode() {
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Header
echo ""
echo "=== Step 3: Verify Deletion ==="
echo ""

# Select region
if [[ -n "${REGION:-}" ]]; then
    case "$REGION" in
        eu|EU)
            AUTH0_DOMAIN="port-prod.eu.auth0.com"
            ADMIN_API_URL="https://admin-service.production-internal.getport.io/v0.1"
            ;;
        us|US)
            AUTH0_DOMAIN="port-prod.us.auth0.com"
            ADMIN_API_URL="https://admin-service.us-production-internal.getport.io/v0.1"
            ;;
        *) echo "ERROR: Invalid region '$REGION'. Must be 'eu' or 'us'."; exit 1 ;;
    esac
    echo "Region: $REGION (from environment)"
else
    echo "Select region:"
    echo "  1) EU (Europe)"
    echo "  2) US (United States)"
    echo ""
    read -rp "Enter 1 or 2: " region_choice
    
    case "$region_choice" in
        1)
            AUTH0_DOMAIN="port-prod.eu.auth0.com"
            ADMIN_API_URL="https://admin-service.production-internal.getport.io/v0.1"
            ;;
        2)
            AUTH0_DOMAIN="port-prod.us.auth0.com"
            ADMIN_API_URL="https://admin-service.us-production-internal.getport.io/v0.1"
            ;;
        *) echo "ERROR: Invalid choice."; exit 1 ;;
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
    exit 1
fi

# Validate CSV
if [[ ! -f "$CSV_PATH" ]]; then
    echo "ERROR: CSV file not found: $CSV_PATH"
    echo ""
    echo "Run ./01_prepare.sh and ./02_delete.sh first."
    exit 1
fi

user_count=$(tail -n +2 "$CSV_PATH" | grep -c '[^[:space:]]' || echo 0)
if [[ "$user_count" -eq 0 ]]; then
    echo "ERROR: No users found in CSV"
    exit 1
fi

echo "Input: $CSV_PATH"
echo "Users: $user_count"
echo ""

read -rp "Proceed? [y/n]: " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# Counters
processed=0
admin_gone=0 admin_exists=0 admin_error=0
auth0_gone=0 auth0_exists=0 auth0_error=0 auth0_skip=0

echo ""
echo "=== Verifying ==="

while IFS=, read -r email port_name auth0_id; do
    email="$(echo "${email:-}" | xargs)"
    port_name="$(echo "${port_name:-}" | xargs)"
    auth0_id="$(echo "${auth0_id:-}" | xargs)"
    
    [[ -z "$email" ]] && continue
    
    ((++processed))
    echo ""
    echo "[$processed/$user_count] $email"
    
    # --- Check Admin Service ---
    email_enc="$(urlencode "$email")"
    resp_file="$(mktemp)"
    status="$(curl -sS -o "$resp_file" -w "%{http_code}" "${ADMIN_API_URL}/users/email/${email_enc}")"
    rm -f "$resp_file"
    
    case "$status" in
        200)
            echo "  ADMIN: ⚠ STILL EXISTS"
            echo "$email,Admin Service,User still exists" >> "$STILL_EXISTS_LOG"
            ((++admin_exists))
            ;;
        404)
            echo "  ADMIN: ✓ Gone"
            ((++admin_gone))
            ;;
        *)
            echo "  ADMIN: ? Error (HTTP $status)"
            ((++admin_error))
            ;;
    esac
    
    # --- Check Auth0 ---
    if [[ -z "$auth0_id" ]]; then
        echo "  AUTH0: - Skipped (no ID)"
        ((++auth0_skip))
    else
        auth0_id_enc="$(urlencode "$auth0_id")"
        resp_file="$(mktemp)"
        status="$(curl -sS -o "$resp_file" -w "%{http_code}" \
            -H "Authorization: Bearer ${AUTH0_TOKEN}" \
            "https://${AUTH0_DOMAIN}/api/v2/users/${auth0_id_enc}")"
        rm -f "$resp_file"
        
        case "$status" in
            200)
                echo "  AUTH0: ⚠ STILL EXISTS"
                echo "$email,Auth0,User still exists (ID: $auth0_id)" >> "$STILL_EXISTS_LOG"
                ((++auth0_exists))
                ;;
            404)
                echo "  AUTH0: ✓ Gone"
                ((++auth0_gone))
                ;;
            *)
                echo "  AUTH0: ? Error (HTTP $status)"
                ((++auth0_error))
                ;;
        esac
    fi
    
    # Small delay to avoid rate limiting
    sleep 0.1

done < <(tail -n +2 "$CSV_PATH")

# Summary
echo ""
echo "=== Verify Summary ==="
echo ""
echo "Processed: $processed users"
echo ""
echo "Admin Service:"
echo "  ✓ Gone:          $admin_gone"
echo "  ⚠ Still exists:  $admin_exists"
echo "  ? Error:         $admin_error"
echo ""
echo "Auth0:"
echo "  ✓ Gone:          $auth0_gone"
echo "  ⚠ Still exists:  $auth0_exists"
echo "  ? Error:         $auth0_error"
echo "  - Skipped:       $auth0_skip"
echo ""

# Final verdict
total_still_exists=$((admin_exists + auth0_exists))
if [[ "$total_still_exists" -eq 0 ]]; then
    echo "✓ SUCCESS: All users have been deleted!"
else
    echo "⚠ WARNING: $total_still_exists user(s) still exist!"
    echo "Review: $STILL_EXISTS_LOG"
fi
echo ""
