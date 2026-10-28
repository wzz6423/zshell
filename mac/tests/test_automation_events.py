"""Run production automation streams against both real terminal backends.

Build Debug, then set ZSHELL_TEST_DERIVED_DATA to that isolated build. Uses an
isolated HOME, preferences and PTY directory; no visible app window is opened.
"""
import os
from pathlib import Path
import platform
import subprocess
import tempfile

root = Path(__file__).resolve().parents[2]
build = Path(os.environ.get('ZSHELL_TEST_DERIVED_DATA', root / 'mac/build/debug')) / 'Build'
products = build / 'Products/Debug'
bundle = products / 'zshell Debug.app'
library = bundle / 'Contents/MacOS/zshell.debug.dylib'
if not library.is_file():
    raise SystemExit(f'Build the Debug app in {build.parent} before running event tests.')

with tempfile.TemporaryDirectory(prefix='zshell-event-model-', dir='/tmp') as directory:
    output = Path(directory)
    binary = output / 'event-tests'
    command = ['xcrun', 'swiftc', '-parse-as-library', '-swift-version', '5',
               '-target', f'{platform.machine()}-apple-macos15.6',
               '-module-cache-path', str(output / 'ModuleCache'),
               '-I', str(products), '-I', str(products / 'include'), '-F', str(products)]
    for modulemap in (build / 'Intermediates.noindex/GeneratedModuleMaps').glob('*.modulemap'):
        command += ['-Xcc', f'-fmodule-map-file={modulemap}']
    for include in ('STTextView/Sources/STObjCLandShim/include', 'swift-cmark/src/include',
                    'swift-cmark/extensions/include', 'swift-markdown/Sources/CAtomic/include'):
        path = root / 'mac/Vendor' / include
        command += ['-I', str(path), '-Xcc', f'-fmodule-map-file={path / "module.modulemap"}']
    command += ['-I', str(root / 'mac/Vendor/alacritty-bridge/include'),
                '-I', str(root / 'mac/Vendor/tree-sitter/lib/include'), str(library),
                '-Xlinker', '-rpath', '-Xlinker', str(products),
                '-Xlinker', '-rpath', '-Xlinker', str(library.parent),
                str(root / 'mac/tests/AutomationEventTests.swift'), '-o', str(binary)]
    subprocess.run(command, cwd=root, check=True)
    for backend in ('alacritty', 'ghostty'):
        home = output / backend
        home.mkdir()
        config = home / '.config/zshell-dev'
        config.mkdir(parents=True)
        (config / 'config.toml').write_text('[ai]\nenabled = false\n')
        (home / '.zshrc').write_text("PROMPT='EVENT-READY> '; RPROMPT=''; HISTFILE=/dev/null\n")
        environment = {k: v for k, v in os.environ.items() if not k.startswith('ZSHELL_')}
        environment.update(HOME=str(home), CFFIXED_USER_HOME=str(home), ZDOTDIR=str(home),
                           ZSHELL_PTY_MUX_DIRECTORY=str(home / 'pty'))
        subprocess.run([str(binary), backend, str(bundle), str(home)], cwd=root,
                       env=environment, check=True, timeout=120)
