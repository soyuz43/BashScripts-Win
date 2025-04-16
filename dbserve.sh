#!/bin/bash

# Initialize variables
json_server_pid=""
react_server_pid=""
json_server_dir=""
react_server_dir=""
tmp_dir="/tmp"
json_log_file="$tmp_dir/jserve.log"
react_log_file="$tmp_dir/react_server.log"
original_dir="$PWD"

# Function to find file recursively starting from current directory
find_file() {
    local file_name="$1"
    local search_dir="$PWD"
    local max_depth=10  # Prevent excessive searching
    local depth=0

    while [ $depth -lt $max_depth ]; do
        found_path=$(find "$search_dir" -name "$file_name" -type f -print -quit 2>/dev/null)
        if [ -n "$found_path" ]; then
            echo "$(dirname "$found_path")"
            return 0
        fi
        if [ "$search_dir" = "/" ]; then
            break
        fi
        search_dir="$(dirname "$search_dir")"
        ((depth++))
    done
    return 1
}

# Recursive kill: kills a process and all its child processes without relying on pgrep.
kill_tree() {
    local parent_pid="$1"
    # Use ps and awk to get child PIDs
    local children
    children=$(ps -eo pid,ppid | awk -v ppid="$parent_pid" '$2==ppid { print $1 }')
    for child in $children; do
        kill_tree "$child"
    done
    kill "$parent_pid" 2>/dev/null
}

# Function to kill process safely; for React server, kill its entire process tree
kill_process() {
    local pid="$1"
    local process_name="$2"

    if [ -n "$pid" ] && ps -p "$pid" > /dev/null; then
        echo "Shutting down $process_name (PID: $pid)..."
        if [ "$process_name" = "React server" ]; then
            kill_tree "$pid"
        else
            kill "$pid" 2>/dev/null
        fi

        # Wait for process to terminate (give it 5 seconds)
        for i in {1..5}; do
            if ! ps -p "$pid" > /dev/null; then
                echo "Process $pid terminated successfully."
                return 0
            fi
            sleep 1
        done

        # Force kill if still running
        if ps -p "$pid" > /dev/null; then
            echo "Process $pid not responding. Force killing..."
            if [ "$process_name" = "React server" ]; then
                kill -9 "$pid" 2>/dev/null
                kill_tree "$pid"
            else
                kill -9 "$pid" 2>/dev/null
            fi
            sleep 1
            if ! ps -p "$pid" > /dev/null; then
                echo "Process $pid forcefully terminated."
                return 0
            else
                echo "Failed to terminate process $pid."
                return 1
            fi
        fi
    elif [ -n "$pid" ]; then
        echo "Process $pid already terminated."
        return 0
    fi
}

# New function to aggressively kill Vite/React dev processes
kill_vite_server() {
    echo "Ensuring Vite/React dev server is shut down..."
    # Kill processes that include 'vite' in their command line
    pkill -f "vite" 2>/dev/null
    # Kill processes started by npm run dev that might not be caught otherwise
    pkill -f "node.*dev" 2>/dev/null

    # Check if port 5173 is still in use and kill whatever is using it
    local pid
    pid=$(lsof -ti:5173 2>/dev/null)
    if [ -n "$pid" ]; then
        echo "Found process still using port 5173 (PID: $pid), terminating..."
        kill -9 "$pid" 2>/dev/null
    fi
}

# Function to clean up and exit
cleanup() {
    kill_process "$json_server_pid" "JSON server"
    kill_process "$react_server_pid" "React server"
    kill_vite_server
    pkill -f "json-server" 2>/dev/null
    pkill -f "npm run dev" 2>/dev/null
    echo "All processes terminated. Exiting."
    cd "$original_dir" || true
    exit 0
}

# Handle unexpected exits
trap cleanup SIGINT SIGTERM EXIT

# Function to verify if a port is in use
check_port_in_use() {
    local port=$1
    local timeout=3  
    local start_time=$(date +%s)
    local retry_interval=0.2  # Check more frequently (5 times per second)

    while [ $(($(date +%s) - start_time)) -lt $timeout ]; do
        if command -v netstat &>/dev/null; then
            if netstat -atn | grep "LISTEN" | grep -q ":$port "; then
                return 0
            fi
        elif command -v ss &>/dev/null; then
            if ss -ltn | grep -q ":$port "; then
                return 0
            fi
        elif command -v lsof &>/dev/null; then
            if lsof -i ":$port" | grep -q "LISTEN"; then
                return 0
            fi
        fi
        if (echo > /dev/tcp/localhost/$port) 2>/dev/null; then
            return 0
        fi
        sleep $retry_interval
    done
    return 1
}

