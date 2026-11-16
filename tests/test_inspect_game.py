from __future__ import annotations

import contextlib
import hashlib
import io
import json
import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

if not __package__:
    sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from tests._fixtures import (
    FIRST_FILE_RECORD,
    PVD_OFFSET,
    ROOT_LBA,
    SECTOR_SIZE,
    both32,
    directory_record,
    make_elf,
    make_iso,
)

import inspect_game
from disc_image import DiscFormatError, IsoImage


BOOT = b"BOOT2 = cdrom0:\\SLPM_654.05;1\r\nVER = 1.00\r\n"


def game_image(
    elf: bytes | None = None,
    boot: bytes | None = BOOT,
    extra: dict[str, bytes] | None = None,
) -> bytes:
    files = {}
    if boot is not None:
        files["SYSTEM.CNF;1"] = boot
    if elf is not None:
        files["SLPM_654.05;1"] = elf
    files.update(extra or {})
    return make_iso(files)


class PatchedImageTrustTests(unittest.TestCase):
    def setUp(self) -> None:
        self.original_elf = make_elf()
        self.patched_elf = make_elf(b"PATCHED!")
        self.assertEqual(len(self.original_elf), len(self.patched_elf))
        self.original = game_image(self.original_elf)
        patcher = mock.patch.multiple(
            inspect_game,
            KNOWN_DISC_SIZE=len(self.original),
            KNOWN_DISC_SHA256=hashlib.sha256(self.original).hexdigest(),
            KNOWN_ELF_SIZE=len(self.original_elf),
            KNOWN_ELF_SHA1=hashlib.sha1(self.original_elf).hexdigest(),
        )
        patcher.start()
        self.addCleanup(patcher.stop)

    def inspect_data(
        self, data: bytes, *, exact: bool = False, allow_patched: bool = False
    ) -> tuple[dict, list[str]]:
        image = IsoImage(io.BytesIO(data), byte_length=len(data), label="synthetic")
        return inspect_game._inspect_image(
            image, Path("synthetic.iso"), len(data), exact, False, allow_patched
        )

    def test_original_passes_with_and_without_exact_hash(self) -> None:
        for exact in (False, True):
            with self.subTest(exact=exact):
                report, errors = self.inspect_data(self.original, exact=exact)
                self.assertEqual(errors, [])
                self.assertTrue(report["executable"]["matchesOriginal"])
                self.assertFalse(report["executable"]["patchedImageAllowed"])
                self.assertEqual(report["executable"]["elf"]["class"], "ELF32")
                self.assertEqual(report["executable"]["elf"]["machine"], 8)
                self.assertEqual(
                    report["iso9660"]["systemCnf"]["BOOT2"], inspect_game.EXPECTED_BOOT
                )
                self.assertEqual(
                    report["source"]["exactDiscSha256"],
                    hashlib.sha256(self.original).hexdigest() if exact else None,
                )

    def test_allow_patched_waives_only_original_executable_sha1(self) -> None:
        patched = game_image(self.patched_elf)
        report, errors = self.inspect_data(patched)
        self.assertEqual(len(errors), 1)
        self.assertIn("ELF SHA-1", errors[0])
        self.assertFalse(report["executable"]["matchesOriginal"])
        self.assertFalse(report["executable"]["patchedImageAllowed"])
        report, errors = self.inspect_data(patched, allow_patched=True)
        self.assertEqual(errors, [])
        self.assertFalse(report["executable"]["matchesOriginal"])
        self.assertTrue(report["executable"]["patchedImageAllowed"])
        self.assertEqual(report["executable"]["sha1"], hashlib.sha1(self.patched_elf).hexdigest())
        self.assertEqual(
            report["executable"]["sha256"], hashlib.sha256(self.patched_elf).hexdigest()
        )

    def test_allow_patched_does_not_waive_exact_disc_hash(self) -> None:
        patched = game_image(self.patched_elf)
        report, errors = self.inspect_data(patched, exact=True, allow_patched=True)
        self.assertEqual(len(errors), 1)
        self.assertIn("disc SHA-256", errors[0])
        self.assertEqual(report["source"]["exactDiscSha256"], hashlib.sha256(patched).hexdigest())
        self.assertFalse(report["executable"]["matchesOriginal"])
        with mock.patch.object(
            inspect_game, "KNOWN_DISC_SHA256", hashlib.sha256(patched).hexdigest()
        ):
            _, errors = self.inspect_data(patched, exact=True, allow_patched=True)
            self.assertEqual(errors, [])

    def test_exact_hash_detects_changed_disc_even_if_elf_is_original(self) -> None:
        changed = bytearray(self.original)
        changed[-1] = 1
        report, errors = self.inspect_data(changed, exact=True, allow_patched=True)
        self.assertTrue(report["executable"]["matchesOriginal"])
        self.assertEqual(len(errors), 1)
        self.assertIn("disc SHA-256", errors[0])
        with mock.patch.object(inspect_game, "sha256_stream", side_effect=AssertionError):
            _, errors = self.inspect_data(changed, exact=False, allow_patched=True)
            self.assertEqual(errors, [])

    def test_wrong_and_missing_boot_remain_errors(self) -> None:
        for boot, expected in (
            (b"BOOT2 = cdrom0:\\WRONG.ELF;1\r\n", "unexpected BOOT2"),
            (b"VER = 1.00\r\n", "unexpected BOOT2"),
            (None, "SYSTEM.CNF is missing"),
        ):
            with self.subTest(boot=boot):
                _, errors = self.inspect_data(
                    game_image(self.patched_elf, boot), allow_patched=True
                )
                self.assertTrue(any(expected in error for error in errors), errors)
                self.assertFalse(any("ELF SHA-1" in error for error in errors))

    def test_missing_and_wrong_size_executable_remain_errors(self) -> None:
        _, errors = self.inspect_data(game_image(None), allow_patched=True)
        self.assertTrue(any("SLPM_654.05 is missing" in error for error in errors))
        _, errors = self.inspect_data(
            game_image(self.patched_elf + b"!"), allow_patched=True
        )
        self.assertTrue(any("ELF size" in error for error in errors))
        self.assertFalse(any("ELF SHA-1" in error for error in errors))

    def test_required_boot_and_executable_must_be_files(self) -> None:
        fake_boot = bytearray(game_image(self.original_elf, bytes(SECTOR_SIZE)))
        fake_boot[FIRST_FILE_RECORD + 25] = 2
        boot_lba = int.from_bytes(
            fake_boot[FIRST_FILE_RECORD + 2 : FIRST_FILE_RECORD + 6], "little"
        )
        boot_text = b"\n" + BOOT
        boot_text += bytes(len(boot_text) % 2)
        fake_member = bytearray(directory_record(b"X", 0, 0))
        fake_member[0] += len(boot_text)
        fake_member.extend(boot_text)
        directory = (
            directory_record(b"\x00", boot_lba, SECTOR_SIZE, 2)
            + directory_record(b"\x01", ROOT_LBA, SECTOR_SIZE, 2)
            + fake_member
        )
        start = boot_lba * SECTOR_SIZE
        fake_boot[start : start + len(directory)] = directory
        image = IsoImage(io.BytesIO(fake_boot))
        self.assertEqual(
            inspect_game.parse_system_cnf(image.read_entry(image.find("SYSTEM.CNF")))["BOOT2"],
            inspect_game.EXPECTED_BOOT,
        )
        _, errors = self.inspect_data(fake_boot, allow_patched=True)
        self.assertTrue(any("SYSTEM.CNF is missing" in error for error in errors))

        fake_elf = bytearray(game_image(bytes(SECTOR_SIZE)))
        elf_record = FIRST_FILE_RECORD + fake_elf[FIRST_FILE_RECORD]
        fake_elf[elf_record + 25] = 2
        elf_lba = int.from_bytes(fake_elf[elf_record + 2 : elf_record + 6], "little")
        directory = directory_record(b"\x00", elf_lba, SECTOR_SIZE, 2) + directory_record(
            b"\x01", ROOT_LBA, SECTOR_SIZE, 2
        )
        start = elf_lba * SECTOR_SIZE
        fake_elf[start : start + len(directory)] = directory
        _, errors = self.inspect_data(fake_elf, allow_patched=True)
        self.assertTrue(any("SLPM_654.05 is missing" in error for error in errors))

    def test_elf_format_and_bounds_remain_enforced(self) -> None:
        not_elf = b"NOPE" + self.patched_elf[4:]
        wrong_class = bytearray(self.patched_elf)
        wrong_class[4] = 2
        bad_section_table = bytearray(self.patched_elf)
        bad_section_table[32:36] = (0xFFFFFF00).to_bytes(4, "little")
        for elf in (not_elf, wrong_class, bad_section_table):
            with self.subTest(elf=bytes(elf[:8])):
                _, errors = self.inspect_data(game_image(elf), allow_patched=True)
                self.assertTrue(any("ELF parse failed" in error for error in errors), errors)
                self.assertFalse(any("ELF SHA-1" in error for error in errors))

    def test_disc_size_and_structure_remain_enforced(self) -> None:
        _, errors = self.inspect_data(self.original + b"\x00", allow_patched=True)
        self.assertTrue(any("disc size" in error for error in errors))
        malformed_volume = bytearray(self.original)
        malformed_volume[PVD_OFFSET + 84] ^= 1
        malformed_directory = bytearray(self.original)
        malformed_directory[FIRST_FILE_RECORD] = 2
        outside_file = bytearray(self.original)
        outside_file[FIRST_FILE_RECORD + 2 : FIRST_FILE_RECORD + 10] = both32(32)
        for data in (malformed_volume, malformed_directory, outside_file):
            for allow_patched in (False, True):
                with self.subTest(allow_patched=allow_patched, data=data[FIRST_FILE_RECORD]):
                    with self.assertRaises(DiscFormatError):
                        self.inspect_data(data, allow_patched=allow_patched)

    def test_container_inventory_and_exhaustive_zero_check(self) -> None:
        inner = make_iso({"PAYLOAD;1": b"data"})
        data = game_image(
            self.original_elf,
            extra={"ACTIVE.CVM;1": bytes(3 * 2048) + inner, "EMPTY.CVM;1": bytes(1024)},
        )
        image = IsoImage(io.BytesIO(data), byte_length=len(data))
        report, errors = inspect_game._inspect_image(
            image, Path("synthetic.iso"), len(data), False, True, False
        )
        self.assertTrue(any("disc size" in error for error in errors))
        active, empty = report["containers"]
        self.assertTrue(active["embeddedIso"])
        self.assertEqual(active["isoBase"], 3 * 2048)
        self.assertEqual(active["fileCount"], 1)
        self.assertFalse(empty["embeddedIso"])
        self.assertTrue(empty["allZero"])

    def test_cli_executes_real_trust_checks(self) -> None:
        patched = game_image(self.patched_elf)
        malformed = bytearray(self.original)
        malformed[PVD_OFFSET + 84] ^= 1
        bad_boot = game_image(self.patched_elf, b"BOOT2 = wrong\r\n")
        cases = (
            (self.original, [], 0, "Verification: OK"),
            (patched, [], 1, "ELF SHA-1"),
            (patched, ["--allow-patched"], 0, "Verification: OK"),
            (patched, ["--allow-patched", "--exact"], 1, "disc SHA-256"),
            (bad_boot, ["--allow-patched"], 1, "unexpected BOOT2"),
            (malformed, ["--allow-patched"], 2, "disagree"),
        )
        for data, flags, expected_code, expected_text in cases:
            with self.subTest(flags=flags, expected=expected_code):
                def open_image(_path: Path) -> tuple[io.BytesIO, IsoImage]:
                    stream = io.BytesIO(data)
                    return stream, IsoImage(stream, byte_length=len(data))

                stdout, stderr = io.StringIO(), io.StringIO()
                with (
                    mock.patch.object(sys, "argv", ["inspect_game.py", "synthetic.iso", *flags]),
                    mock.patch.object(
                        Path, "stat", return_value=SimpleNamespace(st_size=len(data))
                    ),
                    mock.patch.object(IsoImage, "open", side_effect=open_image),
                    contextlib.redirect_stdout(stdout),
                    contextlib.redirect_stderr(stderr),
                ):
                    self.assertEqual(inspect_game.main(), expected_code)
                self.assertIn(expected_text, stdout.getvalue() + stderr.getvalue())


