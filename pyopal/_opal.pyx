# distutils: language = c++
# cython: language_level=3, linetrace=True, binding=True
"""Bindings to Opal, a SIMD-accelerated pairwise sequence aligner.

References:
    - Korpar M., Šošić M., Blažeka D., Šikić M.
      *SW#db: GPU-Accelerated Exact Sequence Similarity Database Search*.
      PLoS One. 2015;10(12):e0145857. Published 2015 Dec 31.
      :doi:`10.1371/journal.pone.0145857`.

"""

# --- C imports ----------------------------------------------------------------

from libc.string cimport memset
from libc.limits cimport UCHAR_MAX
from libcpp.string cimport string
from libcpp.vector cimport vector

from cpython cimport Py_INCREF
from cpython.list cimport PyList_New, PyList_SET_ITEM
from cpython.bytes cimport PyBytes_AsString, PyBytes_FromStringAndSize
from cpython.mem cimport PyMem_Malloc, PyMem_Realloc, PyMem_Free
from _unicode cimport (
    PyUnicode_READY,
    PyUnicode_KIND,
    PyUnicode_DATA,
    PyUnicode_READ,
    PyUnicode_GET_LENGTH,
)

cimport opal
cimport opal.score_matrix
from opal cimport OpalSearchResult

IF NEON_BUILD_SUPPORT:
    from pyopal._opal_neon cimport opalSearchDatabaseNEON
IF SSE2_BUILD_SUPPORT:
    from pyopal._opal_sse2 cimport opalSearchDatabaseSSE2
IF SSE4_BUILD_SUPPORT:
    from pyopal._opal_sse4 cimport opalSearchDatabaseSSE4
IF AVX2_BUILD_SUPPORT:
    from pyopal._opal_avx2 cimport opalSearchDatabaseAVX2

cdef extern from "<cctype>" namespace "std" nogil:
    cdef int toupper(int ch)
    cdef int tolower(int ch)
    cdef bint isalpha(int cht)

cdef extern from "<algorithm>" namespace "std" nogil:
    cdef void reverse[T](T, T)


# --- Python imports -----------------------------------------------------------

import enum
import operator


# --- Constants ----------------------------------------------------------------

cdef dict _OPAL_SEARCH_MODES = {
    "score": opal.OPAL_SEARCH_SCORE,
    "end": opal.OPAL_SEARCH_SCORE_END,
    "full": opal.OPAL_SEARCH_ALIGNMENT,
}

cdef dict _OPAL_OVERFLOW_MODES = {
    "simple": opal.OPAL_OVERFLOW_SIMPLE,
    "buckets": opal.OPAL_OVERFLOW_BUCKETS,
}

cdef dict _OPAL_ALGORITHMS = {
    "nw": opal.OPAL_MODE_NW,
    "hw": opal.OPAL_MODE_HW,
    "ov": opal.OPAL_MODE_OV,
    "sw": opal.OPAL_MODE_SW,
}

cdef dict _OPAL_ALIGNMENT_OPERATION = {
    'M': opal.OPAL_ALIGN_MATCH,
    'D': opal.OPAL_ALIGN_DEL,
    'I': opal.OPAL_ALIGN_INS,
    'X': opal.OPAL_ALIGN_MISMATCH,
}

# --- Runtime CPU detection ----------------------------------------------------

_TARGET_CPU           = TARGET_CPU
_SSE2_RUNTIME_SUPPORT = False
_SSE2_BUILD_SUPPORT   = False
_SSE4_RUNTIME_SUPPORT = False
_SSE4_BUILD_SUPPORT   = False
_AVX2_RUNTIME_SUPPORT = False
_AVX2_BUILD_SUPPORT   = False
_NEON_RUNTIME_SUPPORT = False
_NEON_BUILD_SUPPORT   = False

