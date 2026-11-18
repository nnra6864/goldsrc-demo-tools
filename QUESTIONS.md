# Questions

Open questions for the owner. Agents: add one when something is the owner's call, then carry on with other work. Owner: answer inline, the agent moves the answer into the docs and removes the question.

## Voice packets with a bad CRC (2026-11-18)

The Rust tool computes the Steam voice CRC but decodes the packet either way, without saying anything. None of the 426 test packets has a bad CRC. What should we do with one?

- **(a) Decode it and warn** (count and list them in the report; exit code unaffected). What the code does now, closest to the Rust tool.
- (b) Drop it and count it as lost voice (exit 3 without `--lenient`).
- (c) Decode it, warn, and treat it as partial (exit 3 without `--lenient`).

Answer:

## Exit code for a demo with no voice (2026-11-18)

The Rust tool exits 1 ("no voice in ...") and writes nothing when nobody spoke; the new tool does the same. Run after every map in the server container, that makes every silent map look like a failure. Should a demo without voice:

- **(a) exit 1, write nothing** (now, like the Rust tool)
- (b) exit 0, write nothing, print a note
- (c) exit 0 and write an `.mka` with no tracks

Answer:
