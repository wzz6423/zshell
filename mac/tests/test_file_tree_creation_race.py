"""Exercise a file-tree creation race with the production model and a real writer.

python3 -B mac/tests/test_file_tree_creation_race.py
python3 -B mac/tests/test_file_tree_creation_race.py --source-ref <pre-fix-ref>

The same preservation assertions must fail against the pre-fix source. A temporary
source copy pauses after the existence precheck, without replacing creation code
or adding a production test hook. Binaries, copies, caches and fixtures are removed.
"""

import argparse
import subprocess
import sys
import tempfile

sys.dont_write_bytecode = True
from test_file_tree_background import ROOT, SUPPORT, compiler_arguments


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-ref", help="Run the same regression against an earlier revision")
    options = parser.parse_args()
    source_path = "mac/zshell/FileTreeModel.swift"
    source = (subprocess.check_output(["git", "show", f"{options.source_ref}:{source_path}"],
                                     cwd=ROOT, text=True)
              if options.source_ref else (ROOT / source_path).read_text())
    boundary = "        var createdFile: String?\n"
    if source.count(boundary) != 1:
        raise SystemExit("Expected exactly one production file-creation boundary")
    with tempfile.TemporaryDirectory(prefix="zshell-file-tree-race-") as directory:
        temporary = Path(directory)
        model = temporary / "FileTreeModel.swift"
        model.write_text(source.replace(boundary, "        CreationRaceFixture.shared.pauseBeforeCreation(dest)\n" + boundary))
        support = temporary / "Support.swift"
        support.write_text(SUPPORT)
        binary = temporary / "file-tree-creation-race"
        subprocess.run(compiler_arguments(temporary) + [
            str(model), str(support), str(ROOT / "mac/tests/FileTreeCreationRaceTests.swift"), "-o", str(binary),
        ], cwd=ROOT, check=True, timeout=120)
        result = subprocess.run([str(binary), str(temporary / "fixture")], cwd=ROOT, timeout=30)
    raise SystemExit(result.returncode)


if __name__ == "__main__":
    main()
