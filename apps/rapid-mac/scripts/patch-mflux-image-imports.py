#!/usr/bin/env python3
"""Keep optional Z-Image ControlNet imports lazy in the pinned desktop runtime.

Plain Z-Image generation does not use OpenCV. mflux 0.19.0 nevertheless imports
ControlNet from its parent packages before the generation module can load.
Preserve those public exports, but resolve them only if explicitly requested.
Run before the sidecar's compile/trim/sign stages; unknown layouts fail closed.
"""
from __future__ import annotations

import argparse
from pathlib import Path

_EAGER = "from mflux.models.z_image.variants.controlnet import ZImageTurboControlnet\n"
_MARKER = "# Youzi: defer optional Z-Image ControlNet dependencies."
_LAZY = '''
# Youzi: defer optional Z-Image ControlNet dependencies.
def __getattr__(name):
    if name == "ZImageTurboControlnet":
        from mflux.models.z_image.variants.controlnet import ZImageTurboControlnet

        globals()[name] = ZImageTurboControlnet
        return ZImageTurboControlnet
    raise AttributeError(f"module {__name__!r} has no attribute {name!r}")
'''
_TARGETS = (
    "mflux/models/z_image/__init__.py",
    "mflux/models/z_image/variants/__init__.py",
    "mflux/models/z_image/variants/controlnet/__init__.py",
)


def patch(site_packages: Path) -> list[Path]:
    # Validate all targets before touching any: a version bump must not leave a
    # half-patched stage that an incremental packaging run might later reuse.
    updates = []
    for relative in _TARGETS:
        target = site_packages / relative
        source = target.read_text()
        eager, lazy = _EAGER, _LAZY
        if relative.endswith("/controlnet/__init__.py"):
            # ZImageInitializer imports the dependency-free ControlSpec type
            # through this package as well, so its heavy re-export must wait.
            eager = eager.replace("controlnet import", "controlnet.z_image_turbo_controlnet import")
            lazy = lazy.replace("controlnet import", "controlnet.z_image_turbo_controlnet import")
        if source.endswith(lazy) and eager.rstrip("\n") not in source.splitlines():
            continue
        if _MARKER in source or source.count(eager) != 1 or "def __getattr__(" in source:
            raise RuntimeError(f"Unexpected mflux package layout: {relative}; review the pinned runtime")
        updates.append((target, source.replace(eager, "", 1).rstrip() + "\n" + lazy))
    for target, source in updates:
        target.write_text(source)
    return [target for target, _ in updates]


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("site_packages", type=Path)
    args = parser.parse_args()
    for target in patch(args.site_packages):
        print(f"Deferred optional ControlNet import: {target.relative_to(args.site_packages)}")
