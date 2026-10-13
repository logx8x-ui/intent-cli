#!/usr/bin/env python3
import copy
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location('policy', Path(__file__).with_name('package-component-policy.py'))
policy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(policy)


class ComponentPolicy(unittest.TestCase):
    def test_nested_bundles_cannot_relocate(self):
        components = [{'RootRelativeBundlePath': policy.APP,
                       'BundleIsRelocatable': True, 'BundleIsVersionChecked': True,
                       'ChildBundles': [{'RootRelativeBundlePath': policy.APP + '/Contents/Frameworks/Sparkle.framework',
                                         'BundleIsRelocatable': True}]}]
        before = copy.deepcopy(components)
        fixed = policy.fixed_components(components)
        self.assertFalse(fixed[0]['BundleIsRelocatable'])
        self.assertFalse(fixed[0]['ChildBundles'][0]['BundleIsRelocatable'])
        self.assertTrue(fixed[0]['BundleHasStrictIdentifier'])
        self.assertTrue(fixed[0]['ChildBundles'][0]['BundleHasStrictIdentifier'])
        self.assertEqual(fixed[0]['BundleIsVersionChecked'], before[0]['BundleIsVersionChecked'])
        self.assertEqual(fixed[0]['RootRelativeBundlePath'], before[0]['RootRelativeBundlePath'])
        self.assertEqual(policy.fixed_components(copy.deepcopy(fixed)), fixed)

    def test_refuse_missing_app(self):
        with self.assertRaises(ValueError):
            policy.fixed_components([{'RootRelativeBundlePath': policy.APP + '/Contents/Helpers'}])

    def test_refuse_malformed_or_foreign_components(self):
        cases = [[], {}, [None], [{}], [{'RootRelativeBundlePath': '/'+policy.APP}],
                 [{'RootRelativeBundlePath': policy.APP + '/../../Other.app'}],
                 [{'RootRelativeBundlePath': 'Applications/Test Intent.app'}],
                 [{'RootRelativeBundlePath': policy.APP, 'ChildBundles': {}}],
                 [{'RootRelativeBundlePath': policy.APP, 'ChildBundles': [{'RootRelativeBundlePath': 'Applications/Foreign.app'}]}]]
        for case in cases:
            with self.subTest(case=case), self.assertRaises(ValueError):
                policy.fixed_components(case)


if __name__ == '__main__': unittest.main()
