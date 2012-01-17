########## CythonArray ##########

cdef extern from "stdlib.h":
    void *malloc(size_t)
    void free(void *)

cdef extern from "Python.h":

    cdef enum:
        PyBUF_C_CONTIGUOUS,
        PyBUF_F_CONTIGUOUS,
        PyBUF_ANY_CONTIGUOUS
        PyBUF_FORMAT
        PyBUF_WRITABLE


    void Py_INCREF(object)
    void Py_DECREF(object)

cdef extern from *:
    object __pyx_memoryview_new(object obj, int flags)
    Py_ssize_t fill_contig_strides_array "__pyx_fill_contig_strides_array" (
                Py_ssize_t *shape, Py_ssize_t *strides, Py_ssize_t stride,
                int ndim, char order) nogil

@cname("__pyx_array")
cdef class array:

    cdef:
        char *data
        Py_ssize_t len
        char *format
        int ndim
        Py_ssize_t *_shape
        Py_ssize_t *_strides
        Py_ssize_t itemsize
        unicode mode
        bytes _format
        void (*callback_free_data)(void *data)
        # cdef object _memview
        cdef bint free_data

    def __cinit__(array self, tuple shape, Py_ssize_t itemsize, format,
                  mode=u"c", bint allocate_buffer=True):

        self.ndim = len(shape)
        self.itemsize = itemsize

        if not self.ndim:
            raise ValueError("Empty shape tuple for cython.array")

        if self.itemsize <= 0:
            raise ValueError("itemsize <= 0 for cython.array")

        encode = getattr(format, 'encode', None)
        if encode:
            format = encode('ASCII')
        self._format = format
        self.format = self._format

        self._shape = <Py_ssize_t *> malloc(sizeof(Py_ssize_t)*self.ndim)
        self._strides = <Py_ssize_t *> malloc(sizeof(Py_ssize_t)*self.ndim)

        if not self._shape or not self._strides:
            free(self._shape)
            free(self._strides)
            raise MemoryError("unable to allocate shape or strides.")

        cdef int idx
        # cdef Py_ssize_t dim, stride
        idx = 0
        for idx, dim in enumerate(shape):
            if dim <= 0:
                raise ValueError("Invalid shape in axis %d: %d." % (idx, dim))

            self._shape[idx] = dim
            idx += 1

        if mode not in ("fortran", "c"):
            raise ValueError("Invalid mode, expected 'c' or 'fortran', got %s" % mode)

        cdef char order
        if mode == 'fortran':
            order = 'F'
        else:
            order = 'C'

        self.len = fill_contig_strides_array(self._shape, self._strides,
                                             itemsize, self.ndim, order)

        decode = getattr(mode, 'decode', None)
        if decode:
            mode = decode('ASCII')
        self.mode = mode

        self.free_data = allocate_buffer
        if allocate_buffer:
            self.data = <char *>malloc(self.len)
            if not self.data:
                raise MemoryError("unable to allocate array data.")

    def __getbuffer__(self, Py_buffer *info, int flags):
        cdef int bufmode = -1
        if self.mode == b"c":
            bufmode = PyBUF_C_CONTIGUOUS | PyBUF_ANY_CONTIGUOUS
        elif self.mode == b"fortran":
            bufmode = PyBUF_F_CONTIGUOUS | PyBUF_ANY_CONTIGUOUS
        if not (flags & bufmode):
            raise ValueError("Can only create a buffer that is contiguous in memory.")
        info.buf = self.data
        info.len = self.len
        info.ndim = self.ndim
        info.shape = self._shape
        info.strides = self._strides
        info.suboffsets = NULL
        info.itemsize = self.itemsize
        info.readonly = 0

        if flags & PyBUF_FORMAT:
            info.format = self.format
        else:
            info.format = NULL

        info.obj = self

    def __dealloc__(array self):
        if self.callback_free_data != NULL:
            self.callback_free_data(self.data)
        elif self.free_data:
            free(self.data)

        self.data = NULL

        if self._strides:
            free(self._strides)
            self._strides = NULL

        if self._shape:
            free(self._shape)
            self._shape = NULL

        self.format = NULL
        self.itemsize = 0

    property memview:
        @cname('__pyx_cython_array_get_memview')
        def __get__(self):
            # Make this a property as 'data' may be set after instantiation
            #if self._memview is None:
            #    flags = PyBUF_ANY_CONTIGUOUS|PyBUF_FORMAT|PyBUF_WRITABLE
            #    self._memview = __pyx_memoryview_new(self, flags)

            #return self._memview
            flags =  PyBUF_ANY_CONTIGUOUS|PyBUF_FORMAT|PyBUF_WRITABLE
            return  __pyx_memoryview_new(self, flags)


    def __getattr__(self, attr):
        return getattr(self.memview, attr)

    def __getitem__(self, item):
        return self.memview[item]

    def __setitem__(self, item, value):
        self.memview[item] = value


