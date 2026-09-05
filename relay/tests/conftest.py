"""Explicitly opt the imported ASGI app into the isolated test environment."""
import os

os.environ["RELAY_ENVIRONMENT"] = "test"
