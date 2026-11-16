#!/bin/sh
# Fixture recipe: records what the controller uploaded.
. /work/.fc/recipe.env
{
  echo "recipe=$FC_RECIPE kind=$FC_RECIPE_SAMPLE_KIND sample=$FC_RECIPE_SAMPLE rules=$FC_RECIPE_RULES"
  echo "in: $(ls -A /work/in | tr '\n' ' ')"
  echo "rules: $(ls -A /work/rules 2>/dev/null | tr '\n' ' ')"
  echo "lib: $(cat /work/recipe/_lib/shared.txt)"
  echo "ifaces: $(ls /sys/class/net | tr '\n' ' ')"
  echo "cpus=$(nproc)"
} > /work/out/report.md
echo '{"recipe":"fx-echo"}' > /work/out/report.json
cat /work/out/report.md
