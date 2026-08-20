#!/usr/bin/env bash
# Syntax-check every helper in this directory without executing any of them.
set -Eeuo pipefail

HERE=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
cd "$HERE"

for script in *.sh; do
  bash -n "$script"
  echo "shell syntax OK: $script"
done

for module in *.py; do
  python3 -c "import ast,sys; ast.parse(open(sys.argv[1]).read())" "$module"
  echo "python syntax OK: $module"
done

echo SYNTAX_CHECK_PASSED
