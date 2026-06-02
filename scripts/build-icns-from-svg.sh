#!/bin/zsh

set -euo pipefail

if [[ $# -ne 2 ]]; then
    echo "Usage: $0 <source.svg> <output.icns>" >&2
    exit 1
fi

SOURCE_SVG="$1"
OUTPUT_ICNS="$2"
WORK_DIR="$(mktemp -d "${TMPDIR:-/tmp}/plextray-icon.XXXXXX")"

trap 'rm -rf "$WORK_DIR"' EXIT

if [[ ! -f "$SOURCE_SVG" ]]; then
    echo "Could not find app icon source: $SOURCE_SVG" >&2
    exit 1
fi

if ! command -v vips >/dev/null; then
    echo "vips is required to generate the app icon from $SOURCE_SVG" >&2
    exit 1
fi

typeset -A icon_sizes=(
    icp4 16
    icp5 32
    ic07 128
    ic08 256
    ic09 512
    ic10 1024
)

for icon_type size in ${(kv)icon_sizes}; do
    vips thumbnail "$SOURCE_SVG" "$WORK_DIR/$icon_type.png" "$size" --height "$size" --size force
done

ICON_WORK_DIR="$WORK_DIR" OUTPUT_ICNS="$OUTPUT_ICNS" ruby <<'RUBY'
chunks = %w[icp4 icp5 ic07 ic08 ic09 ic10].map do |icon_type|
  data = File.binread(File.join(ENV.fetch("ICON_WORK_DIR"), "#{icon_type}.png"))
  [icon_type, [data.bytesize + 8].pack("N"), data].join
end.join

File.binwrite(ENV.fetch("OUTPUT_ICNS"), ["icns", chunks.bytesize + 8].pack("a4N") + chunks)
RUBY

