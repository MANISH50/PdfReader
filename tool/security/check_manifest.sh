#!/usr/bin/env bash
# Fails if a built APK requests network/storage/tracking permissions or is debuggable.
# Usage: tool/security/check_manifest.sh build/app/outputs/flutter-apk/app-release.apk
set -euo pipefail

APK="${1:?usage: $0 path/to/app.apk}"
[ -f "$APK" ] || { echo "no such APK: $APK" >&2; exit 2; }

AAPT="${AAPT:-}"
if [ -z "$AAPT" ]; then
  SDK="${ANDROID_HOME:-${ANDROID_SDK_ROOT:-}}"
  [ -n "$SDK" ] || { echo "set ANDROID_HOME or AAPT" >&2; exit 2; }
  AAPT="$(ls -d "$SDK"/build-tools/*/aapt 2>/dev/null | sort -V | tail -1)"
fi
[ -x "$AAPT" ] || { echo "aapt not found (set AAPT)" >&2; exit 2; }

FORBIDDEN_RE='android\.permission\.(INTERNET|ACCESS_NETWORK_STATE|ACCESS_WIFI_STATE|CHANGE_WIFI_STATE|READ_EXTERNAL_STORAGE|WRITE_EXTERNAL_STORAGE|MANAGE_EXTERNAL_STORAGE|READ_MEDIA_[A-Z_]+|ACCESS_MEDIA_LOCATION|QUERY_ALL_PACKAGES|REQUEST_INSTALL_PACKAGES|ACCESS_(FINE|COARSE|BACKGROUND)_LOCATION|CAMERA|RECORD_AUDIO|READ_CONTACTS|READ_PHONE_STATE|READ_SMS|SYSTEM_ALERT_WINDOW|BLUETOOTH[A-Z_]*|NEARBY_WIFI_DEVICES)$|com\.google\.android\.gms\.permission\.AD_ID'

perms="$("$AAPT" dump permissions "$APK" | sed -n "s/^uses-permission: name='\([^']*\)'.*/\1/p")"
echo "Permissions in $(basename "$APK"):"
if [ -n "$perms" ]; then printf '  %s\n' $perms; else echo "  (none)"; fi

status=0
bad="$(printf '%s\n' "$perms" | grep -E "$FORBIDDEN_RE" || true)"
if [ -n "$bad" ]; then
  echo "FAIL: forbidden permissions:" >&2
  printf '  %s\n' $bad >&2
  status=1
fi

xml="$("$AAPT" dump xmltree "$APK" AndroidManifest.xml)"
if printf '%s\n' "$xml" | grep -Eq 'android:debuggable\([^)]*\)=\(type 0x12\)0xffffffff'; then
  echo "FAIL: APK is debuggable" >&2
  status=1
fi
if printf '%s\n' "$xml" | grep -Eq 'android:allowBackup\([^)]*\)=\(type 0x12\)0xffffffff'; then
  echo "WARN: android:allowBackup=true" >&2
fi
if printf '%s\n' "$xml" | grep -Eq 'android:usesCleartextTraffic\([^)]*\)=\(type 0x12\)0xffffffff'; then
  echo "FAIL: usesCleartextTraffic=true" >&2
  status=1
fi

[ $status -eq 0 ] && echo "OK: manifest passes offline/privacy checks."
exit $status
