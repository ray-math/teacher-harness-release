"""Read the selected Codex TOML without exposing unrelated settings or secrets."""
import json
import sys
import tomllib
from pathlib import Path

config, executable, launcher, version = sys.argv[1:]
data = tomllib.loads(Path(config).read_text(encoding="utf-8-sig"))
server = data.get("mcp_servers", {}).get("hwpx")
if server is None:
    result = {"exists": False, "matchesProject": False}
else:
    required = {"HWPX_STACK_AUTO_UPDATE": "0", "PYTHONUTF8": "1", "HWPX_SKILL_VERSION": version}
    env = server.get("env", {})
    matches = (
        server.get("command") == executable
        and server.get("args") == ["-B", launcher]
        and server.get("enabled", True)
        and all(env.get(key) == value for key, value in required.items())
    )
    result = {"exists": True, "matchesProject": bool(matches)}
print(json.dumps(result))
