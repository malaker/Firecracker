#!/bin/sh
# Minimal payload: prints some facts about the sandbox and writes a result file.
echo "Hello from $(hostname), kernel $(uname -r)"
echo "Network interfaces: $(ip -o link | awk -F': ' '{print $2}' | tr '\n' ' ')"
id > out/whoami.txt
echo "wrote out/whoami.txt"
