# 🐍✂️ PyOpal [![Stars](https://img.shields.io/github/stars/althonos/pyopal.svg?style=social&maxAge=3600&label=Star)](https://github.com/althonos/pyopal/stargazers)

*[Cython](https://cython.org/) bindings and Python interface to [Opal](https://github.com/Martinsos/opal), a SIMD-accelerated database search aligner.*

[![Actions](https://img.shields.io/github/workflow/status/althonos/pyopal/Test/main?logo=github&style=flat-square&maxAge=300)](https://github.com/althonos/pyopal/actions)
<!-- [![Coverage](https://img.shields.io/codecov/c/gh/althonos/pyopal?style=flat-square&maxAge=3600&logo=codecov)](https://codecov.io/gh/althonos/pyopal/)
[![License](https://img.shields.io/badge/license-MIT-blue.svg?style=flat-square&maxAge=2678400)](https://choosealicense.com/licenses/mit/)
[![PyPI](https://img.shields.io/pypi/v/pyopal.svg?style=flat-square&maxAge=3600&logo=PyPI)](https://pypi.org/project/pyopal)
[![Bioconda](https://img.shields.io/conda/vn/bioconda/pyopal?style=flat-square&maxAge=3600&logo=anaconda)](https://anaconda.org/bioconda/pyopal)
[![AUR](https://img.shields.io/aur/version/python-pyopal?logo=archlinux&style=flat-square&maxAge=3600)](https://aur.archlinux.org/packages/python-pyopal)
[![Wheel](https://img.shields.io/pypi/wheel/pyopal.svg?style=flat-square&maxAge=3600)](https://pypi.org/project/pyopal/#files)
[![Python Versions](https://img.shields.io/pypi/pyversions/pyopal.svg?style=flat-square&maxAge=600&logo=python)](https://pypi.org/project/pyopal/#files)
[![Python Implementations](https://img.shields.io/pypi/implementation/pyopal.svg?style=flat-square&maxAge=600&label=impl)](https://pypi.org/project/pyopal/#files)
[![Source](https://img.shields.io/badge/source-GitHub-303030.svg?maxAge=2678400&style=flat-square)](https://github.com/althonos/pyopal/)
[![Mirror](https://img.shields.io/badge/mirror-EMBL-009f4d?style=flat-square&maxAge=2678400)](https://git.embl.de/larralde/pyopal/)
[![Issues](https://img.shields.io/github/issues/althonos/pyopal.svg?style=flat-square&maxAge=600)](https://github.com/althonos/pyopal/issues)
[![Docs](https://img.shields.io/readthedocs/pyopal/latest?style=flat-square&maxAge=600)](https://pyopal.readthedocs.io)
[![Changelog](https://img.shields.io/badge/keep%20a-changelog-8A0707.svg?maxAge=2678400&style=flat-square)](https://github.com/althonos/pyopal/blob/main/CHANGELOG.md)
[![Downloads](https://img.shields.io/badge/dynamic/json?style=flat-square&color=303f9f&maxAge=86400&label=downloads&query=%24.total_downloads&url=https%3A%2F%2Fapi.pepy.tech%2Fapi%2Fprojects%2Fpyopal)](https://pepy.tech/project/pyopal) -->


## 🗺️ Overview

[Opal](https://github.com/Martinsos/opal) is a sequence aligner enabling fast
sequence similarity search using either of the Smith-Waterman, semi-global or
Needleman-Wunsch algorithms.

PyOpal is a Python module that provides bindings to [Opal](https://github.com/Martinsos/opal)
using [Cython](https://cython.org/). It implements a user-friendly, Pythonic
interface to query a database of sequences and access the search results. It
interacts with the Opal interface rather than with the CLI, which has the
following advantages:

- **single dependency**: PyOpal is distributed as a Python package, so you
  can add it as a dependency to your project, and stop worrying about the
  Opal binary being present on the end-user machine.
- **no intermediate files**: Everything happens in memory, in a Python object
  you control, so you don't have to invoke the Opal CLI using a sub-process
  and temporary files.
- **better portability**: Opal uses SIMD to accelerate alignment scoring, but
  doesn't support dynamic dispatch, so it has to be compiled on the local
  machine to be able to use the full capabilities of the local CPU. PyOpal
  ships several versions of Opal instead, each compiled with different target
  features, and selects the best one for the local platform at runtime.


## 🔧 Installing

PyOpal is available for all modern versions (3.6+), with no external dependencies.

It can be installed directly from [PyPI](https://pypi.org/project/pyopal/),
which hosts some pre-built wheels for the x86-64 architecture (Linux/OSX)
and the Aarch64 architecture (Linux only), as well as the code required to compile
from source with Cython:
```console
$ pip install pyopal
```

<!-- Otherwise, PyOpal is also available as a [Bioconda](https://bioconda.github.io/)
package:
```console
$ conda install -c bioconda pyopal
``` -->

## 💡 Example

Create a database from some reference sequences:
```python
import pyopal

database = pyopal.Database([
    "MESILDLQELETSEEESALMAASTVSNNC",                         # goadvionin A
    "MKKAVIVENKGCATCSIGAACLVDGPIPDFEIAGATGLFGLWG",           # subtilosin A
    "MAGFLKVVQILAKYGSKAVQWAWANKGKILDWINAGQAIDWVVEKIKQILGIK", # lacticin Z
    "MTQIKVPTALIASVHGEGQHLFEPMAARCTCTTIISSSSTF",             # plantazolicin
])
```

Then search it with a query sequence, and show the target sequence with the
highest score:
```python
results = database.search("MAGFLKVVQLLAKYGSKAVQWAWANKGKILDWLNAGQAIDWVVSKIKQILGIK")
best = max(results, key=lambda result: result.score)
print(best.score, best.target_index, database[best.target_index])
```

You can also get the alignment for every target, but this must be enabled
when searching the database:
```python
results = database.search("MESVLDLQELETSEEESALMAASTISQNC", mode="full", algorithm="nw")
for result in results:
    print(result.score, result.identity(), result.cigar())
```

<!-- ## 🧶 Thread-safety -->


<!-- ## ⏱️ Benchmarks -->


## 💭 Feedback

### ⚠️ Issue Tracker

Found a bug ? Have an enhancement request ? Head over to the [GitHub issue tracker](https://github.com/althonos/pyopal/issues)
if you need to report or ask something. If you are filing in on a bug,
please include as much information as you can about the issue, and try to
recreate the same bug in a simple, easily reproducible situation.


### 🏗️ Contributing

Contributions are more than welcome! See
[`CONTRIBUTING.md`](https://github.com/althonos/pyopal/blob/main/CONTRIBUTING.md)
for more details.


## 📋 Changelog

This project adheres to [Semantic Versioning](http://semver.org/spec/v2.0.0.html)
and provides a [changelog](https://github.com/althonos/pyopal/blob/main/CHANGELOG.md)
in the [Keep a Changelog](http://keepachangelog.com/en/1.0.0/) format.


## ⚖️ License

This library is provided under the [MIT License](https://choosealicense.com/licenses/mit/).
Opal is developed by [Martin Šošić](https://github.com/Martinsos) and is distributed under the
terms of the MIT License as well. See `vendor/opal/LICENSE` for more information.
The `cpu_features` library was written by [Guillaume Chatelet](https://github.com/gchatelet) and is
licensed under the terms of the [Apache License 2.0](https://choosealicense.com/licenses/apache-2.0/).
See `vendor/cpu_features/LICENSE` for more information.

*This project is in no way not affiliated, sponsored, or otherwise endorsed
by the [Opal authors](https://github.com/Martinsos). It was developed
by [Martin Larralde](https://github.com/althonos/) during his PhD project
at the [European Molecular Biology Laboratory](https://www.embl.de/) in
the [Zeller team](https://github.com/zellerlab).*
