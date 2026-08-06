#!/usr/bin/env python3
"""
Synchronize a Steam Workshop collection into a Space Engineers save's <Mods> list.

The script intentionally does NOT download Workshop files itself. Space Engineers
Dedicated Server downloads/updates Workshop mods natively once their IDs are
present in the world's Mods list.

Environment:
  SE_COLLECTION_SYNC              1/0, true/false (default: 0)
  SE_WORKSHOP_COLLECTION_ID       Steam Workshop collection ID
  WORLD_NAME                      Save folder name (default: World)
  SE_COLLECTION_SYNC_MODE         replace | merge (default: replace)
  SE_COLLECTION_SYNC_STRICT       1/0 (default: 0)
  SE_COLLECTION_CACHE_FALLBACK    1/0 (default: 1)
  SE_WORKSHOP_EXTRA_MOD_IDS       comma/space/semicolon separated IDs
  SE_WORKSHOP_EXCLUDE_MOD_IDS     comma/space/semicolon separated IDs
"""

from __future__ import annotations

import json
import os
import re
import shutil
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Iterable

STEAM_COLLECTION_API = (
    "https://api.steampowered.com/"
    "ISteamRemoteStorage/GetCollectionDetails/v1/"
)
ROOT = Path("/home/container")
CONFIG_ROOT = ROOT / "config"
CACHE_FILE = CONFIG_ROOT / "workshop-collection-cache.json"

TRUE_VALUES = {"1", "true", "yes", "on"}
ID_SPLIT_RE = re.compile(r"[\s,;]+")
MODS_RE = re.compile(
    r"(?P<indent>^[ \t]*)<Mods(?:\s[^>]*)?\s*/>"
    r"|(?P<indent2>^[ \t]*)<Mods(?:\s[^>]*)?>.*?</Mods>",
    re.MULTILINE | re.DOTALL,
)
PUBLISHED_ID_RE = re.compile(r"<PublishedFileId>\s*(\d+)\s*</PublishedFileId>")


def env_bool(name: str, default: bool = False) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    return raw.strip().lower() in TRUE_VALUES


def parse_ids(raw: str | None) -> list[str]:
    if not raw:
        return []
    result: list[str] = []
    seen: set[str] = set()
    for token in ID_SPLIT_RE.split(raw.strip()):
        if not token:
            continue
        if not token.isdigit():
            print(f"[collection-sync] WARNING: ignoring invalid Workshop ID: {token!r}")
            continue
        if token not in seen:
            seen.add(token)
            result.append(token)
    return result


def steam_post(fields: dict[str, str], attempts: int = 3, timeout: int = 20) -> dict:
    body = urllib.parse.urlencode(fields).encode("ascii")
    req = urllib.request.Request(
        STEAM_COLLECTION_API,
        data=body,
        headers={
            "Content-Type": "application/x-www-form-urlencoded",
            "User-Agent": "SpaceEngineers-Pterodactyl-CollectionSync/1.0",
        },
        method="POST",
    )

    last_error: Exception | None = None
    for attempt in range(1, attempts + 1):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as response:
                if response.status != 200:
                    raise RuntimeError(f"Steam API returned HTTP {response.status}")
                return json.loads(response.read().decode("utf-8"))
        except (urllib.error.URLError, urllib.error.HTTPError, TimeoutError,
                json.JSONDecodeError, RuntimeError) as exc:
            last_error = exc
            print(
                f"[collection-sync] Steam API attempt {attempt}/{attempts} failed: {exc}"
            )
            if attempt < attempts:
                time.sleep(2 * attempt)

    raise RuntimeError(f"Steam collection lookup failed: {last_error}")


