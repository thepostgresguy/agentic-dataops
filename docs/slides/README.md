# Slides

`workshop.md` is the deck for the SRE Day NY 2026 session, written in
[Marp](https://marp.app/) markdown. Slides are separated by `---`, and speaker
notes are the `<!-- ... -->` comments.

## Present or export

Use the pinned Marp CLI (no install needed):

```bash
# Live preview in the browser while editing
npx @marp-team/marp-cli@4.2.3 -s docs/slides

# Export (PDF and PPTX need Chrome or Chromium installed)
npx @marp-team/marp-cli@4.2.3 docs/slides/workshop.md --html -o workshop.html
npx @marp-team/marp-cli@4.2.3 docs/slides/workshop.md --pdf  -o workshop.pdf
npx @marp-team/marp-cli@4.2.3 docs/slides/workshop.md --pptx -o workshop.pptx
```

The VS Code extension "Marp for VS Code" also previews and exports it.

## Keep it honest

The deck states what is built and what is deferred (see the monitoring and
rollback slide). Update it when that changes, and keep it aligned with
[`../workshop-abstract.md`](../workshop-abstract.md).
