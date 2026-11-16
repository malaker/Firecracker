#!/bin/bash
# Benign test sample for the detonate recipe: does the three things the report must show
# (drops a file, starts a process, attempts a connection), then exits with code 7.
echo "FC-TEST-SAMPLE running"
echo payload > /tmp/dropped
id > /dev/null
timeout 3 bash -c 'exec 3<>/dev/tcp/203.0.113.5/443' 2>/dev/null
echo "contact http://203.0.113.5/beacon and /etc/passwd" > /dev/null
exit 7
