#!/usr/bin/env python3
"""Exercise project indexing against real Git, filesystem aliases, and FuzzyMatch."""

from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest

REPO = Path(__file__).resolve().parents[2]

HARNESS = r'''
import Foundation
@main struct Harness {
 static func main() async throws {
  let fm=FileManager.default
  let root=URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  defer { try? fm.removeItem(at:root) }
  let gitRoot=root.appendingPathComponent("gitA"), plainRoot=root.appendingPathComponent("plainB"), homeRoot=root.appendingPathComponent("home")
  for path in [gitRoot,plainRoot,homeRoot,gitRoot.appendingPathComponent("src"),gitRoot.appendingPathComponent("sub"),plainRoot.appendingPathComponent(".git/objects")] { try fm.createDirectory(at:path,withIntermediateDirectories:true) }
  func write(_ path:URL,_ value:String="fixture") throws { try Data(value.utf8).write(to:path) }
  try write(gitRoot.appendingPathComponent(".gitignore"),"ignored.log\n")
  try write(gitRoot.appendingPathComponent("src/main.swift"))
  try write(gitRoot.appendingPathComponent("space newline\nname.swift"))
  try write(gitRoot.appendingPathComponent("sub/common.swift"))
  try write(gitRoot.appendingPathComponent("README.md"))
  try write(gitRoot.appendingPathComponent("ignored.log"))
  try write(plainRoot.appendingPathComponent("main.swift"))
  try write(plainRoot.appendingPathComponent("guide.txt"))
  try write(plainRoot.appendingPathComponent(".git/objects/dummy"))
  let runner=GitCommandRunner()
  let initialized=await runner.run(["init","-q"],in:gitRoot.path); precondition(initialized.status==0)
  let staged=await runner.run(["add","--",".gitignore","src/main.swift","space newline\nname.swift","sub/common.swift"],in:gitRoot.path); precondition(staged.status==0)
  let alias=root.appendingPathComponent("gitAlias"); try fm.createSymbolicLink(at:alias,withDestinationURL:gitRoot)
  var checks=0
  func check(_ value:Bool) { precondition(value, "failed check \(checks + 1)"); checks += 1 }
  func searchRoot(_ url:URL, name:String) -> ProjectFileSearchRoot { ProjectFileSearchRoot(projectID:UUID(),projectName:name,root:url.path,homeDirectory:homeRoot.path)! }
  check(ProjectFileSearchRoot(projectID:UUID(),projectName:"Home",root:homeRoot.path,homeDirectory:homeRoot.path)==nil)
  check(ProjectFileSearchRoot(projectID:UUID(),projectName:"Missing",root:root.appendingPathComponent("missing").path,homeDirectory:homeRoot.path)==nil)
  let roots=[searchRoot(gitRoot,name:"Git"),searchRoot(alias,name:"Alias"),searchRoot(gitRoot.appendingPathComponent("sub"),name:"Nested"),searchRoot(plainRoot,name:"Plain")]
  check(ProjectFileSearch.canonicalRoots(roots).count==3)
  let files=await ProjectFileSearch.index(roots:roots)
  check(files.count==7)
  check(Set(files.map(\.canonicalAbsolutePath)).count==files.count)
  check(!files.contains { $0.name=="ignored.log" || $0.relativePath.hasPrefix(".git/") })
  check(files.contains { $0.relativePath=="space newline\nname.swift" })
  let matches=await ProjectFileSearch.search("main",in:files)
  check(matches.count==2)
  check(Set(matches.map(\.file.projectRoot)).count==2)
  check(matches.allSatisfy { $0.file.name=="main.swift" })
  let limited=await ProjectFileSearch.search("swift",in:files,limit:1)
  check(limited.count==1)
  let empty=await ProjectFileSearch.search("  ",in:files)
  check(empty.isEmpty)
  let cancel=Task { await ProjectFileSearch.index(roots:roots) }; cancel.cancel()
  let cancelled=await cancel.value
  check(cancelled.isEmpty)
  print("Project file search: real Git and filesystem, \(checks) assertions passed")
 }
}
'''


class ProjectFileSearchTests(unittest.TestCase):
    def test_real_project_roots_and_search(self):
        with tempfile.TemporaryDirectory(prefix="zshell-project-search-") as directory:
            package = Path(directory)
            sources = package / "Sources" / "Harness"
            sources.mkdir(parents=True)
            for name in ("ProjectFileSearch.swift", "GitCommandRunner.swift"):
                shutil.copy2(REPO / "mac" / "zshell" / name, sources / name)
            (sources / "Harness.swift").write_text(HARNESS)
            fuzzy_path = str(REPO / "mac" / "Vendor" / "FuzzyMatch")
            (package / "Package.swift").write_text(
                "// swift-tools-version: 6.0\n"
                "import PackageDescription\n"
                'let package = Package(name: "ProjectSearchRegression", '
                'platforms: [.macOS(.v14)], '
                f'dependencies: [.package(path: "{fuzzy_path}")], '
                'targets: [.executableTarget(name: "Harness", dependencies: '
                '[.product(name: "FuzzyMatch", package: "FuzzyMatch")])])\n'
            )
            result = subprocess.run(
                [
                    "swift", "run", "--package-path", str(package),
                    "--scratch-path", str(package / "build"), "Harness",
                    str(package / "fixture"),
                ],
                text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                timeout=120,
            )
            self.assertEqual(result.returncode, 0, result.stdout)
            self.assertIn("13 assertions passed", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
