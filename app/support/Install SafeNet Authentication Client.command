#!/bin/bash
set -euo pipefail

URL='https://installer.id.ee/media/etoken/SAC%2010.9%20R1%20GA%20MAC.zip'
SHA256='238af9bdc2396d7408884ac663045ce383df61b22a7ac2223aeb6a34060ca441'
DEST="$HOME/Downloads/SAC-10.9-R1-GA-MAC.zip"
WORK="$HOME/Downloads/SafeNet Authentication Client 10.9"

printf 'ProKlik dependency installer\n'
printf 'SafeNet Authentication Client is licensed Thales software.\n'
printf 'The installer will show its license before installation.\n\n'

mkdir -p "$HOME/Downloads" "$WORK"

if [[ ! -f "$DEST" ]]; then
    printf 'Downloading SafeNet Authentication Client 10.9 (about 83 MB)...\n'
    curl -L --fail --progress-bar "$URL" -o "$DEST"
fi

printf 'Verifying download...\n'
ACTUAL=$(shasum -a 256 "$DEST" | awk '{print $1}')
if [[ "$ACTUAL" != "$SHA256" ]]; then
    printf 'Checksum mismatch. Deleting the downloaded file and trying again...\n' >&2
    rm -f "$DEST"
    curl -L --fail --progress-bar "$URL" -o "$DEST"
    ACTUAL=$(shasum -a 256 "$DEST" | awk '{print $1}')
    [[ "$ACTUAL" == "$SHA256" ]] || {
        printf 'The download still failed verification: %s\n' "$ACTUAL" >&2
        exit 1
    }
fi

printf 'Extracting installer...\n'
unzip -q -o "$DEST" -d "$WORK"

DMG=$(find "$WORK" -type f -name '*rev A_SafeNetAuthenticationClient.10.9.4565.0.dmg' -print -quit)
if [[ -z "$DMG" ]]; then
    printf 'Could not find the SafeNet installer DMG after extraction.\n' >&2
    exit 1
fi

printf '\nInstaller ready: %s\n' "$DMG"
if [[ "${PROKLIK_SAC_SKIP_OPEN:-0}" == "1" ]]; then
    printf 'Skipping automatic open because PROKLIK_SAC_SKIP_OPEN=1.\n'
else
    printf 'Opening the SafeNet Authentication Client installer.\n'
    printf 'Install “SafeNet Authentication Client 10.9.pkg”, then reopen ProKlik.\n'
    open "$DMG"
fi