IF TARGET_CPU == "x86" and TARGET_SYSTEM in ("freebsd", "linux_or_android", "macos", "windows"):
    from cpu_features.x86 cimport GetX86Info, X86Info
    cdef X86Info cpu_info = GetX86Info()
    _SSE2_BUILD_SUPPORT   = SSE2_BUILD_SUPPORT
    _SSE2_RUNTIME_SUPPORT = SSE2_BUILD_SUPPORT and cpu_info.features.sse2 != 0
    _SSE4_BUILD_SUPPORT   = SSE4_BUILD_SUPPORT
    _SSE4_RUNTIME_SUPPORT = SSE4_BUILD_SUPPORT and cpu_info.features.sse4_1 != 0
    _AVX2_BUILD_SUPPORT   = AVX2_BUILD_SUPPORT
    _AVX2_RUNTIME_SUPPORT = AVX2_BUILD_SUPPORT and cpu_info.features.avx2 != 0
ELIF TARGET_CPU == "arm":
    from cpu_features.arm cimport GetArmInfo, ArmInfo
    cdef ArmInfo arm_info = GetArmInfo()
    _NEON_BUILD_SUPPORT   = NEON_BUILD_SUPPORT
    _NEON_RUNTIME_SUPPORT = NEON_BUILD_SUPPORT and arm_info.features.neon != 0
ELIF TARGET_CPU == "aarch64":
    _NEON_BUILD_SUPPORT   = NEON_BUILD_SUPPORT
    _NEON_RUNTIME_SUPPORT = NEON_BUILD_SUPPORT # always runtime support on Aarch64


# --- Type definitions ---------------------------------------------------------

ctypedef unsigned char     digit_t
ctypedef digit_t*          seq_t
ctypedef OpalSearchResult* OpalSearchResult_ptr

ctypedef int (*searchfn_t)(
    unsigned char*,
    int,
    unsigned char**,
    int,
    int*,
    int,
    int,
    int*,
    int,
    OpalSearchResult**,
    const int,
    int,
    int,
) nogil


# --- Sequence encoding --------------------------------------------------------

cdef inline void encode_str(str sequence, char* lut, seq_t* encoded, int* length) except *:
    cdef size_t  i
    cdef char    code
    cdef Py_UCS4 letter

    # make sure the unicode string is in canonical form,
    # --> won't be needed anymore in Python 3.12
    IF SYS_VERSION_INFO_MAJOR <= 3 and SYS_VERSION_INFO_MINOR < 12:
        PyUnicode_READY(sequence)

    cdef int     kind = PyUnicode_KIND(sequence)
    cdef void*   data = PyUnicode_DATA(sequence)
    cdef ssize_t slen = PyUnicode_GET_LENGTH(sequence)

    length[0] = slen
    encoded[0] = <seq_t> PyMem_Malloc(length[0] * sizeof(digit_t))
    if encoded[0] is NULL:
        raise MemoryError("Failed to allocate sequence data")

    with nogil:
        for i in range(length[0]):
            letter = PyUnicode_READ(kind, data, i)
            if not isalpha(letter):
                raise ValueError(f"Character outside ASCII range: {letter}")
            code = lut[<unsigned char> letter]
            if code < 0:
                raise ValueError(f"Non-alphabet character in sequence: {chr(letter)}")
            encoded[0][i] = code


cdef inline void encode_bytes(const unsigned char[:] sequence, char* lut, seq_t* encoded, int* length) except *:
    cdef size_t        i
    cdef char          code
    cdef unsigned char letter

    length[0]  = sequence.shape[0]
    encoded[0] = <seq_t> PyMem_Malloc(length[0] * sizeof(digit_t))
    if encoded[0] is NULL:
        raise MemoryError("Failed to allocate sequence data")

    with nogil:
        for i in range(length[0]):
            letter = <unsigned char> sequence[i]
            code = lut[letter]
            if code < 0:
                raise ValueError(f"Non-alphabet character in sequence: {chr(letter)}")
            encoded[0][i] = code


# --- Python classes -----------------------------------------------------------

class AlignmentOperation(enum.IntEnum):
    Match = 0
    Deletion = 1
    Insertion = 2
    Mismatch = 3

