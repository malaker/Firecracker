#!/bin/sh
# Benign test sample: never ends by itself, and leaves a background process behind.
echo started > /tmp/sleeper-started
sleep 600 &
sleep 600
