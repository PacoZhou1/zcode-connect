# Synthetic relay fixtures

Four small protocol fixtures used by the Swift self-tests. These are deterministic test inputs, not captured conversations, pairing credentials, or debugging transcripts. Historical execution reports and source-inspection metadata have been removed.

The test scripts copy inputs into a temporary directory and clean up outputs when they finish. They do not write new logs into this fixture directory.
