#!/usr/bin/env python3
"""Turn syft's scan of a rootfs into the SBOM that ships with an image.

syft finds what package managers recorded — dpkg, the boneIO venv, the Go
modules inside Caddy, the Alpine and npm packages inside the Docker images
baked into the rootfs. What it cannot see is what was put there without a
package manager knowing what it is, and those are exactly the parts with the
most CVEs:

- the kernel: the BeagleBoard package is ``linux-image-6.18.55-bone57`` at
  version ``1trixie``, which matches no advisory, and an ARM zImage carries no
  version string syft can read;
- U-Boot: ``bb-u-boot-am335x-evm`` comes from the BeagleBoard repository and
  no scanner maps it to U-Boot.

Both get a component with a CPE, the identifier vulnerability databases key
kernel and U-Boot advisories on. The document's root becomes the product —
firmware, with a supplier — and points at the application's own SBOM for the
frontend, which is a Vite bundle with no lockfile left to read on the device.

Usage:
    finalize_sbom.py <syft.cdx.json> <rootfs> <version> <output>
"""

from __future__ import annotations

import json
import re
import sys
import uuid
from pathlib import Path

SUPPLIER = {"name": "boneIO Sp. z o.o.", "url": ["https://boneio.eu"],
            "contact": [{"email": "security@boneio.eu"}]}
APP_SBOM = ("https://github.com/boneIO-eu/app_black/releases/download/"
            "v{version}/boneio-{version}.cdx.json")

# A truncated scan reads as an answer. These are present in every image built
# so far; if one goes missing, a cataloger failed rather than the package left.
EXPECTED = ("boneio", "python3.13", "openssl", "caddy", "mosquitto", "linux-kernel", "u-boot")
MIN_COMPONENTS = 500


def kernel(rootfs: Path) -> dict:
    """Describe the kernel from its module directory, the one place it is named."""
    release = next((rootfs / "lib/modules").iterdir()).name  # 6.18.55-bone57
    upstream = release.split("-")[0]
    # Spelled the way syft spells a kernel it does recognise. Grype skips
    # components typed operating-system (it reads them as the distro), so this
    # is an application, or the kernel's advisories never match.
    return {
        "type": "application", "bom-ref": f"linux-kernel@{release}",
        "name": "linux-kernel", "version": upstream,
        "description": f"BeagleBoard kernel {release}",
        "purl": f"pkg:generic/linux-kernel@{upstream}",
        "cpe": f"cpe:2.3:o:linux:linux_kernel:{upstream}:*:*:*:*:*:*:*",
        "properties": [{"name": "syft:package:type", "value": "linux-kernel"}],
        "licenses": [{"license": {"id": "GPL-2.0-only"}}],
    }


def u_boot(components: list[dict]) -> dict | None:
    """Describe U-Boot from the BeagleBoard package that carries it."""
    pkg = next((c for c in components if c["name"].startswith("bb-u-boot-")), None)
    if pkg is None:
        return None
    upstream = re.match(r"\d{4}\.\d{2}", pkg["version"]).group(0)  # 2022.04
    return {
        "type": "firmware", "bom-ref": f"u-boot@{pkg['version']}",
        "name": "u-boot", "version": upstream,
        "description": f"from {pkg['name']} {pkg['version']}",
        "cpe": f"cpe:2.3:a:denx:u-boot:{upstream}:*:*:*:*:*:*:*",
        "licenses": [{"license": {"id": "GPL-2.0-or-later"}}],
    }


def finalize(bom: dict, rootfs: Path, version: str) -> dict:
    """Return *bom* with the product as root and the unscannable parts added."""
    comps = bom["components"]
    added = [c for c in (kernel(rootfs), u_boot(comps)) if c]
    comps += added

    for c in comps:
        if c["name"] == "boneio" and c.get("purl", "").startswith("pkg:pypi/"):
            c.setdefault("externalReferences", []).append(
                {"type": "bom", "url": APP_SBOM.format(version=version),
                 "comment": "application SBOM, including the web frontend"})

    root = bom["metadata"]["component"]
    root.update(type="firmware", name="boneIO Black", version=version,
                supplier=SUPPLIER)
    bom["metadata"]["manufacturer"] = SUPPLIER
    bom["metadata"]["supplier"] = SUPPLIER
    bom["serialNumber"] = f"urn:uuid:{uuid.uuid4()}"
    # Without this the added components hang off nothing.
    bom.setdefault("dependencies", []).append(
        {"ref": root["bom-ref"], "dependsOn": [c["bom-ref"] for c in added]})
    return bom


def check(bom: dict) -> None:
    """Refuse a document too thin to answer 'is this version affected'."""
    names = {c["name"] for c in bom["components"]}
    missing = [n for n in EXPECTED if n not in names]
    assert not missing, f"missing from the inventory: {missing}"
    assert len(bom["components"]) >= MIN_COMPONENTS, \
        f"only {len(bom['components'])} components — a cataloger failed"


def main() -> None:
    src, rootfs, version, out = sys.argv[1:5]
    bom = finalize(json.loads(Path(src).read_text()), Path(rootfs), version)
    check(bom)
    Path(out).write_text(json.dumps(bom, indent=1) + "\n")
    print(f"{out}: {len(bom['components'])} components")


if __name__ == "__main__":
    main()
