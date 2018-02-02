#!/bin/bash
echo "[*] Compiling sajlbrk.."
$(which xcodebuild) clean build CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" -sdk `xcrun --sdk iphoneos --show-sdk-path` -arch arm64
mv build/Release-iphoneos/sajlbrk.app sajlbrk.app
mkdir Payload
mv sajlbrk.app Payload/sajlbrk.app
echo "[*] Zipping into .ipa"
zip -r9 sajlbrk.ipa Payload/sajlbrk.app
rm -rf build Payload
echo "[*] Done! Install .ipa with Impactor"
