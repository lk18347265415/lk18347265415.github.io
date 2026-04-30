#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

for dot_file in "${ROOT_DIR}"/*.dot; do
    png_file="${dot_file%.dot}.png"
    dot -Tpng "${dot_file}" -o "${png_file}"
done
