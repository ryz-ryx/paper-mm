import os
import hashlib
import pytest

# Recorded sha256 hashes of paper_mm2 engine files at commit 01917b8 (normalized LF)
EXPECTED_HASHES = {
    "paper_mm2/bot.py": "a8d92a26e79009b6e0686ca078c6f4ee81517899c6a91c77639e8396f3277bd5",
    "paper_mm2/engine.py": "6178446101a5528c4c6c497c4373d46b575127eb2a450c6f99686ec79fb0d330",
    "paper_mm2/models.py": "28214df26291a7173c4cad8791b433cdb8d3a8996ef1f63ced35947366d63d2f",
}

def test_holdout_code_files_sha256():
    base_dir = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    for rel_path, expected_hash in EXPECTED_HASHES.items():
        full_path = os.path.join(base_dir, rel_path)
        assert os.path.exists(full_path), f"File {rel_path} does not exist"
        with open(full_path, "rb") as f:
            content = f.read()
        # Normalize CRLF to LF to ensure cross-platform deterministic hashing
        normalized_content = content.replace(b"\r\n", b"\n")
        actual_hash = hashlib.sha256(normalized_content).hexdigest()
        assert actual_hash == expected_hash, (
            f"Hash mismatch for {rel_path}:\n"
            f"Expected: {expected_hash}\n"
            f"Actual:   {actual_hash}"
        )
