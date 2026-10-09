from shellhouse_agent.cli import VENV_PYTHON, venv_python_to_use

VENV_ROOT = "/opt/shellhouse-agent"


def exists_only(*paths):
    return lambda p: p in paths


def test_switches_to_the_venv_when_running_under_system_python():
    assert venv_python_to_use({}, "/usr", exists_only(VENV_PYTHON)) == VENV_PYTHON


def test_stays_put_when_already_in_the_venv():
    # Inside the venv sys.prefix is the venv root even though its python is a symlink to the system one.
    assert venv_python_to_use({}, VENV_ROOT, exists_only(VENV_PYTHON)) is None


def test_symlinked_interpreter_is_not_mistaken_for_the_venv():
    # System python3 and the venv python share a real path; only the prefix tells them apart.
    assert venv_python_to_use({}, "/usr", lambda p: True) == VENV_PYTHON


def test_no_venv_means_no_switch_for_dev_machines():
    assert venv_python_to_use({}, "/usr", lambda p: False) is None


def test_never_loops_and_can_be_disabled():
    assert venv_python_to_use({"SHELLHOUSE_AGENT_REEXECED": "1"}, "/usr", lambda p: True) is None
    assert venv_python_to_use({"SHELLHOUSE_AGENT_NO_REEXEC": "1"}, "/usr", lambda p: True) is None


def test_custom_venv_location_is_respected(tmp_path):
    custom = tmp_path / "venv" / "bin" / "python"
    custom.parent.mkdir(parents=True)
    custom.write_text("")
    env = {"SHELLHOUSE_AGENT_PYTHON": str(custom)}
    assert venv_python_to_use(env, str(tmp_path / "venv"), lambda p: True) is None
    assert venv_python_to_use(env, "/usr", lambda p: True) == str(custom)
