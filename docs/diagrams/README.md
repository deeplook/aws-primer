# Diagrams

Archify diagrams live with each spike:

    src/<spike>/diagrams/archify/<type>-<slug>.json   tracked sources (type: architecture, sequence, dataflow, lifecycle, workflow)
    src/<spike>/diagrams/<type>-<slug>.html           tracked, interactive; download to open locally
    src/<spike>/diagrams/<type>-<slug>.light.png      tracked README preview
    src/<spike>/build/diagrams/archify/               ignored receipts, dark PNGs and intermediates

`make SPIKE=spike-1 diagrams-archify` renders and publishes one spike; `make diagrams` does all of them. Rendering needs Node 18+, a local Chrome and uv, not an LLM. Rewriting a source after code changes does need authoring work.

Sources cite files with line ranges and pin `meta.repository.revision`. The check reads committed bytes at that revision, so commit the cited files, then set the revision to the new commit.
