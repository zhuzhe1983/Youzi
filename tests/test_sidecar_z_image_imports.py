"""Regression: no optional OpenCV import for the desktop Z-Image lane."""
from __future__ import annotations

import importlib.util
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).parents[1]
SCRIPT = ROOT / "apps/rapid-mac/scripts/patch-mflux-image-imports.py"
SPEC = importlib.util.spec_from_file_location("patch_mflux_image_imports", SCRIPT)
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def _fake_mflux(root: Path) -> None:
    # The actual pinned parent exports, with dependency-free stand-ins for the
    # heavy generation classes. ControlNet deliberately fails without cv2.
    sources = {
        "mflux/__init__.py": "",
        "mflux/models/__init__.py": "",
        "mflux/models/z_image/__init__.py": (
            "from mflux.models.z_image.variants import ZImage, ZImageTurbo\n"
            + MODULE._EAGER
            + 'from mflux.models.z_image.z_image_initializer import ZImageInitializer\n'
            + '__all__ = ["ZImage", "ZImageTurbo", "ZImageTurboControlnet", "ZImageInitializer"]\n'
        ),
        "mflux/models/z_image/variants/__init__.py": (
            MODULE._EAGER
            + "from mflux.models.z_image.variants.z_image import ZImage\n"
            + 'ZImageTurbo = ZImage\n__all__ = ["ZImage", "ZImageTurbo", "ZImageTurboControlnet"]\n'
        ),
        "mflux/models/z_image/variants/z_image.py": "class ZImage: pass\n",
        "mflux/models/z_image/z_image_initializer.py": "from mflux.models.z_image.variants.controlnet.control_types import ControlSpec\nclass ZImageInitializer: pass\n",
        "mflux/models/z_image/variants/controlnet/__init__.py": (
            "from mflux.models.z_image.variants.controlnet.control_types import ControlSpec, ControlType\n"
            + MODULE._EAGER.replace("controlnet import", "controlnet.z_image_turbo_controlnet import")
            + '__all__ = ["ControlSpec", "ControlType", "ZImageTurboControlnet"]\n'
        ),
        "mflux/models/z_image/variants/controlnet/control_types.py": "class ControlSpec: pass\nclass ControlType: pass\n",
        "mflux/models/z_image/variants/controlnet/z_image_turbo_controlnet.py": (
            "raise ModuleNotFoundError(\"No module named 'cv2'\", name='cv2')\n"
        ),
    }
    for name, source in sources.items():
        file = root / name
        file.parent.mkdir(parents=True, exist_ok=True)
        file.write_text(source)


def test_plain_generation_imports_without_controlnet_but_export_stays_lazy(tmp_path):
    _fake_mflux(tmp_path)
    assert len(MODULE.patch(tmp_path)) == 3
    assert MODULE.patch(tmp_path) == []  # safe to rerun on local runtime repair
    code = '''
import sys
sys.path.insert(0, sys.argv[1])
from mflux.models.z_image.variants.z_image import ZImage
from mflux.models.z_image import ZImageTurbo, ZImageInitializer
import mflux.models.z_image as package
import mflux.models.z_image.variants as variants
assert ZImage is ZImageTurbo
assert not any(x in sys.modules for x in ('cv2', 'torch', 'matplotlib'))
assert 'mflux.models.z_image.variants.controlnet.z_image_turbo_controlnet' not in sys.modules
for module in (package, variants):
    assert 'ZImageTurboControlnet' in module.__all__
    assert not hasattr(module, 'nonexistent')
    try:
        module.ZImageTurboControlnet
    except ModuleNotFoundError as e:
        assert e.name == 'cv2'
    else:
        raise AssertionError('explicit ControlNet import must still enforce its dependency')
'''
    subprocess.run([sys.executable, "-S", "-c", code, str(tmp_path)], check=True)


def test_unexpected_pin_layout_does_not_partially_patch(tmp_path):
    _fake_mflux(tmp_path)
    first = tmp_path / MODULE._TARGETS[0]
    before = first.read_bytes()
    (tmp_path / MODULE._TARGETS[1]).write_text("# changed upstream\n")
    with pytest.raises(RuntimeError, match="Unexpected mflux package layout"):
        MODULE.patch(tmp_path)
    assert first.read_bytes() == before


def test_explicit_controlnet_export_still_works_when_available(tmp_path):
    _fake_mflux(tmp_path)
    path = tmp_path / 'mflux/models/z_image/variants/controlnet/z_image_turbo_controlnet.py'
    path.write_text('class ZImageTurboControlnet: pass\n')
    MODULE.patch(tmp_path)
    subprocess.run([sys.executable, '-S', '-c', '''
import sys
sys.path.insert(0, sys.argv[1])
from mflux.models.z_image import ZImageTurboControlnet as a
from mflux.models.z_image.variants import ZImageTurboControlnet as b
assert a is b
''', str(tmp_path)], check=True)


def test_build_smokes_every_desktop_image_import_before_trimming():
    source = (ROOT / 'apps/rapid-mac/scripts/build-sidecar.sh').read_text()
    assert '"$REPO_ROOT/scripts/patch-mflux-image-imports.py"' in source
    for module in (
        'mflux.models.flux2.variants.txt2img.flux2_klein',
        'mflux.models.flux2.variants.edit.flux2_klein_edit',
        'mflux.models.z_image.variants.z_image',
        'mflux.models.qwen.variants.txt2img.qwen_image',
    ):
        assert f'importlib.import_module("{module}")' in source or f'"{module}",' in source
    assert source.index('patch-mflux-image-imports.py') < source.index('# ----- step 2.7:')
