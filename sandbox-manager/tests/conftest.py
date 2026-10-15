import os
import sys

# The manager refuses to start without a token; tests never talk to a real backend.
os.environ.setdefault("MANAGER_TOKEN", "t" * 64)
os.environ.setdefault("SANDBOX_BACKEND", "docker")
os.environ.setdefault("MANAGER_AUDIT_LOG", "/dev/null")
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "app"))
