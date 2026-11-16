# Benign test project for the pip-check recipe: its build code starts a process and writes a
# file outside the install folder.
import subprocess

from setuptools import setup

with open("/tmp/pip-marker", "w") as f:
    f.write("marker\n")
subprocess.run(["id"], stdout=subprocess.DEVNULL)

setup(name="fc-test-pip-pkg", version="0.0.1", py_modules=[])
