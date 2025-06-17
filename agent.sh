#!/bin/bash

# Create directory if it doesn't exist

# Generate UUID
UUID=$(uuidgen)

# Get system information
# data_folder="/etc/adt-infra-hub-agent"
data_folder="./data"

mkdir -p "$data_folder"

echo "System Snapshot - $(date)" > "$data_folder/snapshot.log"
echo "-------------------" >> "$data_folder/snapshot.log"
echo "" >> "$data_folder/snapshot.log"

# CPU Information
echo "CPU Information:" >> "$data_folder/snapshot.log"
lscpu >> "$data_folder/snapshot.log"
echo "" >> "$data_folder/snapshot.log"

# Memory Information
echo "Memory Information:" >> "$data_folder/snapshot.log"
free -h >> "$data_folder/snapshot.log"
echo "" >> "$data_folder/snapshot.log"

# Active Processes
echo "Active Processes:" >> "$data_folder/snapshot.log"
ps aux | head -n 20 >> "$data_folder/snapshot.log"

# Create UUID file
echo "$UUID" > "$data_folder/$UUID"