def get_collection_children(collection_id: str) -> list[dict]:
    payload = steam_post(
        {
            "collectioncount": "1",
            "publishedfileids[0]": collection_id,
        }
    )
    details = payload.get("response", {}).get("collectiondetails", [])
    if not details:
        raise RuntimeError("Steam returned no collection details")

    detail = details[0]
    if int(detail.get("result", 0)) != 1:
        raise RuntimeError(
            f"Steam returned collection result={detail.get('result')} "
            f"for {collection_id}"
        )

    children = detail.get("children") or []
    # Preserve Steam collection order.
    def sort_key(item: dict) -> tuple[int, str]:
        try:
            order = int(item.get("sortorder", 0))
        except (TypeError, ValueError):
            order = 0
        return order, str(item.get("publishedfileid", ""))

    return sorted(children, key=sort_key)


def flatten_collection(collection_id: str) -> list[str]:
    """
    Resolve a collection, including nested collections when Steam marks a child
    as filetype 2 (Collection). Duplicates keep their first occurrence/order.
    """
    output: list[str] = []
    seen_mods: set[str] = set()
    seen_collections: set[str] = set()

    def visit(cid: str, depth: int = 0) -> None:
        if cid in seen_collections:
            return
        if depth > 8:
            raise RuntimeError("Nested Workshop collection depth exceeded 8")
        seen_collections.add(cid)

        for child in get_collection_children(cid):
            pid = str(child.get("publishedfileid", "")).strip()
            if not pid.isdigit():
                continue

            try:
                filetype = int(child.get("filetype", 0))
            except (TypeError, ValueError):
                filetype = 0

            # Steam EWorkshopFileType::Collection == 2.
            if filetype == 2:
                visit(pid, depth + 1)
            elif pid not in seen_mods:
                seen_mods.add(pid)
                output.append(pid)

    visit(collection_id)
    return output


def load_cache(collection_id: str) -> list[str]:
    try:
        cached = json.loads(CACHE_FILE.read_text(encoding="utf-8"))
        if str(cached.get("collection_id")) != collection_id:
            return []
        ids = cached.get("mod_ids") or []
        return [str(x) for x in ids if str(x).isdigit()]
    except (FileNotFoundError, json.JSONDecodeError, OSError):
        return []


def write_cache(collection_id: str, mod_ids: list[str]) -> None:
    CONFIG_ROOT.mkdir(parents=True, exist_ok=True)
    payload = {
        "collection_id": collection_id,
        "mod_ids": mod_ids,
        "synced_at_unix": int(time.time()),
    }
    temp = CACHE_FILE.with_suffix(".tmp")
    temp.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    temp.replace(CACHE_FILE)


def existing_mod_ids(text: str) -> list[str]:
    result: list[str] = []
    seen: set[str] = set()
    for mod_id in PUBLISHED_ID_RE.findall(text):
        if mod_id not in seen:
            seen.add(mod_id)
            result.append(mod_id)
    return result


def make_mods_block(mod_ids: Iterable[str], indent: str) -> str:
    i1 = indent + "  "
    i2 = indent + "    "
    lines = [f"{indent}<Mods>"]
    for mod_id in mod_ids:
        lines.extend(
            [
                f"{i1}<ModItem>",
                f"{i2}<Name>{mod_id}.sbm</Name>",
                f"{i2}<PublishedFileId>{mod_id}</PublishedFileId>",
                f"{i2}<PublishedServiceName>Steam</PublishedServiceName>",
                f"{i1}</ModItem>",
            ]
        )
    lines.append(f"{indent}</Mods>")
    return "\n".join(lines)