cdef class ScoreMatrix:
    """A score matrix for comparing character matches in sequences.
    """
    cdef opal.score_matrix.ScoreMatrix _mx
    cdef char                          _ahash[UCHAR_MAX]
    cdef char                          _unknown

    @classmethod
    def aa(cls):
        """aa(cls)\n--

        Create a default amino-acid scoring matrix (BLOSUM50).

        """
        cdef int                  i
        cdef char                 unknown
        cdef unsigned char        letter
        cdef const unsigned char* alphabet
        cdef ScoreMatrix          matrix   = ScoreMatrix.__new__(ScoreMatrix)

        matrix._mx = opal.score_matrix.ScoreMatrix.getBlosum50()
        alphabet = matrix._mx.getAlphabet()
        matrix._unknown  = alphabet.find(b'*')

        for i in range(UCHAR_MAX):
            matrix._ahash[i] = matrix._unknown
        for i in range(matrix._mx.getAlphabetLength()):
            letter = alphabet[i]
            matrix._ahash[toupper(letter)] = matrix._ahash[tolower(letter)] = i

        return matrix

    def __cinit__(self):
        cdef int i
        self._unknown = -1
        for i in range(UCHAR_MAX):
            self._ahash[i] = self._unknown

    def __init__(self, str alphabet not None, object matrix not None):
        """__init__(alphabet, matrix)\n--

        Create a new score matrix from the given alphabet and scores.

        Arguments:
            alphabet (`str`): The alphabet of the similarity matrix.
                If the alphabet contains the ``*`` character, it is
                treated as a wildcard for any unknown symbol in the
                query or target sequences.
            matrix (`~numpy.typing.ArrayLike` of `int`): The scoring matrix,
                as a square matrix indexed by the alphabet characters.

        Example:
            Create a new similarity matrix using the HOXD70 scores by
            Chiaromonte, Yap and Miller (:pmid:`11928468`)::

                >>> matrix = ScoreMatrix(
                ...     "ATCG",
                ...     [[  91, -114,  -31, -123],
                ...      [-114,  100, -125,  -31],
                ...      [ -31, -125,  100, -114],
                ...      [-123,  -31, -114,   91]]
                ... )

            Create a new similarity matrix using one of the matrices from
            the `Bio.Align.substitution_matrices` module::

                >>> jones = Bio.Align.substitution_matrices.load('JONES')
                >>> matrix = ScoreMatrix(jones.alphabet, jones)

        """
        cdef int           i
        cdef int           j
        cdef object        row
        cdef int           value
        cdef str           letter
        cdef char          unknown
        cdef int           length    = len(matrix)
        cdef vector[uchar] abcvector = vector[uchar](length, 0)
        cdef vector[int]   scores    = vector[int](length*length, 0)

        if len(set(alphabet)) != len(alphabet):
            raise ValueError("Alphabet contains duplicate letters")
        if len(alphabet) != length:
            raise ValueError("Alphabet must have the same length as matrix")
        if not alphabet.isupper():
            raise ValueError("Alphabet must only contain uppercase letters")
        if not all(len(row) == length for row in matrix):
            raise ValueError("`matrix` must be a square matrix")

        # FIXME: may be required implicitly by SIMD implementations
        # if length > 32:
        #     raise ValueError(f"Cannot use alphabet of more than 32 symbols: {alphabet!r}")

        # copy the alphabet and create a lookup-table for encoding sequences
        self._unknown = alphabet.find("*")
        for i in range(UCHAR_MAX):
            self._ahash[i] = self._unknown
        for i, letter in enumerate(alphabet):
            j = ord(letter)
            abcvector[i] = j
            self._ahash[toupper(j)] = self._ahash[tolower(j)] = i

        # copy the scores
        for i, row in enumerate(matrix):
            for j, value in enumerate(row):
                scores[i*length+j] = value

        # record the matrix
        self._mx = opal.score_matrix.ScoreMatrix(abcvector, scores)


