"""Exercise the real arm64e archive converter and Ghostty without app windows."""

import argparse
import os
from pathlib import Path
import platform
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
VENDOR = ROOT / "mac/Vendor/libghostty-spm"
SLICE = VENDOR / "GhosttyKit.xcframework/macos-arm64_arm64e_x86_64"
parser = argparse.ArgumentParser(description=__doc__)
parser.add_argument("--converter", type=Path, default=VENDOR / "Script/convert-archive-arm64e.py")
parser.add_argument("--library", type=Path, default=SLICE / "libghostty.a")
parser.add_argument("--converter-only", action="store_true")
options, remaining = parser.parse_known_args()

WORKER = r"""
#include <stdint.h>
static _Thread_local volatile uint64_t counter = 3;
__attribute__((noinline)) static uint64_t increment(uint64_t value) { return value + 1; }
static uint64_t (*volatile callback)(uint64_t) = increment;
void *converted_worker(void *context) {
    *(uint64_t *)context = callback(counter++);
    return 0;
}
"""
MAIN = r"""
#include <pthread.h>
#include <stdint.h>
extern void *converted_worker(void *);
int main(void) {
    uint64_t value = 0;
    converted_worker(&value);
    if (value != 4) return 1;
    converted_worker(&value);
    if (value != 5) return 2;
    for (int i = 0; i < 3; i++) {
        pthread_t thread;
        value = 0;
        if (pthread_create(&thread, 0, converted_worker, &value) ||
            pthread_join(thread, 0) || value != 4) return 3;
    }
    return 0;
}
"""
SCHEDULED = r"""
.section __TEXT,__text,regular,pure_instructions
.globl _converted_worker
_converted_worker:
    stp x19, x30, [sp, #-16]!
    mov x19, x0
    adrp x8, _counter@TLVPPAGE
    ldr x8, [x8, _counter@TLVPPAGEOFF]
    ldr x9, [x8]
    mov x0, x8
    blr x9
    ldr x9, [x0]
    add x9, x9, #1
    str x9, [x0]
    str x9, [x19]
    mov x0, #0
    ldp x19, x30, [sp], #16
    ret
"""

BLOCK = r"""
#include <stdint.h>
#include <stdio.h>
#include <ptrauth.h>
extern void ghostty_arm64e_prepare_block(void *);
extern const void *ghostty_arm64e_block_function(const void *);
extern void *_NSConcreteStackBlock[];
extern void *_Block_copy(const void *);
extern void _Block_release(const void *);
typedef struct { uintptr_t reserved, size; void *copy, *dispose; const char *signature; } Descriptor;
typedef struct { void *isa; int flags, reserved; void *invoke; Descriptor *descriptor; uint64_t value; } Block;
static int copies, disposals;
static void copied(void *dst, const void *src) { copies++; }
static void disposed(const void *block) { disposals++; }
static void completed(Block *block, uint64_t *output) { *output = block->value; }
static void *raw(void *pointer) { return ptrauth_strip(pointer, ptrauth_key_function_pointer); }
static uint64_t call(Block *block) {
    const void *pointer = ghostty_arm64e_block_function(block);
    void *function = ptrauth_sign_unauthenticated(pointer, ptrauth_key_function_pointer, 0);
    uint64_t output = 0;
    ((void (*)(Block *, uint64_t *))function)(block, &output);
    return output;
}
int main(void) {
    Descriptor descriptor = {0, sizeof(Block), raw(copied), raw(disposed), "v16@?0^Q8"};
    Block source = {_NSConcreteStackBlock, (1 << 25) | (1 << 30), 0, raw(completed), &descriptor, 42};
    for (int i = 0; i < 32; i++) {
        Block relocated = source;
        if (call(&relocated) != 42) return 1;
        ghostty_arm64e_prepare_block(&relocated);
        ghostty_arm64e_prepare_block(&relocated);
        if (call(&relocated) != 42) return 2;
        Block *heap = _Block_copy(&relocated);
        if (!heap || call(heap) != 42) return 3;
        _Block_release(heap);
    }
    if (copies != 32 || disposals != 32) return 4;
    puts("PASS relocated Block, direct invocation, system copy and release");
    return 0;
}
"""


