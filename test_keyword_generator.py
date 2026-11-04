from PIL import Image

import keyword_generator as kg


class FakeIO:
    """Scripted io: pops answers in order, collects log lines."""
    def __init__(self, answers=None):
        self.answers = list(answers or [])
        self.logs = []

    def ask(self, prompt, secret=False):
        return self.answers.pop(0)

    def log(self, msg):
        self.logs.append(msg)

    def image(self, card_id, path):
        pass

    def result(self, *a):
        pass


def test_parse_board_id():
    assert kg.parse_board_id("https://trello.com/b/AbCd1234/my-board") == "AbCd1234"
    assert kg.parse_board_id("https://trello.com/b/AbCd1234/my-board?filter=x") == "AbCd1234"
    assert kg.parse_board_id("AbCd1234") == "AbCd1234"


def test_select_list():
    lists = [{"id": "a1", "name": "To Do"}, {"id": "b2", "name": "Done"}]
    assert kg.select_list(lists, FakeIO(["2"])) == "b2"            # by number
    assert kg.select_list(lists, FakeIO(["to do"])) == "a1"        # name, case-insensitive
    assert kg.select_list(lists, FakeIO(["9"])) is None            # out of range


def test_extract_sku():
    io = FakeIO()
    assert kg.extract_sku_from_title("[AB12] Cute mug", io) == "[AB12]"
    assert kg.extract_sku_from_title("no sku here", io) == ""


def test_get_image_urls_mode():
    card = {
        "cover": {"idAttachment": "c1"},
        "attachments": [
            {"id": "x0", "mimeType": "image/png", "url": "u0"},
            {"id": "c1", "mimeType": "image/jpeg", "url": "cover"},
            {"id": "d2", "mimeType": "application/pdf", "url": "doc"},  # not an image
        ],
    }
    assert kg.get_image_urls_from_card(card, "cover") == ["cover"]       # cover only
    assert kg.get_image_urls_from_card(card, "all") == ["cover", "u0"]   # cover first, pdf dropped
    assert kg.get_image_urls_from_card({"attachments": []}, "cover") == []


def test_merge_grid_downscales():
    imgs = [Image.new("RGB", (2000, 2000), (i * 30, 0, 0)) for i in range(4)]
    grid = kg.merge_grid(imgs, cell=512, max_edge=1280)
    assert max(grid.size) <= 1280            # downscaled below the cap
    assert grid.mode == "RGB"


def test_parse_title_tags():
    io = FakeIO()
    fenced = '```json\n{"title": "Red Mug", "tags": ["a", "b"]}\n```'
    assert kg.parse_title_tags(fenced, io) == ("Red Mug", ["a", "b"])
    assert kg.parse_title_tags("no json at all", io) == (None, None)
    assert kg.parse_title_tags('{"title": "", "tags": []}', io) == (None, None)


def test_build_prompt_optional_extra():
    base = kg.build_prompt("a.jpg")
    assert kg.SEO_PROMPT in base and "Additional instructions" not in base
    assert kg.build_prompt("a.jpg", "   ") == base               # blank = default
    withx = kg.build_prompt("a.jpg", "focus on wedding gifts")
    assert "Additional instructions" in withx and "focus on wedding gifts" in withx


def test_pipeline_ask_order():
    # web_studio pre-fills answers in this exact order: mode, prompt, board, list.
    kg.check_claude_connection = lambda io: True
    kg.configure_credentials = lambda io: None
    kg.TRELLO_API_KEY = kg.TRELLO_TOKEN = "x"
    kg.get_lists = lambda board, io: [{"id": "L1", "name": "To Do"}] if board == "B1" else None
    kg.get_cards_in_list = lambda list_id, io: []
    for prompt in ["", "focus on wedding gifts"]:   # skipped and filled
        io = FakeIO(["1", prompt, "B1", "1"])
        assert kg.run_pipeline(io) == 0
        assert io.answers == []  # all 4 answers consumed in order


if __name__ == "__main__":
    for name, fn in sorted(globals().items()):
        if name.startswith("test_"):
            fn()
    print("OK")
