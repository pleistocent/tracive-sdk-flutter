#!/bin/sh
# A define file reaches Xcode only as DART_DEFINES, a comma list of base64 entries, and Info.plist
# cannot decode that. So an override of the redirect scheme is written into the built plist.
set -eu

scheme=""
for entry in $(echo "${DART_DEFINES:-}" | tr ',' ' '); do
  define=$(echo "$entry" | base64 --decode)
  case "$define" in
    TRACIVE_REDIRECT_SCHEME=*) scheme=${define#*=} ;;
  esac
done

[ -n "$scheme" ] || exit 0
/usr/libexec/PlistBuddy -c "Set :CFBundleURLTypes:0:CFBundleURLSchemes:0 $scheme" \
  "$TARGET_BUILD_DIR/$INFOPLIST_PATH"
