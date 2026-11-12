import re


def extract_enum(source, name):
    """Stop at the top-level closing brace so neighboring types stay outside probes."""
    match = re.search(rf"^enum {re.escape(name)}\b.*?^}}", source, re.MULTILINE | re.DOTALL)
    if match is None:
        raise AssertionError(f"could not extract {name}")
    return match[0] + "\n"