@cname("__pyx_array_new")
cdef array array_cwrapper(tuple shape, Py_ssize_t itemsize, char *format, char *mode, char *buf):
    cdef array result
    if buf == NULL:
        result = array(shape, itemsize, format, mode.decode('ASCII'))
    else:
        result = array(shape, itemsize, format, mode.decode('ASCII'), allocate_buffer=False)
        result.data = buf

    return result


#################### View.MemoryView ####################

import cython

# from cpython cimport ...
cdef extern from "Python.h":
    int PyIndex_Check(object)
    object PyLong_FromVoidPtr(void *)

cdef extern from "pythread.h":
    ctypedef void *PyThread_type_lock

    PyThread_type_lock PyThread_allocate_lock()
    void PyThread_free_lock(PyThread_type_lock)
    int PyThread_acquire_lock(PyThread_type_lock, int mode) nogil
    void PyThread_release_lock(PyThread_type_lock) nogil

cdef extern from "string.h":
    void *memset(void *b, int c, size_t len)

cdef extern from *:
    int __Pyx_GetBuffer(object, Py_buffer *, int) except -1
    void __Pyx_ReleaseBuffer(Py_buffer *)

    void Py_INCREF(object)
    void Py_DECREF(object)
    void Py_XINCREF(object)

    ctypedef struct PyObject

    cdef struct __pyx_memoryview "__pyx_memoryview_obj":
        Py_buffer view
        PyObject *obj

    ctypedef struct {{memviewslice_name}}:
        __pyx_memoryview *memview
        char *data
        Py_ssize_t shape[{{max_dims}}]
        Py_ssize_t strides[{{max_dims}}]
        Py_ssize_t suboffsets[{{max_dims}}]

    void __PYX_INC_MEMVIEW({{memviewslice_name}} *memslice, int have_gil)
    void __PYX_XDEC_MEMVIEW({{memviewslice_name}} *memslice, int have_gil)

    ctypedef struct __pyx_buffer "Py_buffer":
        PyObject *obj

    PyObject *Py_None

    cdef enum:
        PyBUF_C_CONTIGUOUS,
        PyBUF_F_CONTIGUOUS,
        PyBUF_ANY_CONTIGUOUS
        PyBUF_FORMAT
        PyBUF_WRITABLE
        PyBUF_STRIDES
        PyBUF_INDIRECT
        PyBUF_RECORDS

cdef extern from *:
    ctypedef int __pyx_atomic_int
    {{memviewslice_name}} slice_copy_contig "__pyx_memoryview_copy_new_contig"(
                                 __Pyx_memviewslice *from_mvs,
                                 char *mode, int ndim,
                                 size_t sizeof_dtype, int contig_flag) nogil except *
    bint slice_is_contig "__pyx_memviewslice_is_contig" (
                            {{memviewslice_name}} *mvs, char order, int ndim) nogil
    bint slices_overlap "__pyx_slices_overlap" ({{memviewslice_name}} *slice1,
                                                {{memviewslice_name}} *slice2,
                                                int ndim, size_t itemsize) nogil



cdef extern from "stdlib.h":
    void *malloc(size_t) nogil
    void free(void *) nogil
    void *memcpy(void *dest, void *src, size_t n) nogil

@cname('__pyx_MemviewEnum')
cdef class Enum(object):
    cdef object name
    def __init__(self, name):
        self.name = name
    def __repr__(self):
        return self.name

# Disable generic_contiguous, as it makes trouble verifying contiguity:
#   - 'contiguous' or '::1' means the dimension is contiguous with dtype
#   - 'indirect_contiguous' means a contiguous list of pointers
#   - dtype contiguous must be contiguous in the first or last dimension
#     from the start, or from the dimension following the last indirect dimension
#
#   e.g.
#           int[::indirect_contiguous, ::contiguous, :]
#
#   is valid (list of pointers to 2d fortran-contiguous array), but
#
#           int[::generic_contiguous, ::contiguous, :]
#
#   would mean you'd have assert dimension 0 to be indirect (and pointer contiguous) at runtime.
#   So it doesn't bring any performance benefit, and it's only confusing.

cdef generic = Enum("<strided and direct or indirect>")
cdef strided = Enum("<strided and direct>") # default
cdef indirect = Enum("<strided and indirect>")
# Disable generic_contiguous, as it is a troublemaker
#cdef generic_contiguous = Enum("<contiguous and direct or indirect>")
cdef contiguous = Enum("<contiguous and direct>")
cdef indirect_contiguous = Enum("<contiguous and indirect>")

# 'follow' is implied when the first or last axis is ::1

