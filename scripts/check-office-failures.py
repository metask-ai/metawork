"""XLSX postconditions retained after retiring the old process wrappers.

Actual conversion/cancellation/publication checks live in check-office-engine.
"""
import importlib.util
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
import zipfile
from openpyxl import Workbook

assets = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location('office_formulas', assets/'xlsx/scripts/office/formulas.py')
checks = importlib.util.module_from_spec(spec)
spec.loader.exec_module(checks)


class RecalculationPostconditions(unittest.TestCase):
    def fixture(self, directory, formula='=1+1'):
        path=Path(directory)/'working.xlsx'
        workbook=Workbook()
        workbook.active['A1']=formula
        workbook.active['B1']='Plain text mentioning #REF!'
        workbook.save(path)
        workbook.close()
        return path

    def cache(self, path, *, kind=None, value='2', missing=False):
        with zipfile.ZipFile(path) as archive:
            parts={name:archive.read(name) for name in archive.namelist()}
        namespace='{http://schemas.openxmlformats.org/spreadsheetml/2006/main}'
        root=ET.fromstring(parts['xl/worksheets/sheet1.xml'])
        cell=root.find('.//'+namespace+'c')
        if kind: cell.set('t',kind)
        if missing: cell.remove(cell.find(namespace+'v'))
        else: cell.find(namespace+'v').text=value
        parts['xl/worksheets/sheet1.xml']=ET.tostring(root)
        with zipfile.ZipFile(path,'w',zipfile.ZIP_DEFLATED) as archive:
            for name,data in parts.items():archive.writestr(name,data)

    def test_formula_identity_and_valid_cache(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.fixture(directory)
            expected=checks._formulas(path)
            self.cache(path)
            checks._check_formula_caches(path)
            self.assertEqual(checks._formulas(path),expected)
            self.assertEqual(checks._summary(path,1),{'status':'success','total_errors':0,'error_summary':{},'total_formulas':1})

    def test_missing_and_empty_numeric_cache_are_refused(self):
        with tempfile.TemporaryDirectory() as directory:
            for options in ({'missing':True},{'value':None}):
                path=self.fixture(directory)
                self.cache(path,**options)
                with self.assertRaisesRegex(ValueError,'Missing recalculated formula cache'):
                    checks._check_formula_caches(path)

    def test_empty_string_is_a_real_cached_value(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.fixture(directory,'=""')
            self.cache(path,kind='str',value=None)
            checks._check_formula_caches(path)
            self.assertEqual(checks._summary(path,1)['status'],'success')

    def test_actual_errors_are_not_confused_with_documentation_strings(self):
        with tempfile.TemporaryDirectory() as directory:
            path=self.fixture(directory,'=1/0')
            self.cache(path,kind='e',value='#DIV/0!')
            checks._check_formula_caches(path)
            self.assertEqual(checks._summary(path,1),{'status':'errors_found','total_errors':1,'error_summary':{'#DIV/0!':{'count':1,'locations':['Sheet!A1']}},'total_formulas':1})

    def test_sparse_far_coordinates_are_bounded_before_dense_iteration(self):
        with tempfile.TemporaryDirectory() as directory:
            path=Path(directory)/'far.xlsx'
            workbook=Workbook()
            workbook.active['A1000001']='=1+1'
            workbook.save(path)
            workbook.close()
            with self.assertRaisesRegex(ValueError,'cell budget'):
                checks._formulas(path)


if __name__=='__main__':unittest.main()
