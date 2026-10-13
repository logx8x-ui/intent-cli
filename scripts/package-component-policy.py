#!/usr/bin/env python3
"""Pin every Installer bundle to the launch payload's exact destination."""
from pathlib import PurePosixPath, Path
import plistlib
import sys

APP = 'Applications/Intent.app'


def fixed_components(components):
    if not isinstance(components, list) or not components:
        raise ValueError('Installer component analysis must be a nonempty array.')
    found_app = False

    def visit(items):
        nonlocal found_app
        for item in items:
            if not isinstance(item, dict):
                raise ValueError('Installer component must be a dictionary.')
            path = item.get('RootRelativeBundlePath')
            if (not isinstance(path, str) or str(PurePosixPath(path)) != path
                    or '..' in PurePosixPath(path).parts
                    or not (path == APP or path.startswith(APP + '/'))):
                raise ValueError('Installer bundle is outside the exact launch app destination.')
            found_app = found_app or path == APP
            item['BundleIsRelocatable'] = False
            item['BundleHasStrictIdentifier'] = True
            children = item.get('ChildBundles', [])
            if not isinstance(children, list):
                raise ValueError('Installer child bundles must be an array.')
            visit(children)

    visit(components)
    if not found_app:
        raise ValueError('Installer analysis did not include the launch app.')
    return components


def main():
    if len(sys.argv) != 3:
        sys.exit('Usage: package-component-policy.py ANALYZED_PLIST FIXED_PLIST')
    source, destination = map(Path, sys.argv[1:])
    fixed = fixed_components(plistlib.loads(source.read_bytes()))
    destination.write_bytes(plistlib.dumps(fixed))


if __name__ == '__main__':
    main()
