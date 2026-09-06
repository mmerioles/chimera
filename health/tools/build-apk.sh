set -uo pipefail
export ANDROID_HOME=/sdk
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq && apt-get install -y -qq unzip curl >/dev/null 2>&1

if [ ! -d /sdk/cmdline-tools/latest ]; then
  mkdir -p /sdk/cmdline-tools
  curl -sL https://dl.google.com/android/repository/commandlinetools-linux-11076708_latest.zip -o /tmp/c.zip
  unzip -q /tmp/c.zip -d /sdk/cmdline-tools
  mv /sdk/cmdline-tools/cmdline-tools /sdk/cmdline-tools/latest
fi

# Accept licences by writing the hashes. `yes | sdkmanager --licenses`
# deadlocks when stdout is not a tty.
mkdir -p /sdk/licenses
echo "24333f8a63b6825ea9c5514f83c2829b004d1fee" > /sdk/licenses/android-sdk-license
echo "84831b9409646a918e30573bab4c9c91346d8abd" > /sdk/licenses/android-sdk-preview-license
echo "d975f751698a77b662f1254ddbeed3901e976f5a" > /sdk/licenses/intel-android-extra-license

echo ">>> installing sdk packages"
/sdk/cmdline-tools/latest/bin/sdkmanager --no_https "platform-tools" "platforms;android-35" "build-tools;35.0.0" < /dev/null 2>&1 | tail -3

if [ ! -d /opt/gradle-8.10.2 ]; then
  curl -sL https://services.gradle.org/distributions/gradle-8.10.2-bin.zip -o /tmp/g.zip
  unzip -q /tmp/g.zip -d /opt
fi

echo ">>> building"
cd /src
/opt/gradle-8.10.2/bin/gradle assembleDebug --no-daemon < /dev/null 2>&1 | grep -E "What went wrong|error:|FAILED|BUILD SUCCESSFUL|^> " | head -25
find /src -name '*.apk' 2>/dev/null
