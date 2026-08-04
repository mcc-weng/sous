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


RITUAL_PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "ritual.md").read_text()

RITUAL_VERBS = ["get-plan", "update-day", "swap-days", "add-shopping-item",
               "remove-shopping-item", "flag-staple", "capture-inbox",
               "set-plan", "clear-inbox", "cancel-ritual"]

RITUAL_PLACEHOLDERS = ["{persona_pack}", "{today}", "{weekday}", "{target_week_of}",
                       "{current_week_plan}", "{recent_weeks}", "{inbox}",
                       "{verdicts_recent}", "{staples_flagged}", "{preferences}",
                       "{cookbook_index}", "{history}", "{messages}"]


def test_ritual_prompt_documents_every_verb():
    for verb in RITUAL_VERBS:
        assert verb in RITUAL_PROMPT, f"ritual.md must document {verb}"


def test_ritual_prompt_is_persona_neutral():
    assert "小當家" not in RITUAL_PROMPT


def test_skill_file_is_persona_neutral():
    skill_path = pathlib.Path(__file__).resolve().parent.parent / "skills" / "plan-week.md"
    assert "小當家" not in skill_path.read_text()


def test_ritual_prompt_keeps_all_placeholders():
    for ph in RITUAL_PLACEHOLDERS:
        assert ph in RITUAL_PROMPT, f"ritual.md must keep {ph}"


def test_ritual_prompt_references_the_skill_file():
    assert "skills/plan-week.md" in RITUAL_PROMPT


def test_ritual_prompt_states_two_touchpoint_rule():
    assert "兩" in RITUAL_PROMPT and ("觸點" in RITUAL_PROMPT or "問題" in RITUAL_PROMPT)


RECIPE_INTAKE_PROMPT = (pathlib.Path(__file__).resolve().parent.parent / "prompts" / "recipe_intake.md").read_text()

RECIPE_INTAKE_VERBS = ["save-recipe", "capture-inbox"]
RECIPE_INTAKE_PLACEHOLDERS = ["{persona_pack}", "{today}", "{weekday}", "{url}",
                              "{by}", "{prefetched_context}"]


def test_recipe_intake_prompt_documents_every_verb():
    for verb in RECIPE_INTAKE_VERBS:
        assert verb in RECIPE_INTAKE_PROMPT, f"recipe_intake.md must document {verb}"
    assert ".venv/bin/python state_api.py" in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_is_persona_neutral():
    assert "小當家" not in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_keeps_all_placeholders():
    for ph in RECIPE_INTAKE_PLACEHOLDERS:
        assert ph in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_documents_structured_quantities():
    assert "qty_value" in RECIPE_INTAKE_PROMPT
    assert "qty_unit" in RECIPE_INTAKE_PROMPT


def test_recipe_intake_prompt_documents_servings_flag():
    assert "--servings" in RECIPE_INTAKE_PROMPT
