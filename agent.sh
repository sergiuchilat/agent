#!/bin/bash


### Configuration
VERSION=${VERSION:-""}
DATA_FOLDER=${DATA_FOLDER:-"./data"}
UPDATE_INTERVAL=${UPDATE_INTERVAL:-60}
TOKEN=${TOKEN:-""}
API_COLLECTOR_URL=${API_COLLECTOR_URL:-""} 
SNAPSHOT_RETENTION_DAYS=${SNAPSHOT_RETENTION_DAYS:-1}

# Parse command line arguments
while [ $# -gt 0 ]; do
    case $1 in
        --token=*)
            TOKEN="${1#*=}"
            shift
            ;;
        --version=*)
            VERSION="${1#*=}"
            shift
            ;;
        --api_collector_url=*)
            API_COLLECTOR_URL="${1#*=}"
            shift
            ;;
        --data_folder=*)
            DATA_FOLDER="${1#*=}"
            shift
            ;;
        --update_interval=*)
            UPDATE_INTERVAL="${1#*=}"
            shift
            ;;
        --snapshot_retention_days=*)
            SNAPSHOT_RETENTION_DAYS="${1#*=}"
            shift
            ;;
        *)
            echo "Unknown option: $1"
            echo "Usage: $0 [--token=TOKEN] [--version=VERSION] [--api_collector_url=URL] [--data_folder=PATH] [--update_interval=SECONDS] [--snapshot_retention_days=DAYS]"
            exit 1
            ;;
    esac
done

# Environment variables are already available if not set via command line arguments

UUID_FILE="$DATA_FOLDER/agent_uuid"

### Functions

validate_params() {
    if [ -z "$API_COLLECTOR_URL" ]; then
        echo "Error: API_COLLECTOR_URL is not set" >&2
        exit 1
    fi

    if [ -z "$TOKEN" ]; then
        echo "Error: TOKEN is not set" >&2
        exit 1
    fi
    
    if [ -z "$VERSION" ]; then
        echo "Error: VERSION is not set" >&2
        exit 1
    fi

    if [ -z "$DATA_FOLDER" ]; then
        echo "Error: DATA_FOLDER is not set" >&2
        exit 1
    fi
}