@cname('__pyx_memoryview')
cdef class memoryview(object):

    cdef object obj
    cdef object _size
    cdef object _array_interface
    cdef PyThread_type_lock lock
    cdef __pyx_atomic_int acquisition_count
    cdef Py_buffer view
    cdef int flags

    def __cinit__(memoryview self, object obj, int flags):
        self.obj = obj
        self.flags = flags
        if type(self) is memoryview or obj is not None:
            __Pyx_GetBuffer(obj, &self.view, flags)
            if <PyObject *> self.view.obj == NULL:
                (<__pyx_buffer *> &self.view).obj = Py_None
                Py_INCREF(None)

        self.lock = PyThread_allocate_lock()
        if self.lock == NULL:
            raise MemoryError

    def __dealloc__(memoryview self):
        if self.obj is not None:
            __Pyx_ReleaseBuffer(&self.view)

        if self.lock != NULL:
            PyThread_free_lock(self.lock)

    cdef char *get_item_pointer(memoryview self, object index) except NULL:
        cdef Py_ssize_t dim
        cdef char *itemp = <char *> self.view.buf

        for dim, idx in enumerate(index):
            itemp = pybuffer_index(&self.view, itemp, idx, dim)

        return itemp

    @cname('__pyx_memoryview_getitem')
    def __getitem__(memoryview self, object index):
        if index is Ellipsis:
            return self

        have_slices, indices = _unellipsify(index, self.view.ndim)

        cdef char *itemp
        if have_slices:
            return memview_slice(self, indices)
        else:
            itemp = self.get_item_pointer(indices)
            return self.convert_item_to_object(itemp)

    @cname('__pyx_memoryview_setitem')
    def __setitem__(memoryview self, object index, object value):
        have_slices, index = _unellipsify(index, self.view.ndim)

        if have_slices:
            obj = self.is_slice(value)
            if obj:
                self.setitem_slice_assignment(index, obj)
            else:
                self.setitem_slice_assign_scalar(index, value)
        else:
            self.setitem_indexed(index, value)

    cdef is_slice(self, obj):
        if not isinstance(obj, memoryview):
            try:
                obj = memoryview(obj, self.flags|PyBUF_ANY_CONTIGUOUS)
            except TypeError:
                return None

        return obj

    cdef setitem_slice_assignment(self, index, src):
        cdef {{memviewslice_name}} dst_slice
        cdef {{memviewslice_name}} src_slice

        dst = self[index]
        memoryview_copy_contents(get_slice_from_memview(src, &src_slice)[0],
                                 get_slice_from_memview(dst, &dst_slice)[0],
                                 src.ndim, dst.ndim)

    cdef setitem_slice_assign_scalar(self, index, value):
        raise ValueError("Scalar assignment currently unsupported")

    cdef setitem_indexed(self, index, value):
        cdef char *itemp = self.get_item_pointer(index)
        self.assign_item_from_object(itemp, value)

    cdef convert_item_to_object(self, char *itemp):
        """Only used if instantiated manually by the user, or if Cython doesn't
        know how to convert the type"""
        import struct
        cdef bytes bytesitem
        # Do a manual and complete check here instead of this easy hack
        bytesitem = itemp[:self.view.itemsize]
        try:
            result = struct.unpack(self.view.format, bytesitem)
        except struct.error:
            raise ValueError("Unable to convert item to object")
        else:
            if len(self.view.format) == 1:
                return result[0]
            return result

    cdef assign_item_from_object(self, char *itemp, object value):
        """Only used if instantiated manually by the user, or if Cython doesn't
        know how to convert the type"""
        import struct
        cdef char c
        cdef bytes bytesvalue
        cdef Py_ssize_t i

        if isinstance(value, tuple):
            bytesvalue = struct.pack(self.view.format, *value)
        else:
            bytesvalue = struct.pack(self.view.format, value)

        for i, c in enumerate(bytesvalue):
            itemp[i] = c

    def __getbuffer__(self, Py_buffer *info, int flags):
        if flags & PyBUF_STRIDES:
            info.shape = self.view.shape
        else:
            info.shape = NULL

        if flags & PyBUF_STRIDES:
            info.strides = self.view.strides
        else:
            info.strides = NULL

        if flags & PyBUF_INDIRECT:
            info.suboffsets = self.view.suboffsets
        else:
            info.suboffsets = NULL

        if flags & PyBUF_FORMAT:
            info.format = self.view.format
        else:
            info.format = NULL

        info.buf = self.view.buf
        info.ndim = self.view.ndim
        info.itemsize = self.view.itemsize
        info.len = self.view.len
        info.readonly = 0
        info.obj = self

    # Some properties that have the same sematics as in NumPy
    property T:
        @cname('__pyx_memoryview_transpose')
        def __get__(self):
            cdef _memoryviewslice result = memoryview_copy(self)
            transpose_memslice(&result.from_slice)
            return result

    property base:
        @cname('__pyx_memoryview__get__base')
        def __get__(self):
            return self.obj

    property shape:
        @cname('__pyx_memoryview_get_shape')
        def __get__(self):
            return tuple([self.view.shape[i] for i in xrange(self.view.ndim)])

    property strides:
        @cname('__pyx_memoryview_get_strides')
        def __get__(self):
            if self.view.strides == NULL:
                # Note: we always ask for strides, so if this is not set it's a bug
                raise ValueError("Buffer view does not expose strides")

            return tuple([self.view.strides[i] for i in xrange(self.view.ndim)])

    property suboffsets:
        @cname('__pyx_memoryview_get_suboffsets')
        def __get__(self):
            if self.view.suboffsets == NULL:
                return [-1] * self.view.ndim

            return tuple([self.view.suboffsets[i] for i in xrange(self.view.ndim)])

    property ndim:
        @cname('__pyx_memoryview_get_ndim')
        def __get__(self):
            return self.view.ndim

    property itemsize:
        @cname('__pyx_memoryview_get_itemsize')
        def __get__(self):
            return self.view.itemsize

    property nbytes:
        @cname('__pyx_memoryview_get_nbytes')
        def __get__(self):
            return self.size * self.view.itemsize

    property size:
        @cname('__pyx_memoryview_get_size')
        def __get__(self):
            if self._size is None:
                result = 1

                for length in self.shape:
                    result *= length

                self._size = result

            return self._size

    def __len__(self):
        if self.view.ndim >= 1:
            return self.view.shape[0]

        return 0

    def __repr__(self):
        return "<MemoryView of %r at 0x%x>" % (self.base.__class__.__name__,
                                               id(self))

    def __str__(self):
        return "<MemoryView of %r object>" % (self.base.__class__.__name__,)

    # Support the same attributes as memoryview slices
    def is_c_contig(self):
        cdef {{memviewslice_name}} *mslice, tmp
        mslice = get_slice_from_memview(self, &tmp)
        return slice_is_contig(mslice, 'C', self.view.ndim)

    def is_f_contig(self):
        cdef {{memviewslice_name}} *mslice, tmp
        mslice = get_slice_from_memview(self, &tmp)
        return slice_is_contig(mslice, 'F', self.view.ndim)

    def copy(self):
        cdef {{memviewslice_name}} mslice
        cdef int flags = self.flags & ~PyBUF_F_CONTIGUOUS
        slice_copy(self, &mslice)
        mslice = slice_copy_contig(&mslice, "c", self.view.ndim,
                                   self.view.itemsize,
                                   flags|PyBUF_C_CONTIGUOUS)
        return memoryview_copy_from_slice(self, &mslice)

    def copy_fortran(self):
        cdef {{memviewslice_name}} src, dst
        cdef int flags = self.flags & ~PyBUF_C_CONTIGUOUS
        slice_copy(self, &src)
        dst = slice_copy_contig(&src, "fortran", self.view.ndim,
                                self.view.itemsize,
                                flags|PyBUF_F_CONTIGUOUS)
        return memoryview_copy_from_slice(self, &dst)


