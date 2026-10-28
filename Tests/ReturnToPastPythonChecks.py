"""Run with the SHARP runtime Python. No model download or GPU required."""
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
RESOURCES = ROOT / "Sources/LightTableApp/Resources/ReturnToPast"

PROBE = r'''
import os
from pathlib import Path
import plistlib
import subprocess
import sys
from unittest.mock import patch

original = subprocess.check_output
font_calls = []
def system_fonts(command, *args, **kwargs):
    if isinstance(command, (list, tuple)) and Path(command[0]).name == 'system_profiler':
        font_calls.append(command)
        payload = {'_dataType': 'SPFontsDataType'}
        if sys.argv[1] == 'empty':
            payload['_items'] = []
        elif sys.argv[1] == 'normal':
            payload['_items'] = [{'path': '/System/Library/Fonts/Helvetica.ttc'}]
        return plistlib.dumps([payload])
    return original(command, *args, **kwargs)

with patch.object(subprocess, 'check_output', side_effect=system_fonts):
    # Match the production installation check, including its actual image IO.
    import torch, torchvision, timm
    from sharp.models import create_predictor
    from sharp.utils import io, vis
    from sharp.utils.gaussians import save_ply
    assert torch.__version__.split('+')[0] == '2.8.0'
    assert torchvision.__version__.split('+')[0] == '0.23.0'
    assert timm.__version__ == '1.0.20'
    assert 'matplotlib.pyplot' not in sys.modules
    assert 'matplotlib.font_manager' not in sys.modules

    import numpy as np
    from PIL import Image
    expected = np.arange(18, dtype=np.uint8).reshape(2, 3, 3)
    photo = Path(os.environ['MPLCONFIGDIR']) / 'input.png'
    exif = Image.Exif()
    exif[34665] = {41989: 35}
    Image.fromarray(expected).save(photo, exif=exif)
    pixels, _, focal = io.load_rgb(photo)
    np.testing.assert_array_equal(pixels, expected)
    assert np.isclose(focal, io.convert_focallength(3, 2, 35))

    # Preserve optional diagnostic color-map output without loading fonts.
    from matplotlib import colormaps
    for shape, axes in [((2, 3), (2, 0, 1)), ((2, 2, 3), (0, 3, 1, 2)),
                        ((1, 2, 2, 3), (0, 1, 4, 2, 3))]:
        values = torch.linspace(-1, 2, int(np.prod(shape))).reshape(shape)
        for cmap in ('jet', 'turbo', 'coolwarm'):
            reference = (colormaps.get_cmap(cmap)(np.clip(values.numpy(), 0, 1))[..., :3] * 255).astype(np.uint8)
            result = vis.colorize_scalar_map(values, val_min=0, val_max=1, color_map=cmap)
            np.testing.assert_array_equal(result.numpy(), reference.transpose(axes))
    assert 'matplotlib.pyplot' not in sys.modules
    assert 'matplotlib.font_manager' not in sys.modules
    assert not font_calls, font_calls
    assert not list(Path(os.environ['MPLCONFIGDIR']).glob('fontlist-*'))
print('PASS cold imports, original pixel/focal IO, 9 colormap cases, no font scan')
'''


class ReturnToPastPythonChecks(unittest.TestCase):
    def test_cold_runtime_with_different_system_font_responses(self):
        for response in ("missing", "empty", "normal"):
            with self.subTest(response=response), tempfile.TemporaryDirectory() as cache:
                env = dict(os.environ, PYTHONPATH=str(RESOURCES / "sharp-source"),
                           PYTHONDONTWRITEBYTECODE="1", MPLCONFIGDIR=cache,
                           MPLBACKEND="Agg", HF_HUB_OFFLINE="1")
                result = subprocess.run([sys.executable, "-c", PROBE, response],
                                        env=env, text=True, capture_output=True, timeout=90)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                print(response + ": " + result.stdout.strip())


if __name__ == "__main__":
    unittest.main()
