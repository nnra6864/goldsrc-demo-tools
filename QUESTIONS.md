# Questions

Open questions for the owner. Agents: add one when something is the owner's call, then carry on with other work. Owner: answer inline, the agent moves the answer into the docs and removes the question.

## Voice packets with a bad CRC (2026-11-18)

The Rust tool computes the Steam voice CRC but decodes the packet either way, without saying anything. None of the 426 test packets has a bad CRC. What should we do with one?

- **(a) Decode it and warn** (count and list them in the report; exit code unaffected). What the code does now, closest to the Rust tool.
- (b) Drop it and count it as lost voice (exit 3 without `--lenient`).
- (c) Decode it, warn, and treat it as partial (exit 3 without `--lenient`).

Answer:
