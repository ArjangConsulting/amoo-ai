"""Release packaging uses the same simulator signing step as local companion builds."""
import pathlib
import runpy

runpy.run_path(str(pathlib.Path(__file__).resolve().parent.parent /
                   'CompanionApps/iOS/sign-simulator-products.py'), run_name='__main__')
