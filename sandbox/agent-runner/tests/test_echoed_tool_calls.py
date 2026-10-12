from shellhouse_agent.runner import strip_echoed_tool_calls


def test_removes_echoed_call_block():
    text = ("Let me view the screenshot.\nCalling tools:\n[{'id': 'call_00000000', 'type': 'function', "
            "'function': {'name': 'screenshot', 'arguments': {}}}]\nThe page loaded.")
    assert strip_echoed_tool_calls(text) == "Let me view the screenshot.\nThe page loaded."


def test_handles_brackets_and_quotes_inside_arguments():
    text = ("Now let me run it.\nCalling tools:\n[{'id': 'c1', 'function': {'name': 'run_shell', "
            "'arguments': {'command': \"echo '[x]' && ls ]\"}}}]")
    assert strip_echoed_tool_calls(text) == "Now let me run it."


def test_leaves_ordinary_text_alone():
    for text in ["The average is 18.0.", "Calling tools: is a phrase I might say", "list [1, 2, 3] stays"]:
        assert strip_echoed_tool_calls(text) == text


def test_unbalanced_block_is_dropped():
    assert strip_echoed_tool_calls("Done.\nCalling tools:\n[{'id': 'x'") == "Done."