cdef class SearchResult:

    cdef ssize_t          _target_index
    cdef OpalSearchResult _result

    def __cinit__(self):
        self._target_index = -1
        self._result.scoreSet = 0
        self._result.startLocationQuery = -1
        self._result.startLocationTarget = -1
        self._result.endLocationQuery = -1
        self._result.endLocationTarget = -1
        self._result.alignmentLength = 0
        self._result.alignment = NULL

    def __dealloc__(self):
        PyMem_Free(self._result.alignment)

    def __init__(
        self,
        size_t target_index,
        int score,
        *,
        query_end=None,
        target_end=None,
        query_start=None,
        target_start=None,
        str alignment=None,
    ):
        self._target_index = target_index
        self._result.score = score
        self._result.scoreSet = True

        if (query_end is None) != (target_end is None):
            raise ValueError("Both `query_end` and `target_end` must be set")
        if (query_start is None) != (target_start is None):
            raise ValueError("Both `query_start` and `target_start` must be set")

        if query_end is not None:
            self._result.endLocationQuery = query_end
        if target_end is not None:
            self._result.endLocationTarget = target_end
        if query_start is not None:
            self._result.startLocationQuery = query_start
        if target_start is not None:
            self._result.startLocationTarget = query_start
        if alignment is not None:
            self._result.alignmentLength = len(alignment)
            self._result.alignment = <unsigned char*> PyMem_Realloc(self._result.alignment, self._result.alignmentLength * sizeof(unsigned char))
            for i, x in enumerate(alignment):
                self._result.alignment[i] = _OPAL_ALIGNMENT_OPERATION[x]

    def __repr__(self):
        assert self._result.scoreSet

        cdef str ty    = type(self).__name__
        cdef list args = [f"target_index={self._target_index}", f"score={self.score}"]

        if self._result.endLocationQuery >= 0 and self._result.endLocationTarget >= 0:
            args.append(f"query_end={self._result.endLocationQuery!r}")
            args.append(f"target_end={self._result.endLocationTarget!r}")
        if self._result.startLocationQuery >= 0 and self._result.startLocationTarget >= 0:
            args.append(f"query_start={self._result.startLocationQuery!r}")
            args.append(f"target_start={self._result.startLocationTarget!r}")
        if self._result.alignmentLength > 0:
            args.append(f"alignment={self.alignment!r}")
            
        return "{}({})".format(ty, ", ".join(args))

    @property
    def score(self):
        """`int`: The score of the alignment.
        """
        assert self._result.scoreSet
        return self._result.score

    @property
    def query_start(self):
        return None if self._result.startLocationQuery == -1 else self._result.startLocationQuery

    @property
    def query_end(self):
        return None if self._result.endLocationQuery == -1 else self._result.endLocationQuery

    @property
    def target_start(self):
        return None if self._result.startLocationTarget == -1 else self._result.startLocationTarget

    @property
    def target_end(self):
        return None if self._result.endLocationTarget == -1 else self._result.endLocationTarget

    @property
    def target_index(self):
        """`int`: The index of the target in the database.
        """
        assert self._target_index >= 0
        return self._target_index

    @property
    def alignment(self):
        """`str` or `None`: A string used by Opal to encode alignments. 
        """
        cdef bytearray        ali     
        cdef unsigned char[:] view
        cdef Py_UCS4[4]       symbols = ['M', 'D', 'I', 'X']

        if self._result.alignmentLength > 0:
            ali = bytearray(self._result.alignmentLength)
            view = ali
            for i in range(self._result.alignmentLength):
                view[i] = symbols[self._result.alignment[i]]
            return ali.decode('ascii')

        return None

    cpdef str cigar(self):
        """cigar(self)\n--
        
        Create a CIGAR string representing the alignment.

        """
        cdef size_t        i
        cdef unsigned char symbol
        cdef unsigned char current
        cdef size_t        count
        cdef Py_UCS4[3]    symbols = ['M', 'D', 'I']
        cdef list          chunks  = []

        if self._result.alignmentLength == 0 or self._result.alignment is None:
            return None

        count = 0
        current = self._result.alignment[0]
        for i in range(self._result.alignmentLength):
            symbol = self._result.alignment[i] % 3
            if symbol == current:
                count += 1
            else:
                chunks.append(str(count))
                chunks.append(symbols[current])
                current = symbol
                count = 1
        chunks.append(str(count))
        chunks.append(symbols[current])

        return "".join(chunks)


