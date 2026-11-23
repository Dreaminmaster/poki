#!/usr/bin/env python3
"""Check the built app and its extensions against the selected release."""

import plistlib
import re
import sys
import zipfile


def verify(path, version, build):
    app = "Payload/Poki.app/Info.plist"
    extension = re.compile(r"Payload/Poki\.app/PlugIns/[^/]+\.appex/Info\.plist")
    with zipfile.ZipFile(path) as ipa:
        plists = [name for name in ipa.namelist() if name == app or extension.fullmatch(name)]
        if app not in plists or len(set(plists)) != len(plists):
            raise ValueError("Expected one main app Info.plist and no duplicate bundle Info.plists")
        for name in plists:
            info = plistlib.loads(ipa.read(name))
            for key, expected in (("CFBundleShortVersionString", version), ("CFBundleVersion", build)):
                actual = info.get(key)
                if actual != expected:
                    raise ValueError(f"{name} {key} is {actual!r}; expected {expected!r}")


if __name__ == "__main__":
    try:
        verify(*sys.argv[1:])
    except (ValueError, zipfile.BadZipFile) as error:
        sys.exit(str(error))
