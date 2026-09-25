#!/bin/bash
set -e # Exit if one of commands exit with non-zero exit code
set -u # Treat unset variables and parameters other than the special parameters ‘@’ or ‘*’ as an error
set -o pipefail # Any command failed in the pipe fails the whole pipe
# set -x # Print shell commands as they are executed (or you can try -v which is less verbose)

# Don't forget to also update ./ShellParserGenerated/Package.swift
export antlr_version="4.13.1"

add-optional-dep-to-bin() {
    if /usr/bin/which "$1" &> /dev/null; then
        /bin/cat > ".deps/bin/${2:-$1}" <<EOF
#!/bin/bash
exec '$(/usr/bin/which "$1")' "\$@"
EOF
    fi
}

if /bin/test -z "${NUKE_PATH:-}"; then
    /bin/rm -rf .deps/bin
    /bin/mkdir -p .deps/bin

    add-optional-dep-to-bin bash not-outdated-bash # build-shell-completion.sh
    add-optional-dep-to-bin fish # build-shell-completion.sh
    add-optional-dep-to-bin rustc # build-shell-completion.sh
    add-optional-dep-to-bin cargo # build-shell-completion.sh
    add-optional-dep-to-bin brew # install-from-sources.sh
    add-optional-dep-to-bin bundle # build-docs.sh
    add-optional-dep-to-bin bundler # build-docs.sh
    add-optional-dep-to-bin xcbeautify # build-release.sh
    add-optional-dep-to-bin git
    add-optional-dep-to-bin swift
    add-optional-dep-to-bin swiftly

    export PATH="${PWD}/.deps/bin:/bin:/usr/bin:/sbin:/usr/sbin:/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin"
    chmod +x .deps/bin/*
    export NUKE_PATH=1
fi

# SwiftPM run through swiftly takes the default SDK, which follows the Command Line Tools. That SDK
# can be newer than the pinned toolchain supports, and it lacks the macro plugins that Xcode's
# platform ships (SwiftUI's @State is a macro in the macOS 27 SDK). Build against the selected
# developer directory's macOS SDK (Xcode's, when Xcode is selected) unless the caller chose one.
if /bin/test -z "${SDKROOT:-}"; then
    SDKROOT="$(/usr/bin/xcrun --sdk macosx --show-sdk-path 2> /dev/null || true)"
    if /bin/test -n "$SDKROOT"; then
        export SDKROOT
    else
        unset SDKROOT
        echo "warning: xcrun found no macOS SDK in the selected developer directory; SwiftPM picks its default" > /dev/stderr
    fi
fi

# The pinned Swift, read next to this script so a later cd doesn't lose it. zsh, when a developer
# sources this interactively, has no BASH_SOURCE but names the sourced file in $0.
winmux_pinned_swift="$(/bin/cat "$(/usr/bin/dirname "${BASH_SOURCE[0]:-$0}")/../.swift-version" 2> /dev/null || true)"

# True when `xcrun swift` is the pinned Swift: the selected Xcode's own, or the toolchain TOOLCHAINS
# names (swift --version prints an X.Y.0 release as X.Y). Call it only as a condition: setup.sh
# leaves errexit on in the caller.
selected_xcode_swift_is_pinned() {
    local actual
    actual="$(/usr/bin/xcrun swift --version 2> /dev/null |
        /usr/bin/sed -nE 's/.*Swift version ([0-9]+\.[0-9]+(\.[0-9]+)?)[ )].*/\1/p' || true)"
    /bin/test -n "$actual" && /bin/test -n "$winmux_pinned_swift" &&
        { /bin/test "$actual" = "$winmux_pinned_swift" || /bin/test "$actual.0" = "$winmux_pinned_swift"; }
}

swift() {
    # Build tests and the CLI with the same compiler as the Xcode Release app when `xcrun swift` is
    # the pinned Swift; otherwise select the pinned toolchain through swiftly.
    if selected_xcode_swift_is_pinned; then
        /usr/bin/xcrun swift "$@"
    elif /usr/bin/which swiftly &> /dev/null; then
        if /bin/test -z "$winmux_pinned_swift"; then
            echo "warning: no .swift-version next to script/setup.sh; using swiftly's default Swift" > /dev/stderr
        else
            echo "warning: xcrun swift isn't the pinned Swift $winmux_pinned_swift; using swiftly, so Xcode builds the app with a different compiler" > /dev/stderr
        fi
        swiftly run swift "$@"
    else
        echo "warning: swiftly is not installed. Fallback to plain swift. Swift compilation might not be reproducible" > /dev/stderr
        /usr/bin/env swift --version > /dev/stderr
        /usr/bin/env swift "$@"
    fi
}

xcodebuild-pretty() {
    log_file="$1"
    shift
    # Mute stderr
    # 2024-02-12 23:48:11.713 xcodebuild[60777:7403664] [MT] DVTAssertions: Warning in /System/Volumes/Data/SWE/Apps/DT/BuildRoots/BuildRoot11/ActiveBuildRoot/Library/Caches/com.apple.xbs/Sources/IDEFrameworks/IDEFrameworks-22269/IDEFoundation/Provisioning/Capabilities Infrastructure/IDECapabilityQuerySelection.swift:103
    # Details:  createItemModels creation requirements should not create capability item model for a capability item model that already exists.
    # Function: createItemModels(for:itemModelSource:)
    # Thread:   <_NSMainThread: 0x6000037202c0>{number = 1, name = main}
    # Please file a bug at https://feedbackassistant.apple.com with this warning message and any useful information you can provide.
    if /usr/bin/which xcbeautify &> /dev/null; then
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file" | xcbeautify --quiet # Only print tasks that have warnings or errors
        echo "The full unmodified xcodebuild log is saved to $log_file"
    else
        /usr/bin/xcrun xcodebuild "$@" 2>&1 | tee "$log_file"
    fi
}