@cname('__pyx_memoryview_new')
cdef memoryview_cwrapper(object o, int flags):
    return memoryview(o, flags)

cdef tuple _unellipsify(object index, int ndim):
    """
    Replace all ellipses with full slices and fill incomplete indices with
    full slices.
    """
    if not isinstance(index, tuple):
        tup = (index,)
    else:
        tup = index

    result = []
    have_slices = False
    seen_ellipsis = False
    for idx, item in enumerate(tup):
        if item is Ellipsis:
            if not seen_ellipsis:
                result.extend([slice(None)] * (ndim - len(tup) + 1))
                seen_ellipsis = True
            else:
                result.append(slice(None))
            have_slices = True
        else:
            if not isinstance(item, slice) and not PyIndex_Check(item):
                raise TypeError("Cannot index with type '%s'" % type(item))

            have_slices = have_slices or isinstance(item, slice)
            result.append(item)

    nslices = ndim - len(result)
    if nslices:
        result.extend([slice(None)] * nslices)

    return have_slices or nslices, tuple(result)

#
### Slicing a memoryview
#

@cname('__pyx_memview_slice')
cdef memoryview memview_slice(memoryview memview, object indices):
    cdef int new_ndim = 0, suboffset_dim = -1, dim
    cdef bint negative_step
    cdef {{memviewslice_name}} src, dst
    cdef {{memviewslice_name}} *p_src

    # dst is copied by value in memoryview_fromslice -- initialize it
    # src is never copied
    memset(&dst, 0, sizeof(dst))

    cdef _memoryviewslice memviewsliceobj

    assert memview.view.ndim > 0

    if isinstance(memview, _memoryviewslice):
        memviewsliceobj = memview
        p_src = &memviewsliceobj.from_slice
    else:
        slice_copy(memview, &src)
        p_src = &src

    # Note: don't use variable src at this point
    # SubNote: we should be able to declare variables in blocks...

    # memoryview_fromslice() will inc our dst slice
    dst.memview = p_src.memview
    dst.data = p_src.data

    # Put everything in temps to avoid this bloody warning:
    # "Argument evaluation order in C function call is undefined and
    #  may not be as expected"
    cdef {{memviewslice_name}} *p_dst = &dst
    cdef int *p_suboffset_dim = &suboffset_dim
    cdef Py_ssize_t start, stop, step
    cdef bint have_start, have_stop, have_step

    for dim, index in enumerate(indices):
        if PyIndex_Check(index):
            slice_memviewslice(p_src, p_dst, dim, new_ndim, p_suboffset_dim,
                               index, 0, 0, 0, 0, 0, False)
        else:
            start = index.start or 0
            stop = index.stop or 0
            step = index.step or 0

            have_start = index.start is not None
            have_stop = index.stop is not None
            have_step = index.step is not None

            slice_memviewslice(p_src, p_dst, dim, new_ndim, p_suboffset_dim,
                               start, stop, step, have_start, have_stop, have_step,
                               True)
            new_ndim += 1

    if isinstance(memview, _memoryviewslice):
        return memoryview_fromslice(&dst, new_ndim,
                                    memviewsliceobj.to_object_func,
                                    memviewsliceobj.to_dtype_func)
    else:
        return memoryview_fromslice(&dst, new_ndim, NULL, NULL)


