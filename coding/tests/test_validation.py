from pathlib import Path
import sys
import unittest


sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from accio_cu_code.errors import ArgumentValidationError
from accio_cu_code.validation import tool_map, validate_arguments


TOOL = {
    "name": "example",
    "inputSchema": {
        "type": "object",
        "properties": {
            "name": {"type": "string", "enum": ["one", "two"]},
            "count": {"type": "integer"},
            "ratio": {"type": "number"},
            "path": {"type": "array", "items": {"type": "string"}},
        },
        "required": ["name"],
        "additionalProperties": False,
    },
}


class ValidationTests(unittest.TestCase):
    def test_accepts_schema_conforming_arguments(self):
        validate_arguments(
            TOOL,
            {"name": "one", "count": 2, "ratio": 0.5, "path": ["File", "Open"]},
        )

    def test_rejects_missing_required_argument(self):
        with self.assertRaisesRegex(ArgumentValidationError, "missing required"):
            validate_arguments(TOOL, {})

    def test_rejects_wrong_type_and_bool_as_number(self):
        with self.assertRaisesRegex(ArgumentValidationError, "must be integer"):
            validate_arguments(TOOL, {"name": "one", "count": True})
        with self.assertRaisesRegex(ArgumentValidationError, "must be number"):
            validate_arguments(TOOL, {"name": "one", "ratio": True})

    def test_rejects_non_finite_number(self):
        with self.assertRaisesRegex(ArgumentValidationError, "must be finite"):
            validate_arguments(TOOL, {"name": "one", "ratio": float("inf")})

    def test_rejects_invalid_enum_and_array_item(self):
        with self.assertRaisesRegex(ArgumentValidationError, "must be one of"):
            validate_arguments(TOOL, {"name": "three"})
        with self.assertRaisesRegex(
            ArgumentValidationError, r"path\[1\] must be string"
        ):
            validate_arguments(TOOL, {"name": "one", "path": ["File", 2]})

    def test_rejects_duplicate_or_non_identifier_tool_names(self):
        with self.assertRaisesRegex(ArgumentValidationError, "duplicate"):
            tool_map([TOOL, TOOL])
        with self.assertRaisesRegex(ArgumentValidationError, "valid Python identifier"):
            tool_map([{"name": "not-valid"}])


if __name__ == "__main__":
    unittest.main()
