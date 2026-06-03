# Pre-warm heavy provider SDK imports in the `hermes gateway` process.
#
# WHY THIS EXISTS
# ---------------
# Upstream hermes-agent loads provider SDKs lazily. `agent/anthropic_adapter.py`
# `_get_anthropic_sdk()` does a `import anthropic` on the first agent turn and
# then PERMANENTLY caches the result in a module-global — including a failure:
#
#     try:
#         import anthropic as _sdk
#         _anthropic_sdk = _sdk
#     except ImportError:
#         _anthropic_sdk = None   # sticky for the whole process lifetime
#
# When several agent sessions start at the same instant, multiple executor
# threads (gateway runs `AIAgent(...)` via loop.run_in_executor) hit that lazy
# import simultaneously on a cold container. A concurrent first-import of a
# heavy package (anthropic -> pydantic/httpx/...) can transiently raise
# ImportError in one of the racing threads; `_get_anthropic_sdk()` caches that
# as None, and from then on EVERY message fails with
#   "The 'anthropic' package is required for the Anthropic provider"
# until the gateway is restarted.
#
# This is exactly what a Telegram forum/"Topics" group triggers: one inbound
# fans out into several topic sessions that build agents concurrently. A 1:1 DM
# never trips it (single session -> single thread -> no concurrent import).
#
# THE FIX
# -------
# Import the configured provider SDK(s) ONCE, single-threaded, at interpreter
# startup — before the gateway spawns any executor threads. That populates
# sys.modules, so the later lazy `import anthropic` becomes an instant, race-free
# cache hit. No upstream patching (survives HERMES_REF bumps); scoped to the
# gateway process so MCP stdio subprocesses, the dashboard, and one-shot CLI
# calls that inherit this image are unaffected.
#
# Loaded via the companion `hermes_provider_warm.pth` file (site processes its
# `import` line at startup). Anything here must NEVER raise — a broken
# sitecustomize/.pth breaks every Python invocation in the image.

import os
import sys


def _warm():
    # Only the gateway races on first-import. `hermes gateway` -> argv has the
    # bare "gateway" token. Skip every other process to avoid paying the import
    # cost (and memory) on frequently-spawned MCP subprocesses.
    if "gateway" not in sys.argv:
        return

    # Comma-separated importable module names. Defaults to the provider this
    # template pre-installs and defaults its model to. Extend via env (e.g.
    # "anthropic,boto3") if you switch the default provider — no code change.
    sdks = os.environ.get("HERMES_WARM_SDKS", "anthropic")
    for name in (s.strip() for s in sdks.split(",")):
        if not name:
            continue
        try:
            __import__(name)
        except Exception:
            # Package genuinely missing or import broke — say nothing and let
            # the lazy path retry on demand. Warming is best-effort.
            pass


try:
    _warm()
except Exception:
    pass
