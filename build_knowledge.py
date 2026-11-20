#!/usr/bin/env python3
"""Quét toàn bộ list/card (title + tags) của 1 board Trello, nhờ Claude rút ra
cách viết của shop, ghi vào knowledge.md. keyword_generator tự đọc file này
mỗi lần viết title/tags.

  python build_knowledge.py [board link/ID/tên]     # hoặc double-click build_knowledge.bat

Phần dưới dòng USER_MARK trong knowledge.md là rules của người dùng: quét lại
KHÔNG ghi đè phần đó (file cũ còn được backup ra knowledge.md.bak).
"""
import os
import shutil
import subprocess
import sys

import keyword_generator as kg

USER_MARK = "## RULES CỦA TÔI"
USER_TEMPLATE = f"""{USER_MARK} (giữ nguyên khi quét lại — thêm rules của bạn bên dưới)

<!-- Ví dụ:
- Title luôn bắt đầu bằng "Personalized" nếu sản phẩm khắc tên.
- Không dùng từ "cheap".
-->
"""
# ponytail: cap so the prompt stays ~50K tokens; sample smarter if boards get huge.
MAX_CARDS = 400
CLAUDE_TIMEOUT = 600

ANALYZE_PROMPT = """Below are existing Etsy listings from one shop, exported from its Trello board,
grouped by Trello list. Each line is: card title (starts with [SKU]) || tags (comma separated).

Study HOW this shop writes titles and tags, then write a concise style guide that another
AI will follow to write new titles/tags in exactly this style. Cover, with short real
examples copied from the data:
- Title: typical length, opening phrase pattern, word order, separators ("," or "|"),
  capitalization, recurring phrases/words, what is never used.
- Tags: count, length, casing, phrase patterns, recurring tags, what topics they cover.
- Differences between lists/product types, if any.
- A short "Do / Don't" checklist.

Write in Vietnamese (keep the English examples as-is), Markdown, start with "## ",
under 6000 characters. Output ONLY the guide, no preamble.

DATA:
"""


def fetch_cards(board):
    """[(list name, card name, tags text)] for every open card on the board."""
    io = kg.ConsoleIO()
    lists = kg.get_lists(kg.parse_board_id(board), io)
    if not lists:
        return None
    names = {l["id"]: l["name"] for l in lists}
    r = kg._trello_get(f"boards/{lists[0]['idBoard']}/cards", fields="name,desc,idList")
    r.raise_for_status()
    order = {lid: i for i, lid in enumerate(names)}
    cards = sorted(r.json(), key=lambda c: order.get(c["idList"], len(order)))
    return [(names.get(c["idList"], "?"), c["name"].strip(), " ".join(c["desc"].split()))
            for c in cards if c["name"].strip()]


def format_data(rows):
    """Group rows by list; cards that already have tags first (they are the examples)."""
    rows = sorted(rows, key=lambda r: not r[2])[:MAX_CARDS]
    out, by_list = [], {}
    for lst, name, tags in rows:
        by_list.setdefault(lst, []).append(f"{name} || {tags[:300]}")
    for lst, lines in by_list.items():
        out.append(f"\n### List: {lst}")
        out.extend(lines)
    return "\n".join(out)


def ask_claude(prompt):
    claude = kg.find_claude()
    if not claude:
        sys.exit("Không tìm thấy 'claude' CLI. Chạy run.bat một lần để cài + đăng nhập.")
    # Prompt goes on stdin: board data is far past Windows' 32K command-line cap.
    proc = subprocess.run(
        [claude, "-p", "--model", kg.CLAUDE_MODEL],
        input=prompt, capture_output=True, text=True, encoding="utf-8",
        errors="replace", timeout=CLAUDE_TIMEOUT,
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        sys.exit(f"Claude lỗi (exit {proc.returncode}): {(proc.stderr or proc.stdout)[:500]}")
    return proc.stdout.strip()


def user_section(existing):
    """Everything from USER_MARK on in the old file, or the empty template."""
    i = ("\n" + existing).find("\n" + USER_MARK)  # heading at line start, not the header comment
    return existing[i:].strip() + "\n" if i >= 0 else USER_TEMPLATE


def compose(guide, existing, board, n_cards):
    return (
        f"# Knowledge: cách viết title + tags của shop\n\n"
        f"<!-- Tự sinh bởi build_knowledge.py từ board '{board}' ({n_cards} card). "
        f"Phần trên {USER_MARK} sẽ bị ghi đè khi quét lại; sửa/thêm rules ở phần dưới. -->\n\n"
        f"{guide.strip()}\n\n{user_section(existing)}"
    )


def main():
    kg.configure_credentials(kg.ConsoleIO())
    board = " ".join(sys.argv[1:]).strip() or input("Trello board (link, ID hoặc tên): ").strip()
    rows = fetch_cards(board)
    if not rows:
        sys.exit("Board không có card nào (hoặc không đọc được board).")
    tagged = sum(1 for r in rows if r[2])
    print(f"Đã quét {len(rows)} card ({tagged} card có tags). Đang nhờ Claude phân tích…")
    guide = ask_claude(ANALYZE_PROMPT + format_data(rows))

    path = kg.KNOWLEDGE_PATH
    existing = kg.load_knowledge(path)
    if existing:
        shutil.copyfile(path, path + ".bak")
    with open(path, "w", encoding="utf-8") as f:
        f.write(compose(guide, existing, board, min(len(rows), MAX_CARDS)))
    print(f"Xong: {path}\nMở file để xem / thêm rules ở mục '{USER_MARK}'.")
    if os.name == "nt":
        os.startfile(path)  # open it in the default editor


if __name__ == "__main__":
    try:
        main()
    except (EOFError, KeyboardInterrupt):
        print("\nĐã huỷ.")
    except Exception as e:  # keep the console window readable instead of a raw crash
        print(f"Lỗi: {e}")