class LockAndCliTests(unittest.TestCase):
    def test_constants_match_pinned_game_lock(self) -> None:
        lock_path = Path(__file__).resolve().parents[1] / "game.lock.json"
        lock = json.loads(lock_path.read_text(encoding="utf-8"))
        self.assertEqual(inspect_game.KNOWN_DISC_SIZE, lock["disc"]["size"])
        self.assertEqual(inspect_game.KNOWN_DISC_SHA256, lock["disc"]["sha256"])
        self.assertEqual(inspect_game.KNOWN_ELF_SIZE, lock["executable"]["size"])
        self.assertEqual(inspect_game.KNOWN_ELF_SHA1, lock["executable"]["sha1"])
        self.assertEqual(
            inspect_game.EXPECTED_BOOT, f"cdrom0:\\{lock['executable']['path']};1"
        )
        self.assertEqual(lock["disc"]["size"], 1_230_897_152)
        self.assertEqual(
            lock["disc"]["sha256"],
            "221e4137cc1b197b262c58604143d92d2fdb3dd82d6b464870c6bbf1c68a27df",
        )
        self.assertEqual(lock["executable"]["size"], 4_262_380)
        self.assertEqual(lock["executable"]["sha1"], "84ff167ee9612966e5027beabb7b920e7cf18920")
        self.assertEqual(
            lock["executable"]["sha256"],
            "5e51cf5ecb8f344ccab90f7d99df04ff050fadba025579e4369c4abe0ebe75a1",
        )

    def test_all_cli_options_are_forwarded_and_json_is_written(self) -> None:
        report = {"synthetic": {"value": 1}}
        destination = Path(r"reports\inventory.json")
        args = [
            "inspect_game.py",
            "synthetic.iso",
            "--exact",
            "--exhaustive-zero-check",
            "--allow-patched",
            "--json",
            str(destination),
        ]
        with (
            mock.patch.object(sys, "argv", args),
            mock.patch.object(inspect_game, "inspect", return_value=(report, [])) as inspect,
            mock.patch.object(inspect_game, "print_summary") as summary,
            mock.patch.object(Path, "mkdir", autospec=True) as mkdir,
            mock.patch.object(Path, "write_text", autospec=True) as write,
        ):
            self.assertEqual(inspect_game.main(), 0)
        inspect.assert_called_once_with(Path("synthetic.iso"), True, True, True)
        summary.assert_called_once_with(report, [])
        mkdir.assert_called_once_with(destination.parent, parents=True, exist_ok=True)
        self.assertEqual(write.call_args.args[0], destination)
        self.assertEqual(json.loads(write.call_args.args[1]), report)
        self.assertTrue(write.call_args.args[1].endswith("\n"))
        self.assertEqual(write.call_args.kwargs["encoding"], "utf-8")

    def test_cli_defaults_and_verification_exit_code(self) -> None:
        report, errors = {"report": True}, ["verification failed"]
        with (
            mock.patch.object(sys, "argv", ["inspect_game.py", "synthetic.iso"]),
            mock.patch.object(inspect_game, "inspect", return_value=(report, errors)) as inspect,
            mock.patch.object(inspect_game, "print_summary") as summary,
        ):
            self.assertEqual(inspect_game.main(), 1)
        inspect.assert_called_once_with(Path("synthetic.iso"), False, False, False)
        summary.assert_called_once_with(report, errors)

    def test_cli_operational_errors_return_two(self) -> None:
        for error in (OSError("cannot open"), DiscFormatError("bad ISO")):
            with self.subTest(error=error):
                stderr = io.StringIO()
                with (
                    mock.patch.object(sys, "argv", ["inspect_game.py", "synthetic.iso"]),
                    mock.patch.object(inspect_game, "inspect", side_effect=error),
                    contextlib.redirect_stderr(stderr),
                ):
                    self.assertEqual(inspect_game.main(), 2)
                self.assertIn(f"inspect_game: {error}", stderr.getvalue())
        with (
            mock.patch.object(sys, "argv", ["inspect_game.py"]),
            contextlib.redirect_stderr(io.StringIO()),
            self.assertRaises(SystemExit) as raised,
        ):
            inspect_game.main()
        self.assertEqual(raised.exception.code, 2)

    def test_path_wrapper_closes_stream_on_success_and_failure(self) -> None:
        for error in (None, DiscFormatError("bad directory")):
            with self.subTest(error=error):
                stream = io.BytesIO()
                fake_image = object()
                expected = ({"report": True}, [])
                with (
                    mock.patch.object(Path, "stat", return_value=SimpleNamespace(st_size=123)),
                    mock.patch.object(IsoImage, "open", return_value=(stream, fake_image)),
                    mock.patch.object(
                        inspect_game, "_inspect_image", return_value=expected, side_effect=error
                    ) as inspect_image,
                ):
                    if error is None:
                        self.assertEqual(
                            inspect_game.inspect(Path("synthetic.iso"), True, False, True),
                            expected,
                        )
                    else:
                        with self.assertRaises(DiscFormatError):
                            inspect_game.inspect(Path("synthetic.iso"), True, False, True)
                inspect_image.assert_called_once_with(
                    fake_image, Path("synthetic.iso"), 123, True, False, True
                )
                self.assertTrue(stream.closed)


if __name__ == "__main__":
    unittest.main()