#
### Slicing in a single dimension of a memoryviewslice
#

cdef extern from "stdlib.h":
    void abort() nogil
    void printf(char *s, ...) nogil

cdef extern from "stdio.h":
    ctypedef struct FILE
    FILE *stderr
    int fputs(char *s, FILE *stream)

cdef extern from "pystate.h":
    void PyThreadState_Get() nogil

    # These are not actually nogil, but we check for the GIL before calling them
    void PyErr_SetString(PyObject *type, char *msg) nogil
    PyObject *PyErr_Format(PyObject *exc, char *msg, ...) nogil

@cname('__pyx_memoryview_slice_memviewslice')
cdef int slice_memviewslice({{memviewslice_name}} *src,
                              {{memviewslice_name}} *dst,
                              int dim,
                              int new_ndim,
                              int *suboffset_dim,
                              Py_ssize_t start,
                              Py_ssize_t stop,
                              Py_ssize_t step,
                              int have_start,
                              int have_stop,
                              int have_step,
                              bint is_slice) nogil except -1:
    """
    Create a new slice dst given slice src.

    dim             - the current src dimension (indexing will make dimensions
                                                 disappear)
    new_dim         - the new dst dimension
    suboffset_dim   - pointer to a single int initialized to -1 to keep track of
                      where slicing offsets should be added
    """

    cdef:
        Py_ssize_t shape, stride, suboffset
        Py_ssize_t new_shape
        bint negative_step

    shape = src.shape[dim]
    stride = src.strides[dim]
    suboffset = src.suboffsets[dim]

    if not is_slice:
        # index is a normal integer-like index
        if start < 0:
            start += shape
        if not 0 <= start < shape:
            with gil:
                raise IndexError("Index out of bounds (axis %d)")
    else:
        # index is a slice
        negative_step = have_step != 0 and step < 0

        if have_step and step == 0:
            with gil:
                raise ValueError("Step may not be zero (axis %d)" % dim)

        # check our bounds and set defaults
        if have_start:
            if start < 0:
                start += shape
                if start < 0:
                    start = 0
            elif start >= shape:
                if negative_step:
                    start = shape - 1
                else:
                    start = shape
        else:
            if negative_step:
                start = shape - 1
            else:
                start = 0

        if have_stop:
            if stop < 0:
                stop += shape
                if stop < 0:
                    stop = 0
            elif stop > shape:
                stop = shape
        else:
            if negative_step:
                stop = -1
            else:
                stop = shape

        if not have_step:
            step = 1

        # len = ceil( (stop - start) / step )
        with cython.cdivision(True):
            new_shape = (stop - start) // step

            if (stop - start) % step:
                new_shape += 1

        if new_shape < 0:
            new_shape = 0

        # shape/strides/suboffsets
        dst.strides[new_ndim] = stride * step
        dst.shape[new_ndim] = new_shape
        dst.suboffsets[new_ndim] = suboffset

    # Add the slicing or idexing offsets to the right suboffset or base data *
    if suboffset_dim[0] < 0:
        dst.data += start * stride
    else:
        dst.suboffsets[suboffset_dim[0]] += start * stride

    if suboffset >= 0:
        if not is_slice:
            if new_ndim == 0:
                dst.data = (<char **> dst.data)[0] + suboffset
            else:
                with gil:
                    raise IndexError("All dimensions preceding dimension %d "
                                     "must be indexed and not sliced" % dim)
        else:
            suboffset_dim[0] = new_ndim

    return 0

#
### Index a memoryview
#
@cname('__pyx_pybuffer_index')
cdef char *pybuffer_index(Py_buffer *view, char *bufp, Py_ssize_t index,
                          int dim) except NULL:
    cdef Py_ssize_t shape, stride, suboffset = -1
    cdef Py_ssize_t itemsize = view.itemsize
    cdef char *resultp

    if view.ndim == 0:
        shape = view.len / itemsize
        stride = itemsize
    else:
        shape = view.shape[dim]
        stride = view.strides[dim]
        if view.suboffsets != NULL:
            suboffset = view.suboffsets[dim]

    if index < 0:
        index += view.shape[dim]
        if index < 0:
            raise IndexError("Out of bounds on buffer access (axis %d)" % dim)

    if index >= shape:
        raise IndexError("Out of bounds on buffer access (axis %d)" % dim)

    resultp = bufp + index * stride
    if suboffset >= 0:
        resultp = (<char **> resultp)[0] + suboffset

    return resultp