check_os() {
    if [ "$(uname -s)" != "Linux" ] && [ "$(uname -s)" != "Darwin" ]; then
        echo "Error: This agent only works on Linux and macOS systems" >&2
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
    # Detect OS
    OS=$(uname -s)
    
    # Get users and groups information
    if [ "$OS" = "Darwin" ]; then
        # macOS users and groups
        users=$(dscl . -list /Users | awk '{print "{\"username\":\"" $1 "\",\"uid\":\"\",\"home\":\"\"}"}' | tr '\n' ',' | sed 's/,$//')
        groups=$(dscl . -list /Groups | awk '{print "{\"name\":\"" $1 "\",\"gid\":\"\"}"}' | tr '\n' ',' | sed 's/,$//')
        users_info="{\"users\": [$users]}"
        groups_info="{\"groups\": [$groups]}"
    else
        # Linux users and groups
        if ! command -v getent >/dev/null 2>&1; then
            echo "Error: getent command not found" >&2
            users_info="{\"error\": \"getent command not found\"}"
            groups_info="{\"error\": \"getent command not found\"}"
        else
            users=$(getent passwd | awk -F: '{gsub(/"/,"\\\"", $1); gsub(/"/,"\\\"", $6); print "{\"username\":\"" $1 "\",\"uid\":" $3 ",\"home\":\"" $6 "\"}"}' | tr '\n' ',' | sed 's/,$//')
            groups=$(getent group | awk -F: '{gsub(/"/,"\\\"", $1); print "{\"name\":\"" $1 "\",\"gid\":" $3 "}"}' | tr '\n' ',' | sed 's/,$//')
            users_info="{\"users\": [$users]}"
            groups_info="{\"groups\": [$groups]}"
        fi
    fi

    # Get OS information
    if [ "$OS" = "Darwin" ]; then
        os_name="macOS"
        os_version=$(sw_vers -productVersion)
        os_info="{\"name\": \"$os_name\", \"version\": \"$os_version\"}"
    else
        os_name=$(cat /etc/os-release 2>/dev/null | grep "^NAME=" | cut -d'"' -f2 || echo "")
        os_version=$(cat /etc/os-release 2>/dev/null | grep "^VERSION=" | cut -d'"' -f2 || echo "")
        os_info="{\"name\": \"$os_name\", \"version\": \"$os_version\"}"
    fi

    # Get open ports
    if [ "$OS" = "Darwin" ]; then
        # macOS ports using netstat - filter out wildcards and extract only port numbers
        tcp_ports=$(netstat -an | grep LISTEN | awk '{print $4}' | awk -F: '{print $NF}' | grep -v '^\*$' | grep -v '^\*\.\*$' | sort -n | uniq | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        udp_ports=$(netstat -an | grep udp | awk '{print $4}' | awk -F: '{print $NF}' | grep -v '^\*$' | grep -v '^\*\.\*$' | sort -n | uniq | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        
        # Handle empty port arrays
        if [ -z "$tcp_ports" ]; then
            tcp_ports=""
        fi
        if [ -z "$udp_ports" ]; then
            udp_ports=""
        fi
        
        ports_info="{\"tcp\": [$tcp_ports], \"udp\": [$udp_ports]}"
    else
        # Linux ports using ss command
        if ! command -v ss >/dev/null 2>&1; then
            echo "Warning: ss command not found" >&2
            ports_info="{\"error\": \"ss command not found\"}"
        else
            tcp_ports=$(ss -tln | awk 'NR>1 {split($4,a,":"); print "\""a[length(a)]"\""}' | sort -n | tr '\n' ',' | sed 's/,$//')
            udp_ports=$(ss -uln | awk 'NR>1 {split($4,a,":"); print "\""a[length(a)]"\""}' | sort -n | tr '\n' ',' | sed 's/,$//')
            
            # Handle empty port arrays
            if [ -z "$tcp_ports" ]; then
                tcp_ports=""
            fi
            if [ -z "$udp_ports" ]; then
                udp_ports=""
            fi
            
            ports_info="{\"tcp\": [$tcp_ports], \"udp\": [$udp_ports]}"
        fi
    fi

    # Get RAM slots info
    if [ "$OS" = "Darwin" ]; then
        ram_slots="{\"error\": \"RAM slots info not available on macOS\"}"
    else
        if ! command -v dmidecode >/dev/null 2>&1; then
            echo "Warning: dmidecode command not found" >&2
            ram_slots="{\"error\": \"dmidecode command not found\"}"
        else
            ram_slots=$(dmidecode -t memory | grep -c "^Memory Device$")
            ram_slots="{\"total_slots\": $ram_slots}"
        fi
    fi

    # Get IP addresses
    if [ "$OS" = "Darwin" ]; then
        # macOS IP addresses - filter out loopback and extract only IP addresses
        ipv4_addresses=$(ifconfig | grep "inet " | awk '{print $2}' | grep -v '^127\.' | grep -v '^169\.254\.' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        ipv6_addresses=$(ifconfig | grep "inet6 " | awk '{print $2}' | grep -v '^::1$' | grep -v '^fe80:' | awk '{print "\""$1"\""}' | tr '\n' ',' | sed 's/,$//')
        # Handle empty arrays
        if [ -z "$ipv4_addresses" ]; then
            ipv4_addresses=""
        fi
        if [ -z "$ipv6_addresses" ]; then
            ipv6_addresses=""
        fi
        ip_info="{\"ipv4\": [$ipv4_addresses], \"ipv6\": [$ipv6_addresses]}"
    else
        # Linux IP addresses
        if ! command -v ip >/dev/null 2>&1; then
            echo "Warning: ip command not found" >&2
            ip_info="{\"error\": \"ip command not found\"}"
        else
            ipv4_addresses=$(ip -4 addr show | awk '/inet / {print "\""$2"\""}' | tr '\n' ',' | sed 's/,$//')
            ipv6_addresses=$(ip -6 addr show | awk '/inet6/ {print "\""$2"\""}' | tr '\n' ',' | sed 's/,$//')
            # Handle empty arrays
            if [ -z "$ipv4_addresses" ]; then
                ipv4_addresses=""
            fi
            if [ -z "$ipv6_addresses" ]; then
                ipv6_addresses=""
            fi
            ip_info="{\"ipv4\": [$ipv4_addresses], \"ipv6\": [$ipv6_addresses]}"
        fi
    fi

    # Get CPU info
    if [ "$OS" = "Darwin" ]; then
        # macOS CPU info
        cpu_info="{\"architecture\": \"$(uname -m)\", \"model\": \"$(sysctl -n machdep.cpu.brand_string)\", \"cores\": \"$(sysctl -n hw.ncpu)\"}"
    else
        # Linux CPU info
        if ! command -v lscpu >/dev/null 2>&1; then
            echo "Warning: lscpu command not found" >&2
            cpu_info="{\"error\": \"lscpu command not found\"}"
        else
            if ! lscpu -J >/dev/null 2>&1; then
                cpu_info="{\"error\": \"lscpu JSON output not supported\"}"
            else
                cpu_info=$(lscpu -J)
            fi
        fi
    fi

    # Get memory info
    if [ "$OS" = "Darwin" ]; then
        # macOS memory info
        total_mem=$(sysctl -n hw.memsize)
        vm_stat_output=$(vm_stat)
        free_mem=$(echo "$vm_stat_output" | grep "Pages free:" | awk '{print $3}' | sed 's/\.//')
        free_mem=$((free_mem * 4096))  # Convert pages to bytes
        used_mem=$((total_mem - free_mem))
        memory_info="{\"total\": \"$total_mem\", \"used\": \"$used_mem\", \"free\": \"$free_mem\", \"shared\": \"0\", \"buffers\": \"0\", \"cache\": \"0\", \"total_slots\": 0}"
    else
        # Linux memory info
        if ! command -v free >/dev/null 2>&1; then
            echo "Warning: free command not found" >&2
            memory_info="{\"error\": \"free command not found\", \"total_slots\": 0}"
        else
            memory_info="{\"total\": \"$(free -b | awk 'NR==2 {print $2}')\", \"used\": \"$(free -b | awk 'NR==2 {print $3}')\", \"free\": \"$(free -b | awk 'NR==2 {print $4}')\", \"shared\": \"$(free -b | awk 'NR==2 {print $5}')\", \"buffers\": \"$(free -b | awk 'NR==2 {print $6}')\", \"cache\": \"$(free -b | awk 'NR==2 {print $7}')\", \"total_slots\": $ram_slots}"
        fi
    fi

    # Escape special characters in hostname
    hostname=$(hostname | sed 's/"/\\"/g')

    cat << EOF
{
    "agent_version": "$VERSION",
    "uuid": "$UUID",
    "timestamp": "$(date)",
    "os_info": $os_info,
    "ports_info": $ports_info,
    "ip_info": $ip_info,
    "hostname": "$hostname",
    "cpu_info": $cpu_info,
    "memory_info": $memory_info,
    "disk_info": {
        "filesystems": [$(df -P | awk 'NR>1 {gsub(/"/,"\\\"", $1); gsub(/"/,"\\\"", $6); printf "%s{\"filesystem\":\"%s\",\"total\":%s,\"used\":%s,\"available\":%s,\"use_percent\":%d,\"mounted_on\":\"%s\"}", (NR==2)?"":",", $1, $2*1024, $3*1024, $4*1024, $5+0, $6}')]
    },
    "processes": [$(ps aux --no-headers 2>/dev/null | awk '{
        gsub(/"/,"\\\"", $1);
        gsub(/"/,"\\\"", $11);
        printf "%s{\"user\":\"%s\",\"pid\":%s,\"cpu\":%.1f,\"mem\":%.1f,\"vsz\":%s,\"rss\":%s,\"tty\":\"%s\",\"stat\":\"%s\",\"start\":\"%s\",\"time\":\"%s\",\"command\":\"%s\"}",
        (NR==1)?"":",", $1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11
    }' || echo "")],
    "users_info": $users_info,
    "groups_info": $groups_info
}
EOF
}

send_snapshot() {
    snapshot=$1
    api_url=${API_COLLECTOR_URL}

    # Wrap snapshot data in a "data" field
    payload="{\"data\": $snapshot}"

    response=$(curl -s -X POST \
        -H "Content-Type: application/json" \
        -H "X-Agent-ID: $UUID" \
        -H "x-api-key: $TOKEN" \
        -d "$payload" \
        "$api_url")

    echo "$response"
}

init() {
    validate_params
    check_os
    mkdir -p "$DATA_FOLDER"
    UUID=$(generate_uuid)
}

collect_data_and_send() {
    timestamp=$(date +%Y%m%d_%H%M%S)

    echo "Generating snapshot..."
    snapshot_json=$(generate_snapshot)

    echo "$snapshot_json" > "$DATA_FOLDER/${timestamp}.json"

    echo "Sending snapshot to API..."
    response=$(send_snapshot "$snapshot_json")
    
    # Save API response to file
    echo "$response" > "$DATA_FOLDER/${timestamp}_response.json"
}

clear_old_snapshots() {
    echo "Clearing old snapshots..."
    find "$DATA_FOLDER" -type f -name "*.json" -mtime +$SNAPSHOT_RETENTION_DAYS -exec rm {} \;    
    echo "Old snapshots cleared successfully"
}

### Main scenario


init

echo "Agent started. Version: $VERSION"

while true; do
    collect_data_and_send
    clear_old_snapshots
    echo "Sleeping for $UPDATE_INTERVAL seconds..."
    sleep $UPDATE_INTERVAL
    echo "--------------------------------"
done