cdef class Database:
    """A database of target sequences.

    Like many biological sequence analysis tools, Opal encodes sequences
    with an alphabet for faster indexing of matrices. Sequences inserted in
    a database are stored in encoded format using the alphabet of the
    `ScoreMatrix` given on instantiation.

    """

    cdef readonly ScoreMatrix   score_matrix
    cdef          vector[seq_t] _sequences
    cdef          vector[int]   _lengths

    # --- Magic methods --------------------------------------------------------

    def __cinit__(self):
        self._sequences = vector[seq_t]()
        self._lengths   = vector[int]()

    def __init__(self, object sequences=(), ScoreMatrix score_matrix=None):
        # reset the collection is `__init__` is called more than once
        self.clear()
        # record the score matrix
        self.score_matrix = score_matrix or ScoreMatrix.aa()
        # add the sequences to the database
        self.extend(sequences)

    def __dealloc__(self):
        cdef size_t i
        for i in range(self._sequences.size()):
            PyMem_Free(self._sequences[i])


    # --- Sequence interface ---------------------------------------------------

    def __len__(self):
        return self._sequences.size()

    def __getitem__(self, ssize_t index):
        cdef size_t         i
        cdef bytearray      decoded
        cdef seq_t          encoded
        cdef ssize_t        index_   = index
        cdef size_t         size     = self._sequences.size()
        cdef unsigned char* alphabet = self.score_matrix._mx.getAlphabet()

        if index_ < 0:
            index_ += size
        if index_ < 0 or (<size_t> index_) >= size:
            raise IndexError(index)

        encoded = self._sequences[index_]
        decoded = bytearray(self._lengths[index_])
        for i in range(self._lengths[index_]):
            decoded[i] = alphabet[encoded[i]]

        return decoded.decode("ascii")

    cpdef void clear(self) except *:
        """clear(self)\n--

        Remove all sequences from the database.

        """
        cdef size_t i
        for i in range(self._sequences.size()):
            PyMem_Free(self._sequences[i])
        self._sequences.clear()
        self._lengths.clear()

    cpdef void extend(self, object sequences) except *:
        """extend(self, sequences)\n--

        Extend the database by adding sequences from an iterable.

        """
        # attempt to reserve space in advance for the new sequences
        cdef size_t hint = operator.length_hint(sequences)
        cdef size_t size = self._sequences.size()
        if hint > 0:
            self._sequences.reserve(hint + size)
            self._lengths.reserve(hint + size)

        # append sequences in order
        for sequence in sequences:
            self.append(sequence)

    cpdef void append(self, object sequence) except *:
        """append(self, sequence)\n--

        Append a single sequence at the end of the database.

        """
        cdef int   length
        cdef seq_t encoded

        if isinstance(sequence, str):
            encode_str(sequence, self.score_matrix._ahash, &encoded, &length)
        else:
            encode_bytes(sequence, self.score_matrix._ahash, &encoded, &length)

        self._sequences.push_back(encoded)
        self._lengths.push_back(length)

    cpdef void reverse(self) except *:
        """reverse(self)\n--

        Reverse the database, in place.

        """
        reverse(self._sequences.begin(), self._sequences.end())
        reverse(self._lengths.begin(), self._lengths.end())

    # --- Opal search ----------------------------------------------------------

    def search(
        self,
        object sequence,
        *,
        int gap_open = 3,
        int gap_extend = 1,
        str mode = "score",
        str overflow = "buckets",
        str algorithm = "sw",
    ):
        """search(self, sequence, *, gap_open=3, gap_extend=1, mode="score", overflow="buckets", algorithm="sw")\n--

        Search the database with a query sequence.

        Arguments:
            sequence (`str` or byte-like object): The sequence to query the
                database with.

        Keyword Arguments:
            gap_open(`int`): The gap opening penalty :math:`G`.
            gap_extend (`int`): The gap extension penalty :math:`E`.
            mode (`str`): The search mode to use for querying the database:
                ``score`` to only report scores for each hit (default),
                ``end`` to report scores and end coordinates for each
                hit (slower), ``full`` to report scores, coordinates and
                alignment for each hit (slowest).
            overflow (`str`): The strategy to use when a sequence score
                overflows in the comparison pipeline: ``simple`` computes
                scores with 8-bit range first then recomputes with 16-bit
                range (and then 32-bit) the sequences that overflowed;
                ``bucket`` to divide the targets in ``buckets``, and switch
                to larger score ranges within a bucket when the first
                overflow is detected.
            algorithm (`str`): The alignment algorithm to use: ``nw``
                for global Needleman-Wunsch alignment, ``hw`` for semi-global
                alignment without penalization of gaps on query edges, ``ov``
                for semi-global alignment without penalization of gaps on
                query or target edges, and ``sw`` for local Smith-Waterman
                alignment.

        Hit:
            A gap of length :math:`N` will receive a penalty of
            :math:`E + (N - 1)G`.

        Returns:
            `list` of `pyopal.SearchResult`: A list containing one
                `SearchResult` object for each target sequence in the database,
                containing scores, and optionally coordinates and alignments.

        Raises:
            `ValueError`: When ``sequence`` contains invalid characters
                with respect to the alphabet of the database scoring
                matrix.

        """
        assert self.score_matrix is not None

        cdef int                          _mode
        cdef int                          _overflow
        cdef int                          _algo
        cdef size_t                       i
        cdef int                          retcode
        cdef int                          length
        cdef SearchResult                 result
        cdef list                         results
        cdef vector[OpalSearchResult_ptr] results_raw
        cdef size_t                       size        = self._sequences.size()
        cdef seq_t                        query       = NULL
        cdef searchfn_t                   searchfn    = NULL

        # validate parameters
        if mode in _OPAL_SEARCH_MODES:
            _mode = _OPAL_SEARCH_MODES[mode]
        else:
            raise ValueError(f"Invalid search mode: {mode!r}")
        if overflow in _OPAL_OVERFLOW_MODES:
            _overflow = _OPAL_OVERFLOW_MODES[overflow]
        else:
            raise ValueError(f"Invalid overflow mode: {mode!r}")
        if algorithm in _OPAL_ALGORITHMS:
            _algo = _OPAL_ALGORITHMS[algorithm]
        else:
            raise ValueError(f"Invalid algorithm: {algorithm!r}")

        # Prepare query
        if isinstance(sequence, str):
            encode_str(sequence, self.score_matrix._ahash, &query, &length)
        else:
            encode_bytes(sequence, self.score_matrix._ahash, &query, &length)

        # Prepare list of results
        res_array = PyMem_Malloc(sizeof(OpalSearchResult*) * size)
        results_raw.reserve(size)
        results = PyList_New(size)
        for i in range(size):
            result = SearchResult.__new__(SearchResult)
            result._target_index = i
            Py_INCREF(result)
            PyList_SET_ITEM(results, i, result)
            results_raw.push_back(&result._result)

        # Select best available SIMD backend
        IF AVX2_BUILD_SUPPORT:
            if _AVX2_RUNTIME_SUPPORT and searchfn is NULL:
                searchfn = opalSearchDatabaseAVX2
        IF SSE4_BUILD_SUPPORT:
            if _SSE4_RUNTIME_SUPPORT and searchfn is NULL:
                searchfn = opalSearchDatabaseSSE4
        IF SSE2_BUILD_SUPPORT:
            if _SSE2_RUNTIME_SUPPORT and searchfn is NULL:
                searchfn = opalSearchDatabaseSSE2
        IF NEON_BUILD_SUPPORT:
            if _NEON_RUNTIME_SUPPORT and searchfn is NULL:
                searchfn = opalSearchDatabaseNEON
        if searchfn is NULL:
            raise RuntimeError("No supported SIMD backend available")

        # Run search pipeline in nogil mode
        with nogil:
            retcode = searchfn(
                query,
                length,
                self._sequences.data(),
                self._sequences.size(),
                self._lengths.data(),
                gap_open,
                gap_extend,
                self.score_matrix._mx.getMatrix(),
                self.score_matrix._mx.getAlphabetLength(),
                results_raw.data(),
                _mode,
                _algo,
                _overflow,
            )

        # free memory for the query
        PyMem_Free(query)

        # check the alignment worked
        if retcode != 0:
            raise RuntimeError(f"Failed to run search Opal database (code={retcode})")
        return results







