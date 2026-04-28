#!/usr/bin/env bash
# Script for workers to play the game interactively on their Pis

echo -e "\033[1;36m╔══════════════════════════════════════╗\033[0m"
echo -e "\033[1;36m║          MPI NUMBER GAME             ║\033[0m"
echo -e "\033[1;36m╚══════════════════════════════════════╝\033[0m"

# Clean up any old files
rm -f /tmp/my_number.txt /tmp/result.txt

while true; do
    read -rp "Enter your guess (1-100): " NUM
    if [[ "$NUM" =~ ^[0-9]+$ ]] && (( NUM >= 1 && NUM <= 100 )); then
        echo "$NUM" > /tmp/my_number.txt
        break
    fi
    echo -e "\033[0;31mInvalid!\033[0m Please enter a number between 1 and 100."
done

echo -e "\n\033[1;33mWaiting for Master to announce the winner...\033[0m"

# Wait for the game binary to write the result
while [ ! -f /tmp/result.txt ]; do
    sleep 0.5
done

# Print the result!
cat /tmp/result.txt
echo ""
