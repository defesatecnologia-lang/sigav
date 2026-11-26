# If we aren't running as root, just exec the CMD
[ "$(id -u)" -ne 0 ] && exec "$@"

echo "Creating user and group..."

PUID=${PUID:-1002}
PGID=${PGID:-1002}

# Check if the group with PGID exists; if not, create it
if ! getent group controle-group > /dev/null 2>&1; then
    addgroup -g "$PGID" controle-group
fi

# Check if a user with PUID exists; if not, create it
if ! id -u controle-user > /dev/null 2>&1; then
    if ! getent passwd "$PUID" > /dev/null 2>&1; then
        adduser -u "$PUID" -G controle-group controle-user > /dev/null 2>&1
    else
        # If a user with the PUID already exists, use that user
        existing_user=$(getent passwd "$PUID" | cut -d: -f1)
        echo "Using existing user: $existing_user"
    fi
fi

# Persisted bind mounts must be provisioned on the host as PUID:PGID. This
# container drops CAP_CHOWN, so it cannot repair ownership during startup.
DATA_DIR="${DATA_DIRECTORY:-${DATA_ROOT:-/opt/app/data}}"
for dir in "${DATA_DIR}" /opt/app/frontend/public/img; do
    if ! su-exec "${PUID}:${PGID}" sh -c \
        'test -d "$1" && test -r "$1" && test -w "$1" && test -x "$1"' sh "$dir"; then
        echo "Error: ${dir} must exist and be accessible (rwx) by ${PUID}:${PGID}; provision it on the host." >&2
        exit 1
    fi
done

# Switch to the non-root user
exec su-exec "$PUID:$PGID" "$@"
