#!/bin/sh
# Execute the CLI inside the current app so Sparkle updates replace both together.
set -eu

launcher_path=$0
case "$launcher_path" in
    */*) ;;
    *) launcher_path=$(command -v "$launcher_path") ;;
esac

# Resolve links such as .local/install/current/bin/winmux before reading its config.
link_count=0
while [ -L "$launcher_path" ]; do
    link_count=$((link_count + 1))
    if [ "$link_count" -gt 40 ]; then
        printf '%s\n' 'winmux: too many launcher symbolic links' >&2
        exit 127
    fi
    launcher_directory=$(CDPATH= cd -- "$(dirname -- "$launcher_path")" && pwd -P)
    link_target=$(/usr/bin/readlink "$launcher_path")
    case "$link_target" in
        /*) launcher_path=$link_target ;;
        *) launcher_path=$launcher_directory/$link_target ;;
    esac
done
launcher_directory=$(CDPATH= cd -- "$(dirname -- "$launcher_path")" && pwd -P)

if [ "${WINMUX_APP_PATH+x}" = x ]; then
    app_path=$WINMUX_APP_PATH
elif [ -f "$launcher_directory/winmux-app-path" ]; then
    app_path=$(cat "$launcher_directory/winmux-app-path")
elif [ -d "$launcher_directory/../WinMux.app" ]; then
    app_path=$launcher_directory/../WinMux.app
else
    app_path=/Applications/WinMux.app
fi

case "$app_path" in
    /*) ;;
    *) printf '%s\n' 'winmux: the app path must be absolute and nonempty' >&2; exit 127 ;;
esac
case "$app_path" in
    *'
'*) printf '%s\n' 'winmux: the app path must contain a single line' >&2; exit 127 ;;
esac

bundled_cli=$app_path/Contents/MacOS/winmux
if [ ! -f "$bundled_cli" ] || [ ! -x "$bundled_cli" ]; then
    printf 'winmux: bundled CLI not found: %s\n' "$bundled_cli" >&2
    printf '%s\n' 'Install the matching fork app, or set WINMUX_APP_PATH to its absolute bundle path.' >&2
    exit 127
fi

exec "$bundled_cli" "$@"
