import json
from pathlib import Path

from shellhouse_agent import config as cfg

CONTRACT = json.loads((Path(__file__).resolve().parents[1] / "config-contract.json").read_text())


def test_runner_required_and_optional_keys_match_the_shared_contract():
    assert cfg._TOP_REQUIRED == set(CONTRACT["required"])
    assert cfg._TOP_OPTIONAL == set(CONTRACT["optional"])
    assert cfg._MODEL_KEYS == set(CONTRACT["model_keys"])
