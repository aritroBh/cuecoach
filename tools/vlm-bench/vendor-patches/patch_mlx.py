"""Patch vendored mlx-swift to compile its few precompiled Metal kernels at runtime.

Background: mlx-swift is built in JIT mode, except for 9 kernel files that SwiftPM compiles into
default.metallib with the offline `metal` compiler (Metal Toolchain component, ~700 MB, not installed).
This patch:
  1. excludes those .metal files from the Cmlx target,
  2. adds mlx_runtime_metal_sources.cpp (sources with headers inlined, from inline_metal.py),
  3. makes Device fall back to compiling them with MTLDevice.newLibrary(source:) when no metallib exists,
     and routes default-library kernel lookups to the right runtime library.
Shipping builds would use a normal precompiled metallib; the one-time compile cost is reported separately.
Usage: python3 patch_mlx.py <Vendor/mlx-swift>
"""
import subprocess
import sys
from pathlib import Path

pkg = Path(sys.argv[1])
cmlx = pkg / "Source" / "Cmlx"
here = Path(__file__).resolve().parent

subprocess.run([sys.executable, str(here / "inline_metal.py"), str(cmlx),
                str(cmlx / "mlx-generated" / "mlx_runtime_metal_sources.cpp")], check=True)
for p in (cmlx / "mlx-generated").glob("*.inlined.metal"):
    p.unlink()

manifest = pkg / "Package.swift"
s = manifest.read_text()
metal_files = sorted(str(p.relative_to(cmlx)) for p in (cmlx / "mlx-generated" / "metal").rglob("*.metal"))
marker = '        // vendor docs\n        "vendor-README.md",\n'
assert marker in s, "Package.swift layout changed"
s = s.replace(marker, marker + "".join(f'        "{m}",  // runtime-compiled (CueVLMBench patch)\n' for m in metal_files), 1)
manifest.write_text(s)

dev = cmlx / "mlx" / "mlx" / "backend" / "metal" / "device.cpp"
d = dev.read_text()

helper = r'''
// ---- CueVLMBench patch: runtime-compiled default kernels (no offline Metal toolchain) ----
} // namespace (anonymous, reopened below)
const std::vector<std::pair<std::string, std::string>>& mlx_runtime_metal_sources();
namespace {
std::unordered_map<std::string, MTL::Library*>& runtime_function_libraries() {
  static std::unordered_map<std::string, MTL::Library*> m;
  return m;
}
MTL::Library* compile_runtime_default_libraries(MTL::Device* device) {
  MTL::Library* first = nullptr;
  for (const auto& [name, src] : mlx_runtime_metal_sources()) {
    auto pool = NS::AutoreleasePool::alloc()->init();
    auto options = MTL::CompileOptions::alloc()->init();
    options->setFastMathEnabled(true);
    options->setLanguageVersion(get_metal_version());
    NS::Error* error = nullptr;
    auto lib = device->newLibrary(
        NS::String::string(src.c_str(), NS::UTF8StringEncoding), options, &error);
    options->release();
    if (!lib) {
      std::ostringstream msg;
      msg << "[metal::Device] runtime compile of " << name << " failed: ";
      if (error) {
        msg << error->localizedDescription()->utf8String();
      }
      pool->release();
      throw std::runtime_error(msg.str());
    }
    auto names = lib->functionNames();
    for (NS::UInteger i = 0; i < names->count(); i++) {
      auto fn = static_cast<NS::String*>(names->object(i));
      runtime_function_libraries()[fn->utf8String()] = lib;
    }
    if (!first) {
      first = lib;
    }
    pool->release();
  }
  return first;
}
// ---- end CueVLMBench patch ----

MTL::Library* load_default_library(MTL::Device* device) {'''
anchor = "MTL::Library* load_default_library(MTL::Device* device) {"
assert d.count(anchor) == 1
d = d.replace(anchor, helper, 1)

throw_block = '''  if (!lib) {
    std::ostringstream msg;
    msg << "Failed to load the default metallib. ";'''
assert d.count(throw_block) == 1
d = d.replace(throw_block, '''  if (!lib) {
    return compile_runtime_default_libraries(device);
  }
  if (!lib) {
    std::ostringstream msg;
    msg << "Failed to load the default metallib. ";''', 1)

lookup = '''  return get_kernel(
      base_name, default_library_, hash_name, func_consts, linked_functions);'''
assert d.count(lookup) == 1
d = d.replace(lookup, '''  MTL::Library* lib = default_library_;
  if (auto& rt = runtime_function_libraries(); !rt.empty()) {
    if (auto it = rt.find(base_name); it != rt.end()) {
      lib = it->second;
    }
  }
  return get_kernel(base_name, lib, hash_name, func_consts, linked_functions);''', 1)
if "#include <unordered_map>" not in d:
    d = "#include <unordered_map>\n" + d
dev.write_text(d)
print("patched", dev)