#
### Transposing a memoryviewslice
#
@cname('__pyx_memslice_transpose')
cdef int transpose_memslice({{memviewslice_name}} *memslice) nogil except 0:
    cdef int ndim = memslice.memview.view.ndim

    cdef Py_ssize_t *shape = memslice.shape
    cdef Py_ssize_t *strides = memslice.strides

    # reverse strides and shape
    cdef int i, j
    for i in range(ndim / 2):
        j = ndim - 1 - i
        strides[i], strides[j] = strides[j], strides[i]
        shape[i], shape[j] = shape[j], shape[i]

        if memslice.suboffsets[i] >= 0 or memslice.suboffsets[j] >= 0:
            with gil:
                raise ValueError("Cannot transpose memoryview with indirect dimensions")

    return 1

#
### Creating new memoryview objects from slices and memoryviews
#
@cname('__pyx_memoryviewslice')
cdef class _memoryviewslice(memoryview):
    "Internal class for passing memoryview slices to Python"

    # We need this to keep our shape/strides/suboffset pointers valid
    cdef {{memviewslice_name}} from_slice
    # We need this only to print it's class' name
    cdef object from_object

    cdef object (*to_object_func)(char *)
    cdef int (*to_dtype_func)(char *, object) except 0

    def __dealloc__(self):
        __PYX_XDEC_MEMVIEW(&self.from_slice, 1)

    cdef convert_item_to_object(self, char *itemp):
        if self.to_object_func != NULL:
            return self.to_object_func(itemp)
        else:
            return memoryview.convert_item_to_object(self, itemp)

    cdef assign_item_from_object(self, char *itemp, object value):
        if self.to_dtype_func != NULL:
            self.to_dtype_func(itemp, value)
        else:
            memoryview.assign_item_from_object(self, itemp, value)

    property base:
        @cname('__pyx_memoryviewslice__get__base')
        def __get__(self):
            return self.from_object

@cname('__pyx_memoryview_fromslice')
cdef memoryview_fromslice({{memviewslice_name}} *memviewslice,
                          int ndim,
                          object (*to_object_func)(char *),
                          int (*to_dtype_func)(char *, object) except 0):

    cdef _memoryviewslice result
    cdef int i

    # assert 0 < ndim <= memviewslice.memview.view.ndim, (
    #                 ndim, memviewslice.memview.view.ndim)

    result = _memoryviewslice(None, 0)

    result.from_slice = memviewslice[0]
    __PYX_INC_MEMVIEW(memviewslice, 1)

    result.from_object = <object> memviewslice.memview.obj

    result.view = memviewslice.memview.view
    result.view.buf = <void *> memviewslice.data
    result.view.ndim = ndim
    (<__pyx_buffer *> &result.view).obj = Py_None
    Py_INCREF(None)

    result.flags = PyBUF_RECORDS

    result.view.shape = <Py_ssize_t *> result.from_slice.shape
    result.view.strides = <Py_ssize_t *> result.from_slice.strides
    result.view.suboffsets = <Py_ssize_t *> result.from_slice.suboffsets

    result.view.len = result.view.itemsize
    for i in range(ndim):
        result.view.len *= result.view.shape[i]

    result.to_object_func = to_object_func
    result.to_dtype_func = to_dtype_func

    return result

@cname('__pyx_memoryview_get_slice_from_memoryview')
cdef {{memviewslice_name}} *get_slice_from_memview(memoryview memview,
                                                   {{memviewslice_name}} *mslice):
    cdef _memoryviewslice obj
    if isinstance(memview, _memoryviewslice):
        obj = memview
        return &obj.from_slice
    else:
        slice_copy(memview, mslice)
        return mslice

@cname('__pyx_memoryview_slice_copy')
cdef void slice_copy(memoryview memview, {{memviewslice_name}} *dst):
    cdef int dim

    dst.memview = <__pyx_memoryview *> memview
    dst.data = <char *> memview.view.buf

    for dim in range(memview.view.ndim):
        dst.shape[dim] = memview.view.shape[dim]
        dst.strides[dim] = memview.view.strides[dim]
        dst.suboffsets[dim] = memview.view.suboffsets[dim]

@cname('__pyx_memoryview_copy_object')
cdef memoryview_copy(memoryview memview):
    "Create a new memoryview object"
    cdef {{memviewslice_name}} memviewslice
    slice_copy(memview, &memviewslice)
    return memoryview_copy_from_slice(memview, &memviewslice)

@cname('__pyx_memoryview_copy_object_from_slice')
cdef memoryview_copy_from_slice(memoryview memview, {{memviewslice_name}} *memviewslice):
    """
    Create a new memoryview object from a given memoryview object and slice.
    """
    cdef object (*to_object_func)(char *)
    cdef int (*to_dtype_func)(char *, object) except 0

    if isinstance(memview, _memoryviewslice):
        to_object_func = (<_memoryviewslice> memview).to_object_func
        to_dtype_func = (<_memoryviewslice> memview).to_dtype_func
    else:
        to_object_func = NULL
        to_dtype_func = NULL

    return memoryview_fromslice(memviewslice, memview.view.ndim,
                                to_object_func, to_dtype_func)


#
### Copy the contents of a memoryview slices
#
cdef Py_ssize_t abs_py_ssize_t(Py_ssize_t arg) nogil:
    if arg < 0:
        return -arg
    else:
        return arg

