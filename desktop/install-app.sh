#!/usr/bin/env bash
#
# Install (or remove) the NTS Radio launcher entry.
#
# The plugin itself is a shell plugin, not an application — it has no binary to
# run and nothing to install system-wide. What this adds is a desktop entry so
# the browser window can be summoned the way any other app is: from the Omarchy
# menu (SUPER + SPACE, or SUPER + ALT + SPACE for apps), or from any launcher
# that reads XDG desktop entries.
#
# Everything lands under $HOME. Nothing here needs root.
#
#   ./desktop/install-app.sh
#   ./desktop/install-app.sh --remove

set -euo pipefail

here=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)

data_home=${XDG_DATA_HOME:-$HOME/.local/share}
apps_dir="$data_home/applications"
icon_png_dir="$data_home/icons/hicolor/256x256/apps"
icon_svg_dir="$data_home/icons/hicolor/scalable/apps"

desktop_file="$apps_dir/nts-radio.desktop"
icon_png="$icon_png_dir/nts-radio.png"
icon_svg="$icon_svg_dir/nts-radio.svg"

refresh() {
  # Both are best-effort: the entry works without either, they just make it
  # show up without waiting for a cache to expire.
  command -v update-desktop-database >/dev/null 2>&1 &&
    update-desktop-database "$apps_dir" >/dev/null 2>&1 || true
  command -v gtk-update-icon-cache >/dev/null 2>&1 &&
    gtk-update-icon-cache -qtf "$data_home/icons/hicolor" >/dev/null 2>&1 || true
}

if [[ ${1:-} == "--remove" ]]; then
  rm -f "$desktop_file" "$icon_png" "$icon_svg"
  refresh
  echo "Removed the NTS Radio launcher entry."
  exit 0
fi

mkdir -p "$apps_dir" "$icon_png_dir" "$icon_svg_dir"
install -m 644 "$here/nts-radio.desktop" "$desktop_file"
install -m 644 "$here/nts-radio.png" "$icon_png"
install -m 644 "$here/nts-radio.svg" "$icon_svg"
refresh

echo "Installed:"
echo "  $desktop_file"
echo "  $icon_png"
echo "  $icon_svg"
echo
echo "Find it as \"NTS Radio\" in the Omarchy menu (SUPER + SPACE)."
echo
echo "It opens as an ordinary tiled window — it moves between workspaces and"
echo "answers your window bindings like anything else."