def replace_mods(path: Path, collection_ids: list[str], mode: str,
                 extras: list[str], excludes: set[str]) -> bool:
    if not path.exists():
        print(f"[collection-sync] {path} does not exist yet; skipping.")
        return False

    text = path.read_text(encoding="utf-8-sig")
    match = MODS_RE.search(text)

    old_ids = existing_mod_ids(match.group(0) if match else "")
    if mode == "merge":
        desired = old_ids + collection_ids + extras
    else:
        desired = collection_ids + extras

    final_ids: list[str] = []
    seen: set[str] = set()
    for mod_id in desired:
        if mod_id in excludes or mod_id in seen:
            continue
        seen.add(mod_id)
        final_ids.append(mod_id)

    if not final_ids:
        raise RuntimeError(
            "Resolved mod list is empty; refusing to replace the current Mods block"
        )

    if match:
        indent = match.group("indent") or match.group("indent2") or ""
        new_text = text[:match.start()] + make_mods_block(final_ids, indent) + text[match.end():]
    else:
        # Vanilla saves normally contain <Mods />, but if they do not, insert
        # immediately before the root closing tag.
        closing = re.search(r"\n(?P<indent>[ \t]*)</[^>]+>\s*$", text)
        if not closing:
            raise RuntimeError(f"Could not locate a safe insertion point in {path}")
        indent = closing.group("indent")
        insertion = make_mods_block(final_ids, indent) + "\n"
        new_text = text[:closing.start()] + "\n" + insertion + text[closing.start() + 1:]

    if new_text == text:
        print(f"[collection-sync] {path.name}: already in sync ({len(final_ids)} mods).")
        return True

    backup = path.with_name(path.name + ".collection-sync.bak")
    shutil.copy2(path, backup)

    fd, temp_name = tempfile.mkstemp(prefix=path.name + ".", suffix=".tmp", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(new_text)
        os.replace(temp_name, path)
    finally:
        if os.path.exists(temp_name):
            os.unlink(temp_name)

    print(
        f"[collection-sync] {path.name}: wrote {len(final_ids)} mods "
        f"(backup: {backup.name})."
    )
    return True


def fail(message: str, strict: bool) -> int:
    prefix = "ERROR" if strict else "WARNING"
    print(f"[collection-sync] {prefix}: {message}")
    return 1 if strict else 0


def main() -> int:
    if not env_bool("SE_COLLECTION_SYNC", False):
        print("[collection-sync] Disabled.")
        return 0

    collection_id = os.getenv("SE_WORKSHOP_COLLECTION_ID", "").strip()
    strict = env_bool("SE_COLLECTION_SYNC_STRICT", False)
    cache_fallback = env_bool("SE_COLLECTION_CACHE_FALLBACK", True)

    if not collection_id.isdigit():
        return fail("SE_WORKSHOP_COLLECTION_ID is missing or invalid.", strict)

    mode = os.getenv("SE_COLLECTION_SYNC_MODE", "replace").strip().lower()
    if mode not in {"replace", "merge"}:
        return fail("SE_COLLECTION_SYNC_MODE must be 'replace' or 'merge'.", strict)

    extras = parse_ids(os.getenv("SE_WORKSHOP_EXTRA_MOD_IDS"))
    excludes = set(parse_ids(os.getenv("SE_WORKSHOP_EXCLUDE_MOD_IDS")))

    try:
        mod_ids = flatten_collection(collection_id)
        if not mod_ids:
            raise RuntimeError("Steam collection resolved to zero Workshop items")
        write_cache(collection_id, mod_ids)
        print(
            f"[collection-sync] Collection {collection_id}: "
            f"resolved {len(mod_ids)} Workshop items."
        )
    except Exception as exc:
        if cache_fallback:
            mod_ids = load_cache(collection_id)
            if mod_ids:
                print(
                    f"[collection-sync] WARNING: {exc}; using cached list of "
                    f"{len(mod_ids)} mods."
                )
            else:
                return fail(f"{exc}; no usable cache exists.", strict)
        else:
            return fail(str(exc), strict)

    world_name = os.getenv("WORLD_NAME", "World").strip() or "World"
    world_dir = CONFIG_ROOT / "Saves" / world_name
    targets = [
        world_dir / "Sandbox_config.sbc",
        world_dir / "Sandbox.sbc",
    ]

    updated = 0
    try:
        for target in targets:
            if replace_mods(target, mod_ids, mode, extras, excludes):
                updated += 1
    except Exception as exc:
        return fail(str(exc), strict)

    if updated == 0:
        return fail(
            f"No save files were found in {world_dir}. "
            "The collection will sync on the next restart after the world exists.",
            strict,
        )

    print("[collection-sync] Sync complete. Space Engineers will download/update the mods.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
