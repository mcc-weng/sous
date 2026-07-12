from sous_worker import context
from tests.conftest import SANDBOX

TEMPLATE = (
    "{persona_pack}\nToday is {today} ({weekday}).\n"
    "PLAN:\n{week_plan}\nPREFS:\n{preferences}\nCOOKBOOK:\n{cookbook_index}\n"
    "SHOPPING:\n{shopping_open}\nHISTORY:\n{history}\nNEW:\n{messages}"
)


def test_fetch_context_renders_seeded_week(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    assert "蔥香雞腿飯" in ctx["week_plan"]
    assert "batch" in ctx["week_plan"]           # mode tags rendered
    assert "不吃香菜" in ctx["preferences"]
    assert "麻婆豆腐" in ctx["cookbook_index"]
    assert "chicken thigh fillets" in ctx["shopping_open"]
    assert "小當家" in ctx["household"]["prompt_pack"]


def test_history_renders_last_messages_oldest_first(conn):
    for i in range(3):
        conn.execute(
            "insert into chat_messages (household_id, sender, content) "
            "values (%s, 'user', %s)", (SANDBOX, f"msg{i}"),
        )
    ctx = context.fetch_context(conn, SANDBOX, history_limit=2)
    assert "msg0" not in ctx["history"]
    assert ctx["history"].index("msg1") < ctx["history"].index("msg2")


def test_build_chat_prompt_substitutes_everything(conn):
    ctx = context.fetch_context(conn, SANDBOX)
    prompt = context.build_chat_prompt(TEMPLATE, ctx, "user: 今晚吃什麼?")
    assert "今晚吃什麼?" in prompt
    assert "蔥香雞腿飯" in prompt
    assert "{" not in prompt.replace("{}", "")  # no unsubstituted placeholders


def test_checked_shopping_items_excluded(conn):
    conn.execute(
        "update shopping_items set checked=true where name='basil pesto' "
        "and household_id=%s", (SANDBOX,),
    )
    try:
        ctx = context.fetch_context(conn, SANDBOX)
        assert "basil pesto" not in ctx["shopping_open"]
    finally:
        conn.execute(
            "update shopping_items set checked=false where household_id=%s", (SANDBOX,),
        )
