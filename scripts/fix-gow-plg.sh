#!/bin/bash
# fix-gow-plg.sh — repair gow.plg on Unraid flash (no python3 required)
# Fixes: Windows CRLF, bare & in CHANGES, INLINE single-quote bugs, unreleased tag URLs.
set -euo pipefail

PLG="${1:-/boot/config/plugins/gow.plg}"

[[ -f "$PLG" ]] || { echo "Missing: $PLG" >&2; exit 1; }

echo "==> Repairing $PLG"

sed -i 's/\r$//' "$PLG"

if ! grep -q '<CHANGES><!\[CDATA\[' "$PLG"; then
  perl -0777 -i -pe 's|<CHANGES>(.*?)</CHANGES>|<CHANGES><![CDATA[$1]]></CHANGES>|s' "$PLG"
  echo "    Wrapped <CHANGES> in CDATA"
fi

sed -i 's/config backup & restore/config backup \&amp; restore/' "$PLG"
sed -i "s/Install the 'Compose Manager' plugin/Install the Compose Manager plugin/" "$PLG"
sed -i 's/grep -v '\''&version;'\''/grep -v "\&version;"/' "$PLG"

echo "==> Sanity check"
grep -n '<CHANGES>\|<!ENTITY version\|backup &\|Compose Manager\|grep -v' "$PLG" | head -10 || true

echo "==> Done. Run: plugin install /boot/config/plugins/gow.plg"
