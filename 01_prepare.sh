#!/usr/bin/env bash
set -euo pipefail

###############################################################################
# 01_prepare.sh - Prepare Users for Deletion
#
# Looks up Auth0 user IDs for a list of emails and generates a CSV ready
# for deletion by 02_delete.sh
#
# Input:  input/users.csv (Email, Port Name)
# Output: output/users_ready.csv (Email, Port Name, Auth0 ID)
###############################################################################

# Configuration
INPUT_CSV="${INPUT_CSV:-input/users.csv}"
OUTPUT_CSV="${OUTPUT_CSV:-output/users_ready.csv}"

# Log files
mkdir -p logs
FOUND_LOG="logs/prepare_found.log"
NOT_FOUND_LOG="logs/prepare_not_found.log"
ERROR_LOG="logs/prepare_errors.log"

# Initialize log files with headers
cat > "$FOUND_LOG" << 'EOF'
# Prepare - Users Found in Auth0
# These users exist in Auth0 and are ready for deletion
# Format: Email,Port Name,Auth0 ID
# ─────────────────────────────────────────────────────────────────
Email,Port Name,Auth0 ID
EOF

cat > "$NOT_FOUND_LOG" << 'EOF'
# Prepare - Users Not Found in Auth0
# These users do not exist in Auth0 (may have been deleted or never created)
# Format: Email,Port Name
# Note: These users will still be deleted from Admin Service
# ─────────────────────────────────────────────────────────────────
Email,Port Name
EOF

cat > "$ERROR_LOG" << 'EOF'
# Prepare - API Errors
# Errors that occurred during Auth0 lookup (e.g., 401, 403, 429)
# Format: Email,Port Name,HTTP Status,Error Details
# ─────────────────────────────────────────────────────────────────
Email,Port Name,HTTP Status,Error Details
EOF

# URL encode helper
urlencode() {
    python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$1"
}

# Clean port name - if it's same as email or empty, derive from email
clean_port_name() {
    local email="$1"
    local name="$2"
    
    if [[ -z "$name" ]] || [[ "$name" == "$email" ]]; then
        # Extract name from email (e.g., dustin.savage@smarsh.com -> Dustin Savage)
        local local_part="${email%%@*}"
        # Replace dots/underscores with spaces and capitalize each word
        echo "$local_part" | tr '._' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
    else
        echo "$name"
    fi
}

# Header
echo ""
echo "=== Step 1: Prepare Users ==="
echo ""

# Select region
if [[ -n "${REGION:-}" ]]; then
    case "$REGION" in
        eu|EU) AUTH0_DOMAIN="port-prod.eu.auth0.com" ;;
        us|US) AUTH0_DOMAIN="port-prod.us.auth0.com" ;;
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
        1) AUTH0_DOMAIN="port-prod.eu.auth0.com" ;;
        2) AUTH0_DOMAIN="port-prod.us.auth0.com" ;;
        *) echo "ERROR: Invalid choice."; exit 1 ;;
    esac
fi

echo "Auth0 Domain: $AUTH0_DOMAIN"
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

# Validate input CSV
if [[ ! -f "$INPUT_CSV" ]]; then
    echo "ERROR: Input CSV file not found: $INPUT_CSV"
    echo ""
    echo "Create a CSV file with columns: Email,Port Name"
    exit 1
fi

user_count=$(tail -n +2 "$INPUT_CSV" | grep -c '[^[:space:]]' || echo 0)
if [[ "$user_count" -eq 0 ]]; then
    echo "ERROR: No users found in CSV"
    exit 1
fi

echo "Input:  $INPUT_CSV"
echo "Output: $OUTPUT_CSV"
echo "Users:  $user_count"
echo ""

read -rp "Proceed? [y/n]: " confirm
if [[ ! "$confirm" =~ ^[Yy] ]]; then
    echo "Aborted."
    exit 0
fi

# Create output directory and CSV with header
mkdir -p "$(dirname "$OUTPUT_CSV")"
echo "Email,Port Name,Auth0 ID" > "$OUTPUT_CSV"

# Counters
processed=0
found=0
not_found=0
errors=0

echo ""
echo "=== Processing ==="

while IFS=, read -r email port_name; do
    email="$(echo "${email:-}" | xargs)"
    port_name="$(echo "${port_name:-}" | xargs)"
    
    [[ -z "$email" ]] && continue
    
    # Clean up port name for display
    display_name=$(clean_port_name "$email" "$port_name")
    
    ((++processed))
    echo ""
    echo "[$processed/$user_count] $email"
    
    # Look up user in Auth0
    email_enc="$(urlencode "$email")"
    resp_file="$(mktemp)"
    status="$(curl -sS -o "$resp_file" -w "%{http_code}" \
        -H "Authorization: Bearer ${AUTH0_TOKEN}" \
        "https://${AUTH0_DOMAIN}/api/v2/users-by-email?email=${email_enc}")"
    body="$(cat "$resp_file")"
    rm -f "$resp_file"
    
    if [[ "$status" != "200" ]]; then
        echo "  ERROR: HTTP $status"
        echo "$email,$display_name," >> "$OUTPUT_CSV"
        # Escape body for CSV (remove newlines, limit length)
        error_msg=$(echo "$body" | tr '\n' ' ' | cut -c1-200)
        echo "$email,$display_name,$status,$error_msg" >> "$ERROR_LOG"
        ((++errors))
        continue
    fi
    
    # Parse Auth0 response (it's a JSON array)
    auth0_id=$(echo "$body" | python3 -c "
import sys, json
try:
    users = json.load(sys.stdin)
    if users and len(users) > 0:
        print(users[0].get('user_id', ''))
    else:
        print('')
except:
    print('')
" 2>/dev/null || echo "")
    
    if [[ -n "$auth0_id" ]]; then
        echo "  Found: $auth0_id"
        echo "$email,$display_name,$auth0_id" >> "$OUTPUT_CSV"
        echo "$email,$display_name,$auth0_id" >> "$FOUND_LOG"
        ((++found))
    else
        echo "  Not found in Auth0"
        echo "$email,$display_name," >> "$OUTPUT_CSV"
        echo "$email,$display_name" >> "$NOT_FOUND_LOG"
        ((++not_found))
    fi
    
    # Small delay to avoid rate limiting
    sleep 0.1

done < <(tail -n +2 "$INPUT_CSV")

# Summary
echo ""
echo "=== Prepare Summary ==="
echo ""
echo "Processed: $processed users"
echo "Found:     $found (ready for Auth0 deletion)"
echo "Not found: $not_found (will skip Auth0, still delete from Admin)"
echo "Errors:    $errors"
echo ""
echo "Output: $OUTPUT_CSV"
echo ""
echo "Logs:"
echo "  Found:     $FOUND_LOG"
echo "  Not found: $NOT_FOUND_LOG"
echo "  Errors:    $ERROR_LOG"
echo ""

if [[ "$not_found" -gt 0 ]]; then
    echo "NOTE: $not_found users not in Auth0 - they will still be deleted from Admin Service."
    echo ""
fi

echo "Next step: Run ./02_delete.sh"
echo ""
