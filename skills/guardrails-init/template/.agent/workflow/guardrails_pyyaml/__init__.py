"""PyYAML's pure-Python reader, scanner and parser, vendored for .agent/workflow/check.py.

The other files in this directory are byte-identical copies of lib/yaml/{error,tokens,events,reader,scanner,
parser}.py and LICENSE from the PyYAML sdist pinned in scripts/vendored-pyyaml/requirements.txt of the kit;
scripts/vendored-pyyaml/check.sh compares them with that release in the kit's CI. This file is the kit's own:
upstream's __init__.py imports the constructor, which builds objects out of documents, and the workflow check
only reads the parser's events.
"""