@cname('__pyx_get_best_slice_order')
cdef char get_best_order({{memviewslice_name}} *mslice, int ndim) nogil:
    """
    Figure out the best memory access order for a given slice.
    """
    cdef int i
    cdef Py_ssize_t c_stride = 0
    cdef Py_ssize_t f_stride = 0

    for i in range(ndim - 1, -1, -1):
        if mslice.shape[i] > 1:
            c_stride = mslice.strides[i]
            break

    for i in range(ndim):
        if mslice.shape[i] > 1:
            f_stride = mslice.strides[i]
            break

    if abs_py_ssize_t(c_stride) <= abs_py_ssize_t(f_stride):
        return 'C'
    else:
        return 'F'

@cython.cdivision(True)
cdef void _copy_strided_to_strided(char *src_data, Py_ssize_t *src_strides,
                                   char *dst_data, Py_ssize_t *dst_strides,
                                   Py_ssize_t *src_shape, Py_ssize_t *dst_shape,
                                   int ndim, size_t itemsize) nogil:
    # Note: src_extent is 1 if we're broadcasting
    # dst_extent always >= src_extent as we don't do reductions
    cdef Py_ssize_t i
    cdef Py_ssize_t src_extent = src_shape[0]
    cdef Py_ssize_t dst_extent = dst_shape[0]
    cdef Py_ssize_t src_stride = src_strides[0]
    cdef Py_ssize_t dst_stride = dst_strides[0]

    if ndim == 1:
       if (src_stride > 0 and dst_stride > 0 and
           <size_t> src_stride == itemsize == <size_t> dst_stride):
           memcpy(dst_data, src_data, itemsize * dst_extent)
       else:
           for i in range(dst_extent):
               memcpy(dst_data, src_data, itemsize)
               src_data += src_stride
               dst_data += dst_stride
    else:
        for i in range(dst_extent):
            _copy_strided_to_strided(src_data, src_strides + 1,
                                     dst_data, dst_strides + 1,
                                     src_shape + 1, dst_shape + 1,
                                     ndim - 1, itemsize)
            src_data += src_stride
            dst_data += dst_stride

cdef void copy_strided_to_strided({{memviewslice_name}} *src,
                                  {{memviewslice_name}} *dst,
                                  int ndim, size_t itemsize) nogil:
    _copy_strided_to_strided(src.data, src.strides, dst.data, dst.strides,
                             src.shape, dst.shape, ndim, itemsize)

@cname('__pyx_memoryview_slice_get_size')
cdef Py_ssize_t slice_get_size({{memviewslice_name}} *src, int ndim) nogil:
    "Return the size of the memory occupied by the slice in number of bytes"
    cdef int i
    cdef Py_ssize_t size = src.memview.view.itemsize

    for i in range(ndim):
        size *= src.shape[i]

    return size

@cname('__pyx_fill_contig_strides_array')
cdef Py_ssize_t fill_contig_strides_array(
                Py_ssize_t *shape, Py_ssize_t *strides, Py_ssize_t stride,
                int ndim, char order) nogil:
    "Fill the strides array for a slice with C or F contiguous strides"
    cdef int idx

    if order == 'F':
        for idx in range(ndim):
            strides[idx] = stride
            stride = stride * shape[idx]
    else:
        for idx in range(ndim - 1, -1, -1):
            strides[idx] = stride
            stride = stride * shape[idx]

    return stride

@cname('__pyx_memoryview_copy_data_to_temp')
cdef void *copy_data_to_temp({{memviewslice_name}} *src,
                             {{memviewslice_name}} *tmpslice,
                             char order,
                             int ndim) nogil except NULL:
    """
    Copy a direct slice to temporary contiguous memory. The caller should free
    the result when done.
    """
    cdef int i
    cdef void *result

    cdef size_t itemsize = src.memview.view.itemsize
    cdef size_t size = slice_get_size(src, ndim)

    result = malloc(size)
    if not result:
        with gil:
            raise MemoryError

    # tmpslice[0] = src
    tmpslice.data = <char *> result
    tmpslice.memview = src.memview
    for i in range(ndim):
        tmpslice.shape[i] = src.shape[i]
        tmpslice.suboffsets[i] = -1

    fill_contig_strides_array(&tmpslice.shape[0], &tmpslice.strides[0], itemsize,
                              ndim, order)

    # We need to broadcast strides again
    for i in range(ndim):
        if tmpslice.shape[i] == 1:
            tmpslice.strides[i] = 0

    if slice_is_contig(src, order, ndim):
        memcpy(result, src.data, size)
    else:
        copy_strided_to_strided(src, tmpslice, ndim, itemsize)

    return result

