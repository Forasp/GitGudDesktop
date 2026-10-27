# Turn-taking model

Bragi's turn-taking model: MiniLM-L12-H384 (Microsoft, MIT) fine-tuned to
tell when you're done talking, as int8 ONNX, with its `vocab.txt`.

It isn't shipped with the app. Bragi's first-time setup downloads it with the
voice models, checked against the sizes and SHA-256 pinned in
`resources/uis/bragi/scripts/bragi/voicemodels.lua`, from the
`bragi-decide-1` tag. A new model goes in under a new tag, with the pins.
