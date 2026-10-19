"""Plain-text steps that only announce work. Shared by the API loop so tests need no database."""

NO_ACTION_LIMIT = 5

_OPENERS = (
    "i'll ", "i will ", "let me ", "i am going to ", "i'm going to ",
    "first, i", "now i", "now, i", "going to ", "i should ", "my plan",
    "to do this", "okay, ", "ok, let", "sure, i'll", "sure! i'll",
)
_INTENTS = (
    "let me ", "i'll ", "i will ", "i am going to ", "i'm going to ",
    "next, i", "now i", "i need to ", "i should ", "i'm now ", "i am now ",
)


def is_announcement(text: str) -> bool:
    """True when the reply only says what the bot is about to do."""
    stripped = (text or "").strip()
    if not stripped:
        return False
    lowered = stripped.lower()
    if len(lowered) <= 400 and any(lowered.startswith(opener) for opener in _OPENERS):
        return True
    if lowered.endswith(":") and len(lowered) < 160:
        return True
    sentences = [part.strip() for part in lowered.replace("!", ".").replace("?", ".").replace("\n", ".").split(".")]
    sentences = [part for part in sentences if len(part) > 3]
    if not sentences or sentences[-1].startswith("let me know"):
        return False
    last = sentences[-1]
    return any(last.startswith(intent) or (" " + intent) in last for intent in _INTENTS)


def prose_outcome(content: str, misses: int) -> tuple[str, int]:
    """What a step with no tool call does.

    ``complete`` ends the task. ``nudge`` continues. ``block`` stops after five announcements.
    """
    if is_announcement(content):
        misses += 1
        if misses >= NO_ACTION_LIMIT:
            return "block", misses
        return "nudge", misses
    return "complete", 0
