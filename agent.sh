#!/bin/bash


### Configuration
VERSION="1.0.6"
DATA_FOLDER="./data"
SLEEP_INTERVAL=10

AGENT_SOURCE_URL="https://raw.githubusercontent.com/sergiuchilat/agent/main/agent.sh"
API_COLLECTOR_URL="https://adt-agent.requestcatcher.com/test"

UUID_FILE="$DATA_FOLDER/agent_uuid"

### Main
mkdir -p "$DATA_FOLDER"

generate_uuid() {
    if [ ! -f "$UUID_FILE" ]; then
        generated_uuid=$(uuidgen)
        echo "$generated_uuid" > "$UUID_FILE"
    fi
    echo $(cat "$UUID_FILE")
}

UUID=$(generate_uuid)

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
    if ! command -v uname >/dev/null 2>&1; then
        echo "Warning: uname command not found" >&2
        os_info="{\"error\": \"uname command not found\"}"
    else
        os_name=$(uname -s)
        os_version=$(uname -r)
        os_info="{\"name\": \"$os_name\", \"version\": \"$os_version\"}"
    fi

    # Get open ports
    if ! command -v netstat >/dev/null 2>&1; then
        echo "Warning: netstat command not found" >&2
        ports_info="{\"error\": \"netstat command not found\"}"
    else
        # Get listening TCP and UDP ports
        tcp_ports=$(netstat -tln | awk '/^tcp/ {split($4,a,":"); print a[length(a)]}' | sort -n | tr '\n' ',' | sed 's/,$//')
        udp_ports=$(netstat -uln | awk '/^udp/ {split($4,a,":"); print a[length(a)]}' | sort -n | tr '\n' ',' | sed 's/,$//')
        ports_info="{\"tcp\": [$tcp_ports], \"udp\": [$udp_ports]}"
    fi

    # Get OS information
    if ! command -v uname >/dev/null 2>&1; then
        echo "Warning: uname command not found" >&2
        os_info="{\"error\": \"uname command not found\"}"
    else
        os_name=$(uname -s)
        os_version=$(uname -r)
        os_info="{\"name\": \"$os_name\", \"version\": \"$os_version\"}"
    fi

    # Get number of RAM slots
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

    # Check if required commands exist
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

    # Some older versions of lscpu don't support -J flag
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
    echo "Checking for updates..."

    current_checksum=$(md5sum agent.sh | awk '{print $1}')
    remote_script=$(curl -s -H "Cache-Control: no-cache" "$AGENT_SOURCE_URL")
    remote_checksum=$(echo "$remote_script" | md5sum | awk '{print $1}')
    if [ "$current_checksum" != "$remote_checksum" ]; then
        echo "Update available, installing..."
        echo "$remote_script" > agent.sh
        chmod +x agent.sh
        echo "Agent updated successfully"
        echo "$(date '+%Y-%m-%d %H:%M:%S') - Agent updated and restarted" >> "$DATA_FOLDER/update.log"
        systemctl restart adt-infra-hub-agent.service
        exit 0
    else
        echo "Agent is up to date"
    fi
}

while true; do
    echo "Agent version: $VERSION"
    
    self_update

    timestamp=$(date +%Y%m%d_%H%M%S)

    snapshot_json=$(generate_snapshot)

    echo "$snapshot_json" > "$DATA_FOLDER/${timestamp}.json"

    echo "Sending snapshot to API..."
    send_snapshot "$snapshot_json"

    echo "Sleeping for $SLEEP_INTERVAL seconds..."
    sleep $SLEEP_INTERVAL
done