@unittest.skipUnless(platform.system() == "Darwin" and platform.machine() == "arm64",
                     "arm64e runtime checks require Apple Silicon macOS")
class GhosttyArm64eTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="zshell-arm64e-test-", dir="/tmp")
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.home = self.directory / "home"
        self.home.mkdir()

    def command(self, arguments):
        result = subprocess.run([str(value) for value in arguments], cwd=self.directory,
                                env={**os.environ, "HOME": str(self.home), "CFFIXED_USER_HOME": str(self.home)},
                                capture_output=True, text=True, timeout=40)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def archive(self, sources, architecture="arm64"):
        objects = []
        for index, (extension, text) in enumerate(sources):
            source = self.directory / f"worker-{index}.{extension}"
            source.write_text(text)
            obj = source.with_suffix(".o")
            self.command(["xcrun", "clang", "-arch", architecture, "-O1",
                          "-mmacosx-version-min=13.0", "-c", source, "-o", obj])
            objects.append(obj)
        archive = self.directory / "raw.a"
        self.command(["xcrun", "libtool", "-static", "-o", archive, *objects])
        return archive

    def convert_and_run(self, archive):
        converted = self.directory / "converted.a"
        self.command(["python3", options.converter, archive, converted])
        again = self.directory / "converted-again.a"
        self.command(["python3", options.converter, converted, again])
        self.assertEqual(converted.read_bytes(), again.read_bytes(), "conversion is idempotent")
        main = self.directory / "main.c"
        main.write_text(MAIN)
        binary = self.directory / "probe"
        self.command(["xcrun", "clang", "-arch", "arm64e", "-mmacosx-version-min=13.0",
                      main, converted, "-o", binary])
        self.command([binary])

    def test_tls_and_unsigned_callback(self):
        self.convert_and_run(self.archive([("c", WORKER)]))

    def test_native_authenticated_tls(self):
        self.convert_and_run(self.archive([("c", WORKER)], architecture="arm64e"))

    def test_scheduled_tls(self):
        storage = "#include <stdint.h>\n_Thread_local volatile uint64_t counter = 3;\n"
        self.convert_and_run(self.archive([("c", storage), ("s", SCHEDULED)]))

    def test_unknown_tls_sequence_is_rejected(self):
        archive = self.archive([("s", SCHEDULED.replace("mov x0, x8", "nop"))])
        destination = self.directory / "unsupported.a"
        result = subprocess.run(["python3", str(options.converter), str(archive), str(destination)],
                                capture_output=True, text=True, timeout=10)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("TLS resolver", result.stdout + result.stderr)
        self.assertFalse(destination.exists())

    def test_block_boundaries(self):
        source = self.directory / "block.c"
        source.write_text(BLOCK)
        binary = self.directory / "block"
        self.command(["xcrun", "clang", "-arch", "arm64e", "-mmacosx-version-min=13.0",
                      "-Wl,-dead_strip", source, VENDOR / "Script/support/arm64e-compat.c",
                      "-I", SLICE / "Headers", "-o", binary])
        self.command([binary])

    @unittest.skipIf(options.converter_only, "converter-only check")
    def test_ghostty_lifecycle(self):
        frameworks = ("AppKit", "Foundation", "CoreFoundation", "CoreGraphics", "CoreText",
                      "CoreVideo", "QuartzCore", "IOSurface", "Metal", "MetalKit", "Carbon")
        for architecture in ("arm64", "arm64e", "x86_64"):
            with self.subTest(architecture=architecture):
                binary = self.directory / ("lifecycle-" + architecture)
                arguments = ["xcrun", "clang", "-arch", architecture, "-mmacosx-version-min=13.0",
                             "-fobjc-arc", ROOT / "mac/tests/GhosttyArm64eLifecycleTests.m",
                             "-I", SLICE / "Headers", options.library, "-lc++", "-o", binary]
                for framework in frameworks:
                    arguments += ["-framework", framework]
                self.command(arguments)
                self.command([binary])


if __name__ == "__main__":
    unittest.main(argv=[__file__, *remaining])
