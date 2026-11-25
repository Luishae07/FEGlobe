#!/bin/sh
# Builds Atlas.apk. Needs: ANDROID_HOME, GRADLE (a gradle program), ARCGIS_LICENSE,
# and ATLAS_KEYSTORE with ATLAS_KEYSTORE_PASSWORD (the signing key; keep it, updates need the same one).
# On the home server these have defaults.
set -e
cd "$(dirname "$0")"
export ANDROID_HOME="${ANDROID_HOME:-/media/data/android-sdk}"
export GRADLE_USER_HOME="${GRADLE_USER_HOME:-/media/data/android-sdk/gradle}"
GRADLE="${GRADLE:-/media/data/fullmapmod/gradle-9.8.2/bin/gradle}"
[ -n "$ARCGIS_LICENSE" ] || ARCGIS_LICENSE="$(cat /srv/secrets/arcgis_license)"
export ARCGIS_LICENSE
export ATLAS_KEYSTORE="${ATLAS_KEYSTORE:-/srv/secrets/atlas_android.keystore}"
[ -n "$ATLAS_KEYSTORE_PASSWORD" ] || ATLAS_KEYSTORE_PASSWORD="$(cat /srv/secrets/atlas_android.password)"
export ATLAS_KEYSTORE_PASSWORD
mkdir -p "$GRADLE_USER_HOME/tmp"
export JAVA_TOOL_OPTIONS="-Djava.io.tmpdir=$GRADLE_USER_HOME/tmp"
nice -n 15 "$GRADLE" assembleRelease --no-daemon --console=plain "$@"
ls -la app/build/outputs/apk/release/
