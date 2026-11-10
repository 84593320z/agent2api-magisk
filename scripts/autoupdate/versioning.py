"""Upstream version parsing shared by the trusted sync stages.

Stable releases are ``X.Y.Z``; a prerelease adds a semver suffix such as
``3.5.0-beta.1``. Ordering follows semver precedence, so ``3.5.0`` always
outranks its own prereleases while ``3.5.0-beta.1`` still outranks ``3.4.2``.
"""
import re

NUMBER = r'(?:0|[1-9][0-9]*)'
STABLE = NUMBER + r'\.' + NUMBER + r'\.' + NUMBER
IDENTIFIER = r'[0-9A-Za-z-]+'
PRERELEASE = IDENTIFIER + r'(?:\.' + IDENTIFIER + r')*'
STABLE_RE = re.compile(r'v?' + STABLE + r'\Z')
VERSION_RE = re.compile(r'v?' + STABLE + r'(?:-' + PRERELEASE + r')?\Z')
_PARTS = re.compile(r'v?(?P<stable>' + STABLE + r')(?:-(?P<pre>' + PRERELEASE + r'))?\Z')


def split(text):
    """Return (numbers, prerelease identifiers or None); reject anything else."""
    match = _PARTS.fullmatch(text) if isinstance(text, str) else None
    if match is None:
        raise ValueError('not a canonical upstream version: %r' % (text,))
    numbers = tuple(int(part) for part in match.group('stable').split('.'))
    pre = match.group('pre')
    return numbers, (tuple(pre.split('.')) if pre else None)


def numbers(text):
    """Numeric major/minor/patch, used for Android versionCode derivation."""
    return split(text)[0]


def prerelease(text):
    """True when the version carries a semver prerelease suffix."""
    return split(text)[1] is not None


def normalize(text):
    """Canonical version string without the tag's leading ``v``."""
    split(text)
    return text[1:] if text.startswith('v') else text


def key(text):
    """Sortable semver precedence: stable > its prereleases, numeric ids < alnum."""
    nums, pre = split(text)
    if pre is None:
        return nums + (1, ())
    return nums + (0, tuple((0, int(part)) if part.isdigit() else (1, part) for part in pre))
