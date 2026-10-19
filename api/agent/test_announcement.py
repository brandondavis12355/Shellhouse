from agent.announcement import is_announcement, prose_outcome


def test_an_announcement_is_not_completed_on_the_first_step():
    assert is_announcement("I'll check the logs")
    outcome, misses = prose_outcome("I'll check the logs", 0)
    assert outcome == "nudge"
    assert misses == 1


def test_five_announcements_block():
    misses = 0
    outcome = "nudge"
    for _ in range(5):
        outcome, misses = prose_outcome("I'll check the logs", misses)
    assert outcome == "block"
    assert misses == 5


def test_a_factual_answer_completes():
    outcome, misses = prose_outcome("The logs show three errors in auth.py.", 2)
    assert outcome == "complete"
    assert misses == 0
