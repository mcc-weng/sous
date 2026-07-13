import pathlib

PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "chat.md").read_text()

M2A_VERBS = ["get-plan", "update-day", "swap-days", "add-shopping-item",
             "remove-shopping-item", "flag-staple", "capture-inbox"]


def test_chat_prompt_documents_every_m2a_verb():
    for verb in M2A_VERBS:
        assert verb in PROMPT, f"chat.md must document {verb}"
    assert ".venv/bin/python state_api.py" in PROMPT  # exact allowlisted prefix


def test_chat_prompt_is_persona_neutral():
    assert "小當家" not in PROMPT   # voice arrives only via {persona_pack}


def test_chat_prompt_dropped_readonly_rule():
    assert "唯讀" not in PROMPT


def test_chat_prompt_keeps_all_placeholders():
    for ph in ["{persona_pack}", "{today}", "{weekday}", "{week_plan}",
               "{preferences}", "{cookbook_index}", "{shopping_open}",
               "{history}", "{messages}"]:
        assert ph in PROMPT
