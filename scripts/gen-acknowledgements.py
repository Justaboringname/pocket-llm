#!/usr/bin/env python3
"""Writes App/Resources/Acknowledgements.json from the SwiftPM checkouts.

The list covers the packages that are actually linked into the app binary (not every
package that gets resolved: swift-syntax only builds macros, and swift-asn1, swift-system
and BoringSSL are not linked on Apple platforms). It was taken from the app target's
LinkFileList; `--check` re-verifies that against the last simulator build.

License texts are copied verbatim from each checkout (plus the NOTICE files Apache-2.0
asks to be shipped). Run after a build has resolved packages:

    scripts/gen-acknowledgements.py           # write the JSON
    scripts/gen-acknowledgements.py --check   # also compare with the linked modules
"""

import glob
import json
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CHECKOUTS = os.path.join(ROOT, ".build", "dd", "SourcePackages", "checkouts")
RESOLVED = os.path.join(
    ROOT, "LLMOnIPhone.xcodeproj", "project.xcworkspace", "xcshareddata", "swiftpm",
    "Package.resolved")
OUTPUT = os.path.join(ROOT, "App", "Resources", "Acknowledgements.json")

# (display name, package identity, license SPDX id, [files relative to the checkout])
PACKAGES = [
    ("mlx-swift", "mlx-swift", "MIT", ["LICENSE"]),
    ("MLX (C++ core, bundled in mlx-swift)", "mlx-swift", "MIT", ["Source/Cmlx/mlx/LICENSE"]),
    ("mlx-c (bundled in mlx-swift)", "mlx-swift", "MIT", ["Source/Cmlx/mlx-c/LICENSE"]),
    ("metal-cpp (bundled in mlx-swift)", "mlx-swift", "Apache-2.0",
     ["Source/Cmlx/metal-cpp/LICENSE.txt"]),
    ("{fmt} (bundled in mlx-swift)", "mlx-swift", "MIT", ["Source/Cmlx/fmt/LICENSE"]),
    ("JSON for Modern C++ (bundled in mlx-swift)", "mlx-swift", "MIT",
     ["Source/Cmlx/json/LICENSE.MIT"]),
    ("mlx-swift-lm", "mlx-swift-lm", "MIT", ["LICENSE"]),
    ("swift-transformers", "swift-transformers", "Apache-2.0", ["LICENSE"]),
    ("swift-huggingface", "swift-huggingface", "Apache-2.0", ["LICENSE"]),
    ("swift-jinja", "swift-jinja", "Apache-2.0", ["LICENSE"]),
    ("swift-crypto", "swift-crypto", "Apache-2.0", ["LICENSE.txt", "NOTICE.txt"]),
    ("swift-nio", "swift-nio", "Apache-2.0", ["LICENSE.txt", "NOTICE.txt"]),
    ("swift-collections", "swift-collections", "Apache-2.0", ["LICENSE.txt"]),
    ("swift-atomics", "swift-atomics", "Apache-2.0", ["LICENSE.txt"]),
    ("swift-numerics", "swift-numerics", "Apache-2.0", ["LICENSE.txt"]),
    ("EventSource", "eventsource", "MIT", ["LICENSE.md"]),
    ("yyjson", "yyjson", "MIT", ["LICENSE"]),
]

# Linked module (object file) -> package identity, for --check.
MODULES = {
    "MLX": "mlx-swift", "MLXNN": "mlx-swift", "MLXOptimizers": "mlx-swift",
    "Cmlx": "mlx-swift",
    "MLXLLM": "mlx-swift-lm", "MLXLMCommon": "mlx-swift-lm", "MLXHuggingFace": "mlx-swift-lm",
    "Tokenizers": "swift-transformers", "Hub": "swift-transformers",
    "HuggingFace": "swift-huggingface", "Jinja": "swift-jinja", "Crypto": "swift-crypto",
    "DequeModule": "swift-collections", "OrderedCollections": "swift-collections",
    "InternalCollectionsUtilities": "swift-collections",
    "Atomics": "swift-atomics", "_AtomicsShims": "swift-atomics",
    "NIOCore": "swift-nio", "NIOConcurrencyHelpers": "swift-nio", "_NIODataStructures": "swift-nio",
    "_NIOBase64": "swift-nio", "CNIOAtomics": "swift-nio", "CNIODarwin": "swift-nio",
    "CNIOLinux": "swift-nio", "CNIOOpenBSD": "swift-nio", "CNIOWASI": "swift-nio",
    "CNIOWindows": "swift-nio",
    "Numerics": "swift-numerics", "RealModule": "swift-numerics",
    "ComplexModule": "swift-numerics", "_NumericsShims": "swift-numerics",
    "EventSource": "eventsource", "yyjson": "yyjson",
}

# Checkout directory names differ in case from the identity for some packages.
CHECKOUT_DIR = {"eventsource": "EventSource"}


def resolved_pins():
    with open(RESOLVED) as handle:
        data = json.load(handle)
    return {pin["identity"]: pin for pin in data["pins"]}


def check_linked(identities):
    pattern = os.path.join(
        ROOT, ".build", "dd", "Build", "Intermediates.noindex", "LLMOnIPhone.build",
        "Debug-iphonesimulator", "LLMOnIPhone.build", "Objects-normal", "arm64",
        "LLMOnIPhone.LinkFileList")
    files = glob.glob(pattern)
    if not files:
        print("check: no LinkFileList found (build for the simulator first)", file=sys.stderr)
        return False
    ok = True
    own_sources = {os.path.splitext(os.path.basename(p))[0]
                   for p in glob.glob(os.path.join(ROOT, "App", "Sources", "**", "*.swift"),
                                      recursive=True)}
    with open(files[0]) as handle:
        for line in handle:
            module = os.path.splitext(os.path.basename(line.strip()))[0]
            if module in own_sources or module in ("LLMCore", "GeneratedAssetSymbols", "GeneratedStringSymbols_Localizable") or not module:
                continue
            package = MODULES.get(module)
            if package is None:
                print(f"check: linked module {module} is not mapped to a package")
                ok = False
            elif package not in identities:
                print(f"check: linked package {package} has no acknowledgement")
                ok = False
    print("check: all linked modules are acknowledged" if ok else "check: FAILED")
    return ok


def main():
    pins = resolved_pins()
    entries = []
    for name, identity, spdx, files in PACKAGES:
        pin = pins[identity]
        directory = os.path.join(CHECKOUTS, CHECKOUT_DIR.get(identity, identity))
        texts = []
        for relative in files:
            with open(os.path.join(directory, relative), encoding="utf-8") as handle:
                texts.append({"file": os.path.basename(relative), "text": handle.read().strip()})
        location = pin["location"].removesuffix(".git")
        entries.append({
            "name": name,
            "version": pin["state"].get("version") or pin["state"].get("revision", "")[:12],
            "url": location,
            "license": spdx,
            "texts": texts,
        })
    os.makedirs(os.path.dirname(OUTPUT), exist_ok=True)
    with open(OUTPUT, "w", encoding="utf-8") as handle:
        json.dump({"packages": entries}, handle, indent=1, ensure_ascii=False)
        handle.write("\n")
    print(f"wrote {os.path.relpath(OUTPUT, ROOT)} ({len(entries)} entries)")
    if "--check" in sys.argv:
        return 0 if check_linked({identity for _, identity, _, _ in PACKAGES}) else 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
