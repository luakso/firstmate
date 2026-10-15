# Claude Code 2.1.296 slash-command menu capture

`slash-exit-menu.txt` is the bottom of a Claude Code 2.1.296 pane on herdr, captured on 2026-10-15 with `/exit` typed and not submitted.
Claude opens its command menu under the composer: the composer row shows the typed command, and the menu below lists that command as its highlighted first entry.
The transcript above the composer was dropped, keeping only the composer, its rule pair, and the menu.
`tests/fm-composer-lib.test.sh` and `tests/fm-backend-herdr.test.sh` build their slash-menu regressions from it.
