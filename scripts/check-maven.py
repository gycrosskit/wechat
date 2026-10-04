"""检查实际发布文件与 Gradle 变体引用，避免本机源码编译掩盖损坏的 Maven 产物。"""
import hashlib
import json
import sys
from pathlib import Path
import xml.etree.ElementTree as ET

if len(sys.argv) not in (6, 7):
    raise SystemExit("Usage: check-maven.py repository group version modules_csv native_targets_csv [publications_csv]")
repository = Path(sys.argv[1]).resolve()
expected_group = sys.argv[2]
expected_version = sys.argv[3]
expected_modules = set(sys.argv[4].split(","))
expected_targets = set(sys.argv[5].split(","))

def resolve_artifact(path):
    # Maven SNAPSHOT 元数据使用逻辑版本，磁盘文件使用时间戳版本。
    if not path.parent.name.endswith("-SNAPSHOT"):
        return path
    metadata = ET.parse(path.parent / "maven-metadata.xml").getroot()
    artifact_id = metadata.findtext("artifactId")
    version = metadata.findtext("version")
    suffix = path.name.removeprefix(f"{artifact_id}-{version}")
    for snapshot in metadata.findall("./versioning/snapshotVersions/snapshotVersion"):
        classifier = snapshot.findtext("classifier")
        extension = snapshot.findtext("extension")
        expected_suffix = (f"-{classifier}" if classifier else "") + f".{extension}"
        if suffix == expected_suffix:
            return path.with_name(f"{artifact_id}-{snapshot.findtext('value')}{suffix}")
    raise AssertionError(f"No current snapshot artifact: {path}")


modules = []
for path in repository.rglob("*.module"):
    if path.parent.name.endswith("-SNAPSHOT"):
        logical = path.parent / f"{path.parent.parent.name}-{path.parent.name}.module"
        if path != resolve_artifact(logical):
            continue
    modules.append(path)
assert modules, "Maven staging repository is empty"
platforms = set()
coordinates = {}
def check_sidecars(file):
    for algorithm in ("md5", "sha1", "sha256", "sha512"):
        checksum = file.with_name(file.name + "." + algorithm)
        assert checksum.is_file(), f"Missing artifact checksum: {checksum}"
        assert checksum.read_text().strip() == hashlib.new(algorithm, file.read_bytes()).hexdigest(), checksum

for module in modules:
    check_sidecars(module.with_suffix(".pom"))
    for algorithm in ("md5", "sha1", "sha256", "sha512"):
        checksum = module.with_name(module.name + "." + algorithm)
        assert checksum.is_file(), f"Missing metadata checksum: {checksum}"
        if checksum.exists():
            assert checksum.read_text().strip() == hashlib.new(algorithm, module.read_bytes()).hexdigest(), checksum
    pom = ET.parse(module.with_suffix(".pom")).getroot()
    namespaces = {"m": "http://maven.apache.org/POM/4.0.0"}
    assert pom.findtext("m:groupId", namespaces=namespaces) == expected_group, module
    assert pom.findtext("m:version", namespaces=namespaces) == expected_version, module
    published_module = pom.findtext("m:artifactId", namespaces=namespaces)
    assert published_module == module.parent.parent.name, module
    license = pom.find("m:licenses/m:license", namespaces)
    assert license is not None, f"Missing Apache license: {module}"
    assert license.findtext("m:name", namespaces=namespaces) == "Apache License, Version 2.0", module
    assert license.findtext("m:url", namespaces=namespaces) == "https://www.apache.org/licenses/LICENSE-2.0.txt", module
    assert license.findtext("m:distribution", namespaces=namespaces) == "repo", module
    data = json.loads(module.read_text())
    component = data["component"]
    assert component["group"] == expected_group, component
    assert component["version"] == expected_version, component
    coordinates.setdefault(published_module, set()).add(component["version"])
    if "url" in component:
        assert resolve_artifact((module.parent / component["url"]).resolve()).is_file(), component
    for variant in data["variants"]:
        assert variant["name"] != "metadataSourcesElements", variant
        assert not variant["name"].endswith(("SourcesElements-published", "MetadataElements-published", "ResourcesElements-published")), variant
        target = variant.get("attributes", {}).get("org.jetbrains.kotlin.native.target")
        if target:
            platforms.add(target)
        if "available-at" in variant:
            redirect = variant["available-at"]
            target_module = resolve_artifact((module.parent / redirect["url"]).resolve())
            assert target_module.is_file(), redirect
            target_variants = json.loads(target_module.read_text())["variants"]
            assert any(item["name"] == variant["name"] for item in target_variants), f"Dangling variant: {variant}"
        for entry in variant.get("files", []):
            artifact = resolve_artifact((module.parent / entry["url"]).resolve())
            assert artifact.is_file(), artifact
            check_sidecars(artifact)
            assert artifact.stat().st_size == entry["size"], artifact
            for algorithm in ("md5", "sha1", "sha256", "sha512"):
                assert hashlib.new(algorithm, artifact.read_bytes()).hexdigest() == entry[algorithm], artifact

for module in modules:
    for variant in json.loads(module.read_text())["variants"]:
        for dependency in variant.get("dependencies", []):
            if dependency["module"] in coordinates:
                assert dependency["group"] == expected_group, dependency
                assert dependency["version"]["requires"] in coordinates[dependency["module"]], dependency

assert expected_targets <= platforms, platforms
assert list(repository.rglob("*.aar")), "Android AAR is missing"
expected_coordinates = set(sys.argv[6].split(",")) if len(sys.argv) == 7 else set(expected_modules)
if len(sys.argv) == 6:
    for module in modules:
        if module.parent.parent.name in expected_modules:
            for variant in json.loads(module.read_text())["variants"]:
                if "available-at" in variant:
                    expected_coordinates.add(variant["available-at"]["module"])
assert expected_modules <= expected_coordinates, expected_coordinates
assert expected_coordinates == coordinates.keys(), f"Missing or unexpected publications: {coordinates}"
assert len(modules) == len(expected_coordinates), "Duplicate module metadata"
print(f"Maven metadata: {len(modules)} modules; artifact hashes, Apache POM licenses, project dependencies and platform variants passed")