@cname('__pyx_memoryview_copy_contents')
cdef int memoryview_copy_contents({{memviewslice_name}} src,
                                  {{memviewslice_name}} dst,
                                  int src_ndim, int dst_ndim) nogil except -1:
    """
    Copy memory from slice src to slice dst.
    Check for overlapping memory and verify the shapes.
    """
    cdef void *tmpdata = NULL
    cdef size_t itemsize = src.memview.view.itemsize
    cdef int i
    cdef char order = get_best_order(&src, src_ndim)
    cdef bint broadcasting = False
    cdef bint direct_copy = False
    cdef {{memviewslice_name}} tmp

    if src_ndim < dst_ndim:
        broadcast_leading(&src, src_ndim, dst_ndim)
    elif dst_ndim < src_ndim:
        broadcast_leading(&dst, dst_ndim, src_ndim)

    cdef int ndim = max(src_ndim, dst_ndim)

    for i in range(ndim):
        if src.shape[i] != dst.shape[i]:
            if src.shape[i] == 1:
                broadcasting = True
                src.strides[i] = 0
            else:
                with gil:
                    raise ValueError(
                        "got differing extents in dimension %d "
                        "(got %d and %d)" % (i, dst.shape[i], src.shape[i]))

        if src.suboffsets[i] >= 0:
            with gil:
                raise ValueError("Dimension %d is not direct" % i)

    if slices_overlap(&src, &dst, ndim, itemsize):
        # slices overlap, copy to temp, copy temp to dst
        if not slice_is_contig(&src, order, ndim):
            order = get_best_order(&dst, ndim)

        tmpdata = copy_data_to_temp(&src, &tmp, order, ndim)
        src = tmp

    if not broadcasting:
        # See if both slices have equal contiguity, in that case perform a
        # direct copy. This only works when we are not broadcasting.
        if slice_is_contig(&src, 'C', ndim):
            direct_copy = slice_is_contig(&dst, 'C', ndim)
        elif slice_is_contig(&src, 'F', ndim):
            direct_copy = slice_is_contig(&dst, 'F', ndim)

        if direct_copy:
            # Contiguous slices with same order
            memcpy(dst.data, src.data, slice_get_size(&src, ndim))
            return 0

    if order == 'F' == get_best_order(&dst, ndim):
        # see if both slices have Fortran order, transpose them to match our
        # C-style indexing order
        transpose_memslice(&src)
        transpose_memslice(&dst)

    copy_strided_to_strided(&src, &dst, ndim, itemsize)
    free(tmpdata)
    return 0

@cname('__pyx_memoryview_broadcast_leading')
cdef void broadcast_leading({{memviewslice_name}} *slice,
                            int ndim,
                            int ndim_other) nogil:
    cdef int i
    cdef int offset = ndim_other - ndim

    for i in range(ndim - 1, -1, -1):
        slice.shape[i + offset] = slice.shape[i]
        slice.strides[i + offset] = slice.strides[i]
        slice.suboffsets[i + offset] = slice.suboffsets[i]

    for i in range(offset):
        slice.shape[i] = 1
        slice.strides[i] = slice.strides[0]
        slice.suboffsets[i] = -1


############### BufferFormatFromTypeInfo ###############
cdef extern from *:
    ctypedef struct __Pyx_StructField

    cdef enum:
        __PYX_BUF_FLAGS_PACKED_STRUCT
        __PYX_BUF_FLAGS_INTEGER_COMPLEX

    ctypedef struct __Pyx_TypeInfo:
      char* name
      __Pyx_StructField* fields
      size_t size
      size_t arraysize[8]
      int ndim
      char typegroup
      char is_unsigned
      int flags

    ctypedef struct __Pyx_StructField:
      __Pyx_TypeInfo* type
      char* name
      size_t offset

    ctypedef struct __Pyx_BufFmt_StackElem:
      __Pyx_StructField* field
      size_t parent_offset

    #ctypedef struct __Pyx_BufFmt_Context:
    #  __Pyx_StructField root
      __Pyx_BufFmt_StackElem* head

    struct __pyx_typeinfo_string:
        char string[3]

    __pyx_typeinfo_string __Pyx_TypeInfoToFormat(__Pyx_TypeInfo *)


@cname('__pyx_format_from_typeinfo')
cdef format_from_typeinfo(__Pyx_TypeInfo *type):
    """
    We want to return bytes, but python 3 doesn't allow you to do anything
    useful with bytes. So use str and convert back and forth to/from unicode.
    Thank you python 3 for making bytes the most useless thing ever!
    """
    cdef __Pyx_StructField *field
    cdef __pyx_typeinfo_string fmt

    if type.typegroup == 'S':
        assert type.fields != NULL and type.fields.type != NULL

        if type.flags & __PYX_BUF_FLAGS_PACKED_STRUCT:
            alignment = '^'
        else:
            alignment = ''

        parts = ["T{"]
        field = type.fields

        while field.type:
            part = format_from_typeinfo(field.type).decode('ascii')
            parts.append('%s:%s:' % (part, field.name))
            field += 1

        result = alignment.join(parts) + '}'
    else:
        fmt = __Pyx_TypeInfoToFormat(type)
        if type.arraysize[0]:
            extents = [str(type.arraysize[i]) for i in range(type.ndim)]
            result = "(%s)%s" % (','.join(extents), fmt.string.decode('ascii'))
        else:
            result = fmt.string.decode('ascii')

    return result.encode('ascii')
