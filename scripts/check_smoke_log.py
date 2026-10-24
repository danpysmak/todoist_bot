"""Assert offline smoke success without forwarding private marker values to CI logs."""
from pathlib import Path
import sys

text = Path(sys.argv[1]).read_text()
if "OFFLINE RELEASE SMOKE PASSED" not in text:
    raise SystemExit("Offline release smoke failed; inspect its private captured log")
if any(marker in text for marker in (
    "SYNTHETIC_SECRET_MARKER", "SYNTHETIC_STATE_MARKER", "SYNTHETIC_PAYLOAD_MARKER"
)):
    raise SystemExit("Production logging leaked a synthetic private marker")
print("Offline production runtime, HTTP health, and private-log smoke passed (providers mocked)")
