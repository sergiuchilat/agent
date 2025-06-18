#!/bin/bash


### Configuration
VERSION="1.0.18"
DATA_FOLDER="./data"
SLEEP_INTERVAL=10

AGENT_SOURCE_URL="https://api.github.com/repos/sergiuchilat/agent/contents/agent.sh"
API_COLLECTOR_URL="https://adt-agent.requestcatcher.com/test"

UUID_FILE="$DATA_FOLDER/agent_uuid"

### Functions

check_os() {
    if [ "$(uname -s)" != "Linux" ]; then
        echo "Error: This agent only works on Linux systems" >&2
        exit 1
    fi
}

generate_uuid() {
    if [ ! -f "$UUID_FILE" ]; then
        generated_uuid=$(uuidgen)
        echo "$generated_uuid" > "$UUID_FILE"
    fi
    echo $(cat "$UUID_FILE")
}

generate_snapshot() {
    # Get users and groups information
    if ! command -v getent >/dev/null 2>&1; then
        echo "Error: getent command not found" >&2
        users_info="{\"error\": \"getent command not found\"}"
        groups_info="{\"error\": \"getent command not found\"}"
    else
        users=$(getent passwd | awk -F: '{print "{\"username\":\"" $1 "\",\"uid\":" $3 ",\"home\":\"" $6 "\"}"}' | tr '\n' ',' | sed 's/,$//')
        groups=$(getent group | awk -F: '{print "{\"name\":\"" $1 "\",\"gid\":" $3 "}"}' | tr '\n' ',' | sed 's/,$//')
        users_info="{\"users\": [$users]}"
        groups_info="{\"groups\": [$groups]}"
    fi

    # Get OS information
    os_name=$(cat /etc/os-release | grep "^NAME=" | cut -d'"' -f2)
    os_version=$(cat /etc/os-release | grep "^VERSION=" | cut -d'"' -f2)
    os_info="{\"name\": \"$os_name\", \"version\": \"$os_version\"}"

    # Get open ports using ss command (modern replacement for netstat)
    if ! command -v ss >/dev/null 2>&1; then
        echo "Warning: ss command not found" >&2
        ports_info="{\"error\": \"ss command not found\"}"
    else
        tcp_ports=$(ss -tln | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' | sort -n | tr '\n' ',' | sed 's/,$//')
        udp_ports=$(ss -uln | awk 'NR>1 {split($4,a,":"); print a[length(a)]}' | sort -n | tr '\n' ',' | sed 's/,$//')
        ports_info="{\"tcp\": [$tcp_ports], \"udp\": [$udp_ports]}"
    fi

    # Get number of RAM slots using dmidecode
    if ! command -v dmidecode >/dev/null 2>&1; then
        echo "Warning: dmidecode command not found" >&2
        ram_slots="{\"error\": \"dmidecode command not found\"}"
    else
        ram_slots=$(dmidecode -t memory | grep -c "^Memory Device$")
        ram_slots="{\"total_slots\": $ram_slots}"
    fi

    # Get IP addresses
    if ! command -v ip >/dev/null 2>&1; then
        echo "Warning: ip command not found" >&2
        ip_info="{\"error\": \"ip command not found\"}"
    else
        ipv4_addresses=$(ip -4 addr show | awk '/inet / {print $2}' | tr '\n' ',' | sed 's/,$//')
        ipv6_addresses=$(ip -6 addr show | awk '/inet6/ {print $2}' | tr '\n' ',' | sed 's/,$//')
        ip_info="{\"ipv4\": [${ipv4_addresses}], \"ipv6\": [${ipv6_addresses}]}"
    fi

    # Check if required Linux commands exist
    if ! command -v lscpu >/dev/null 2>&1; then
        echo "Warning: lscpu command not found" >&2
    fi

    if ! command -v free >/dev/null 2>&1; then
        echo "Warning: free command not found" >&2
    fi

    if ! command -v ps >/dev/null 2>&1; then
        echo "Warning: ps command not found" >&2
    fi

    if ! command -v df >/dev/null 2>&1; then
        echo "Warning: df command not found" >&2
    fi

    if ! command -v hostname >/dev/null 2>&1; then
        echo "Warning: hostname command not found" >&2
    fi

    # Get CPU info using lscpu
    if ! lscpu -J >/dev/null 2>&1; then
        cpu_info="{\"error\": \"lscpu JSON output not supported\"}"
    else
        cpu_info=$(lscpu -J)
    fi

    cat << EOF
{
    "agent_version": "$VERSION",
    "uuid": "$UUID",
    "timestamp": "$(date)",
    "os_info": $os_info,
    "ports_info": $ports_info,
    "ip_info": $ip_info,
    "hostname": "$(hostname)",
    "cpu_info": $cpu_info,
    "memory_info": {
        "total": "$(free -b | awk 'NR==2 {print $2}')",
        "used": "$(free -b | awk 'NR==2 {print $3}')",
        "free": "$(free -b | awk 'NR==2 {print $4}')",
        "shared": "$(free -b | awk 'NR==2 {print $5}')",
        "buffers": "$(free -b | awk 'NR==2 {print $6}')",
        "cache": "$(free -b | awk 'NR==2 {print $7}')",
        "total_slots": $ram_slots
    },
    "disk_info": {
        "filesystems": [$(df -P | awk 'NR>1 {printf "%s{\"filesystem\":\"%s\",\"total\":%s,\"used\":%s,\"available\":%s,\"use_percent\":%d,\"mounted_on\":\"%s\"}", (NR==2)?"":",", $1, $2*1024, $3*1024, $4*1024, $5+0, $6}')]
    },
    "processes": [$(ps aux --no-headers | awk '{
        printf "%s{\"user\":\"%s\",\"pid\":%s,\"cpu\":%.1f,\"mem\":%.1f,\"vsz\":%s,\"rss\":%s,\"tty\":\"%s\",\"stat\":\"%s\",\"start\":\"%s\",\"time\":\"%s\",\"command\":\"%s\"}",
        (NR==1)?"":",", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
    }')],
    "users_info": $users_info,
    "groups_info": $groups_info
}
EOF
}

send_snapshot() {
    snapshot=$1
    api_url=${API_COLLECTOR_URL}

    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-Agent-ID: $UUID" \
        -d "$snapshot" \
        "$api_url")

    if [ $? -eq 0 ]; then
        echo "Snapshot sent successfully"
    else
        echo "Failed to send snapshot"
    fi
}


self_update() {
    # Get latest version from GitHub API
    latest_script=$(curl -s -H "Accept: application/vnd.github.v3.raw" \
        "$AGENT_SOURCE_URL")

    if [ $? -ne 0 ]; then
        echo "Failed to fetch latest version"
        return 1
    fi

    # Save current script hash
    current_hash=$(md5sum "$0" | cut -d' ' -f1)
    
    # Save latest script to temporary file and get its hash
    echo "$latest_script" > "$0.tmp"
    latest_hash=$(md5sum "$0.tmp" | cut -d' ' -f1)

    if [ "$current_hash" != "$latest_hash" ]; then
        echo "New version detected, updating..."
        mv "$0.tmp" "$0"
        chmod 755 "$0"
        echo "Update successful, restarting..."
        exec "$0"
    else
        echo "Already running latest version"
        rm -f "$0.tmp"
    fi

}

### Main scenario


check_os

mkdir -p "$DATA_FOLDER"

UUID=$(generate_uuid)

while true; do
    echo "Agent version: $VERSION"
    
    # self_update

    timestamp=$(date +%Y%m%d_%H%M%S)

    snapshot_json=$(generate_snapshot)

    echo "$snapshot_json" > "$DATA_FOLDER/${timestamp}.json"

    echo "Sending snapshot to API..."
    send_snapshot "$snapshot_json"

    echo "Sleeping for $SLEEP_INTERVAL seconds..."
    sleep $SLEEP_INTERVAL
done