# Function to start JSON server
start_json_server() {
    if [ -z "$json_server_dir" ]; then
        echo "Error: JSON server directory not specified."
        return 1
    fi
    cd "$json_server_dir" || return 1
    echo "Starting JSON server in $(pwd)"
    rm -f "$json_log_file"
    export PATH="$PATH:$HOME/.npm-global/bin:$HOME/node_modules/.bin:./node_modules/.bin:$json_server_dir/node_modules/.bin"
    if [ ! -f "database.json" ]; then
        echo "Error: database.json not found in current directory."
        return 1
    fi
    if command -v json-server &>/dev/null; then
        nohup json-server --watch database.json -p 8088 &> "$json_log_file" &
        json_server_pid=$!
        echo "Started json-server with PID: $json_server_pid"
    elif [ -f "./node_modules/.bin/json-server" ]; then
        nohup ./node_modules/.bin/json-server --watch database.json &> "$json_log_file" &
        json_server_pid=$!
        echo "Started local json-server with PID: $json_server_pid"
    elif command -v npx &>/dev/null; then
        nohup npx json-server --watch database.json &> "$json_log_file" &
        json_server_pid=$!
        echo "Started json-server via npx with PID: $json_server_pid"
    else
        echo "Error: json-server command not found. Please install it with npm install -g json-server."
        return 1
    fi
    sleep 2
    if ! ps -p "$json_server_pid" > /dev/null 2>&1; then
        echo "Error: JSON server process failed to start."
        echo "=== JSON server log excerpt ==="
        tail -10 "$json_log_file" 2>/dev/null
        echo "=============================="
        return 1
    fi
    echo "Waiting for JSON server to be ready..."
    if ! check_port_in_use 3000; then
        if ! check_port_in_use 3001; then
            echo "Warning: JSON server may not be running properly on ports 3000 or 3001."
            echo "=== JSON server log excerpt ==="
            tail -10 "$json_log_file" 2>/dev/null
            echo "=============================="
        else
            echo "JSON server is running on port 3001."
        fi
    else
        echo "JSON server is running on port 3000."
    fi
    return 0
}

# Function to start React server
start_react_server() {
    if [ -z "$react_server_dir" ]; then
        echo "Error: React server directory not specified."
        return 1
    fi
    cd "$react_server_dir" || return 1
    echo "Starting React server in $(pwd)"
    rm -f "$react_log_file"
    export PATH="$PATH:$HOME/.npm-global/bin:$HOME/node_modules/.bin:./node_modules/.bin:$react_server_dir/node_modules/.bin"
    if [ ! -f "package.json" ]; then
        echo "Error: package.json not found in React project directory."
        return 1
    fi
    if ! grep -q '"dev"' package.json; then
        echo "Error: No 'dev' script found in package.json."
        return 1
    fi
    nohup npm run dev > "$react_log_file" 2>&1 &
    react_server_pid=$!
    sleep 2
    if ! ps -p "$react_server_pid" > /dev/null 2>&1; then
        echo "Error: Failed to start React server."
        echo "=== React server log excerpt ==="
        tail -20 "$react_log_file" 2>/dev/null
        echo "==============================="
        return 1
    fi
    echo "React server started with PID: $react_server_pid"
    echo "Waiting for React server to be ready..."
    local vite_ports="5173 3000 3001 4000 4173 8000 8080"
    local found_port=0
    for port in $vite_ports; do
        if check_port_in_use "$port"; then
            echo "React server is running on port $port."
            echo "You can access it at: http://localhost:$port"
            found_port=1
            break
        fi
    done
    if [ $found_port -eq 0 ]; then
        echo "Warning: Could not verify React server on any common port."
        echo "Check the log file for details: $react_log_file"
        echo "=== React server log excerpt ==="
        grep -A 5 "Local:" "$react_log_file" 2>/dev/null || tail -10 "$react_log_file" 2>/dev/null
        echo "==============================="
    fi
    return 0
}

# Function to restart both servers
restart_servers() {
    echo "Restarting servers..."
    kill_process "$json_server_pid" "JSON server"
    kill_process "$react_server_pid" "React server"
    pkill -f "json-server" 2>/dev/null
    pkill -f "npm run dev" 2>/dev/null
    json_server_pid=""
    react_server_pid=""
    if ! start_json_server; then
        echo "Error: Failed to restart JSON server."
        cleanup
        return 1
    fi
    if ! start_react_server; then
        echo "Error: Failed to restart React server."
        cleanup
        return 1
    fi
    return 0
}

# Main script execution starts here

# Step 1: Find database.json
json_server_dir=$(find_file "database.json")
if [ -z "$json_server_dir" ]; then
    echo "Error: No database.json found. Exiting."
    exit 1
fi

# Step 2: Start JSON server
if ! start_json_server; then
    cleanup
    exit 1
fi

# Step 3: Find React project (vite.config.js)
react_server_dir=$(find_file "vite.config.js")
if [ -z "$react_server_dir" ]; then
    echo "Error: No React project found. Shutting down JSON server and exiting."
    cleanup
    exit 1
fi

# Step 4: Start React development server
if ! start_react_server; then
    cleanup
    exit 1
fi

# Step 5: Interactive control panel
while true; do
    echo "Enter :q to quit or :r to restart:"
    read -r input
    case "$input" in
        ":q")
            echo "Shutting down servers..."
            cleanup
            break
            ;;
        ":r")
            if ! restart_servers; then
                break
            fi
            ;;
        *)
            echo "Invalid command. Use :q to quit or :r to restart."
            ;;
    esac
done

exit 0
