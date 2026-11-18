#!/usr/bin/env python3
"""Download a Roboflow Universe dataset only after verifying its license."""

from __future__ import annotations

import argparse
import json
import os
import re
import shutil
import stat
import tempfile
import zipfile
from datetime import date
from pathlib import Path
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import Request, urlopen


ROOT = Path(__file__).resolve().parents[2]
DATASET_ROOT = (ROOT / "tools" / "datasets").resolve()
REGISTRY = Path(__file__).parent / "DATASETS.md"
LICENSES = {
    "cc by 4.0": "CC BY 4.0",
    "cc by 4.0 international": "CC BY 4.0",
    "cc by 3.0": "CC BY 3.0",
    "cc by 2.0": "CC BY 2.0",
    "cc0 1.0": "CC0 1.0",
    "cc0": "CC0 1.0",
    "public domain": "Public Domain",
}
MAX_ARCHIVE_BYTES = 5_000_000_000
MAX_EXTRACTED_BYTES = 20_000_000_000
MAX_ARCHIVE_FILES = 250_000


def _slug(value: str, label: str) -> str:
    if not re.fullmatch(r"[A-Za-z0-9_-]+", value):
        raise ValueError(f"{label} must contain only letters, numbers, '_' or '-'")
    return value


def _request(url: str, timeout: int = 60):
    try:
        return urlopen(Request(url, headers={"User-Agent": "CueCoach-dataset-import/1.0"}), timeout=timeout)
    except HTTPError as exc:
        raise RuntimeError(f"Roboflow request failed with HTTP {exc.code}") from None
    except (URLError, TimeoutError, OSError):
        raise RuntimeError("Roboflow request failed; check network access and credentials") from None


def _json(url: str) -> dict:
    try:
        with _request(url) as response:
            payload = json.load(response)
    except (json.JSONDecodeError, UnicodeDecodeError):
        raise RuntimeError("Roboflow returned invalid project or export metadata") from None
    if not isinstance(payload, dict):
        raise RuntimeError("Roboflow returned an unexpected metadata response")
    return payload


def project_license(metadata: dict) -> tuple[str, dict]:
    project = metadata.get("project") if isinstance(metadata.get("project"), dict) else metadata
    raw = next((project.get(key) for key in ("license", "licenseName", "license_name") if project.get(key)), None)
    if not isinstance(raw, str):
        raise ValueError("Roboflow did not provide a verifiable project license; refusing download")
    normalized = re.sub(r"\s+", " ", raw.strip().lower())
    if normalized not in LICENSES:
        raise ValueError(f"dataset license {raw!r} is not on the reuse allowlist; refusing download")
    return LICENSES[normalized], project


def _safe_extract(archive: zipfile.ZipFile, target: Path) -> None:
    entries = archive.infolist()
    if len(entries) > MAX_ARCHIVE_FILES:
        raise ValueError("dataset archive has too many files")
    expanded_size = sum(item.file_size for item in entries)
    if expanded_size > MAX_EXTRACTED_BYTES:
        raise ValueError("dataset archive expands beyond the 20 GB safety limit")
    target_resolved = target.resolve()
    for item in entries:
        member_path = (target / item.filename).resolve()
        if member_path != target_resolved and target_resolved not in member_path.parents:
            raise ValueError("dataset archive contains a path outside its output directory")
        if stat.S_ISLNK(item.external_attr >> 16):
            raise ValueError("dataset archive contains a symbolic link")
    archive.extractall(target)


def import_dataset(workspace: str, project_name: str, version: int, api_key: str, output_root: Path = DATASET_ROOT) -> Path:
    workspace = _slug(workspace, "workspace")
    project_name = _slug(project_name, "project")
    if version < 1:
        raise ValueError("version must be a positive integer")
    output_root = output_root.resolve()
    if output_root != DATASET_ROOT and DATASET_ROOT not in output_root.parents:
        raise ValueError(f"output must stay under {DATASET_ROOT}")

    params = urlencode({"api_key": api_key})
    project_url = f"https://universe.roboflow.com/{workspace}/{project_name}"
    project_info = _json(f"https://api.roboflow.com/{workspace}/{project_name}?{params}")
    license_name, project = project_license(project_info)
    export_info = _json(f"https://api.roboflow.com/{workspace}/{project_name}/{version}/yolov8?{params}")
    if export_info.get("ready") is False:
        raise RuntimeError("Roboflow dataset version is not ready for export")
    export_url = export_info.get("export", {}).get("link")
    if not isinstance(export_url, str) or urlparse(export_url).scheme != "https":
        raise RuntimeError("Roboflow did not return a safe HTTPS dataset link")

    destination = output_root / f"{workspace}_{project_name}_v{version}"
    if destination.exists():
        raise FileExistsError(f"{destination} already exists; refusing to overwrite it")
    output_root.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix=".cuecoach-import-", dir=output_root) as temporary:
        temporary_root = Path(temporary)
        archive_path = temporary_root / "dataset.zip"
        received = 0
        try:
            with _request(export_url) as response, archive_path.open("wb") as archive_file:
                while chunk := response.read(1024 * 1024):
                    received += len(chunk)
                    if received > MAX_ARCHIVE_BYTES:
                        raise ValueError("dataset archive exceeds the 5 GB download limit")
                    archive_file.write(chunk)
        except OSError:
            raise RuntimeError("could not save the Roboflow dataset archive") from None
        extracted = temporary_root / "extract"
        extracted.mkdir()
        with zipfile.ZipFile(archive_path) as archive:
            _safe_extract(archive, extracted)
        yaml_files = list(extracted.rglob("data.yaml"))
        if not yaml_files:
            raise RuntimeError("Roboflow export did not contain data.yaml")
        dataset_dir = yaml_files[0].parent
        manifest = {
            "source": project_url,
            "workspace": workspace,
            "project": project_name,
            "version": version,
            "dataset_name": project.get("name", project_name),
            "author": project.get("owner", project.get("createdBy", "Unknown")),
            "license": license_name,
            "license_source": project_url,
            "imported_on": date.today().isoformat(),
            "format": "YOLOv8 detection",
        }
        (dataset_dir / "cuecoach-license.json").write_text(json.dumps(manifest, indent=2) + "\n")
        shutil.move(str(dataset_dir), destination)

    name = str(manifest["dataset_name"]).replace("|", "\\|").replace("\n", " ")
    author = str(manifest["author"]).replace("|", "\\|").replace("\n", " ")
    entry = f"| [{name}]({project_url}) | {version} | {license_name} | {author} |"
    with REGISTRY.open("a") as registry:
        registry.write(entry + "\n")
    return destination


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("workspace_project", help="Roboflow Universe workspace/project slug")
    parser.add_argument("--version", type=int, required=True)
    args = parser.parse_args()
    if "/" not in args.workspace_project:
        parser.error("workspace_project must be written as workspace/project")
    workspace, project_name = args.workspace_project.split("/", 1)
    api_key = os.environ.get("ROBOFLOW_API_KEY")
    if not api_key:
        parser.error("set ROBOFLOW_API_KEY in the environment; the value is never printed or saved")
    destination = import_dataset(workspace, project_name, args.version, api_key)
    print(f"Imported licensed dataset to {destination}")


if __name__ == "__main__":
    main()
